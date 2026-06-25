#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

# Reset geoip2 state before deciding whether it is enabled this start. On a
# persistent /etc/angie volume the active symlinks survive container recreation,
# and both early `exit 0` paths (GEOIP2_DB_COUNTRY unset, or its DB
# unreadable) would otherwise leave an orphaned `geoip2 <path>` map pointing at a
# possibly-gone database. angie's geoip2 module opens the mmdb at config load, so
# a stale map left in the final config fails `angie -t` (see
# docker-entrypoint.sh). Re-enabled when geoip2 genuinely comes up.
reset_httpconf 025-geoip2.conf
reset_module http_geoip2.conf

if [ -z "${GEOIP2_DB_COUNTRY:-}" ]; then
  exit 0
fi

if [ ! -r "${GEOIP2_DB_COUNTRY}" ]; then
  ngx_warning "GeoIP database '$GEOIP2_DB_COUNTRY' not found"
  exit 0
fi

# The path is substituted into a config directive. Restrict it to a safe charset
# so the value cannot break out of the geoip2{} block (config injection) or
# contain a character that aborts the sed substitution below.
case "$GEOIP2_DB_COUNTRY" in
*[!A-Za-z0-9._/-]*)
  ngx_err "GEOIP2_DB_COUNTRY has unsupported characters (allowed: A-Za-z0-9 . _ / -): $GEOIP2_DB_COUNTRY"
  exit 1
  ;;
esac

: "${ANGIE_LOG_FORMAT_LOGFMT_GEOIP2:=no}"
: "${ANGIE_LOG_LOGFMT_GEOIP2:=no}"

ngx_ctl mod en http_geoip2.conf &&
  ngx_info "GeoIP2 module enabled"

# Render the active config from the pristine template every start: idempotent
# across restarts (a changed DB path is re-applied) and the template is never
# mutated in place. The validated charset above keeps the '|' delimiter safe.
geoip2_conf="/etc/angie/http-conf-available.d/025-geoip2.conf"
sed -e "s|%%GEOIP2_DB_COUNTRY%%|$GEOIP2_DB_COUNTRY|g" "${geoip2_conf}.template" >"$geoip2_conf"
ngx_ctl httpconf en 025-geoip2.conf &&
  ngx_info "GeoIP2 database configured: ${GEOIP2_DB_COUNTRY}"

case "${ANGIE_LOG_FORMAT_LOGFMT_GEOIP2}" in
yes | on | 1 | true | enable | enabled)
  enable_log_format "logfmt-with-geoip2"
  ;;
esac

case "${ANGIE_LOG_LOGFMT_GEOIP2}" in
yes | on | 1 | true | enable | enabled)
  enable_log "logfmt-with-geoip2"
  ;;
esac
