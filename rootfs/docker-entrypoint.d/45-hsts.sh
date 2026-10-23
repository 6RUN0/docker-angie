#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_HSTS_ENABLED:=no}"

# Reset before deciding whether HSTS is on this start (declarative toggle, see
# docker-entrypoint-common.sh): an active rendered snippet would keep sending a
# stale max-age after the toggle is switched off.
reset_httpconf 056-hsts.conf

case "${ANGIE_HSTS_ENABLED}" in
yes | on | 1 | true | enable | enabled) ;;
*)
  exit 0
  ;;
esac

# The h5bp default: 16070400 seconds, 186 days. The value sets how long the
# consumer binds itself, so it is the consumer's choice, not the image's.
: "${ANGIE_HSTS_MAX_AGE:=16070400}"
: "${ANGIE_HSTS_INCLUDE_SUBDOMAINS:=no}"

case "$ANGIE_HSTS_MAX_AGE" in
'' | *[!0-9]*)
  ngx_err "ANGIE_HSTS_MAX_AGE must be a decimal number of seconds, got: $ANGIE_HSTS_MAX_AGE"
  exit 1
  ;;
esac

hsts_value="max-age=${ANGIE_HSTS_MAX_AGE}"

case "${ANGIE_HSTS_INCLUDE_SUBDOMAINS}" in
yes | on | 1 | true | enable | enabled)
  hsts_value="${hsts_value}; includeSubDomains"
  ;;
esac

# Zero is the supported way back, not an error: it tells clients to forget the
# entry at once. Unlike a disabled toggle the header keeps being sent, which is
# the only reason the retreat works; switching the toggle off revokes nothing.
if [ "$ANGIE_HSTS_MAX_AGE" -eq 0 ]; then
  ngx_warning "ANGIE_HSTS_MAX_AGE is 0: this tells clients to forget the HSTS entry immediately; keep it enabled until every client has been served once, then switch the toggle off"
fi

# Render the active config from the pristine template every start (same
# pattern as 35-real-ip.sh, 40-acme.sh and 40-status-api.sh). The value is
# built here from a number and a literal, so the '|' delimiter is safe.
hsts_conf="${HTTP_CONF_AVAILABLE_DIR}/056-hsts.conf"
sed -e "s|%%HSTS_VALUE%%|${hsts_value}|g" "${hsts_conf}.template" >"$hsts_conf"

ngx_ctl httpconf en 056-hsts.conf &&
  ngx_info "HSTS is enabled over https: ${hsts_value}"
