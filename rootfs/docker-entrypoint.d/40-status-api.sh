#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_STATUS_API_ENABLED:=no}"

# Reset before deciding whether the API is on this start, so clearing
# ANGIE_STATUS_API_ENABLED actually takes effect on a persistent /etc/angie
# volume instead of leaving the listener stuck on.
reset_httpconf 070-status-api.conf

case "${ANGIE_STATUS_API_ENABLED}" in
yes | on | 1 | true | enable | enabled) ;;
*)
  exit 0
  ;;
esac

: "${ANGIE_STATUS_API_HOST:=0.0.0.0}"
: "${ANGIE_STATUS_API_PORT:=8181}"

# Both values are substituted into a `listen` directive. Restrict them to an
# address/port charset so a value cannot break out of the directive (config
# injection), mirroring the real-ip and geoip2 guards. The host set covers
# IPv4, bracketed IPv6, and the `*` wildcard; hostnames are deliberately not
# accepted. In a bracket expression `]` must come first to be literal.
case "$ANGIE_STATUS_API_HOST" in
'' | *[!]0-9a-fA-F:.[*]*)
  ngx_err "ANGIE_STATUS_API_HOST has unsupported characters (allowed: 0-9 a-f A-F : . [ ] *): $ANGIE_STATUS_API_HOST"
  exit 1
  ;;
esac

case "$ANGIE_STATUS_API_PORT" in
'' | *[!0-9]*)
  ngx_err "ANGIE_STATUS_API_PORT must be a decimal port number, got: $ANGIE_STATUS_API_PORT"
  exit 1
  ;;
esac
if [ "$ANGIE_STATUS_API_PORT" -lt 1 ] || [ "$ANGIE_STATUS_API_PORT" -gt 65535 ]; then
  ngx_err "ANGIE_STATUS_API_PORT out of range 1-65535: $ANGIE_STATUS_API_PORT"
  exit 1
fi

# Render the active config from the pristine template every start: idempotent
# across restarts (a changed host/port is re-applied) and the template is never
# mutated in place (same pattern as 35-real-ip.sh).
status_api_conf="${HTTP_CONF_AVAILABLE_DIR}/070-status-api.conf"
sed \
  -e "s|%%STATUS_API_HOST%%|${ANGIE_STATUS_API_HOST}|g" \
  -e "s|%%STATUS_API_PORT%%|${ANGIE_STATUS_API_PORT}|g" \
  "${status_api_conf}.template" >"$status_api_conf"

ngx_ctl httpconf en 070-status-api.conf &&
  ngx_info "Status API and Prometheus metrics listening on ${ANGIE_STATUS_API_HOST}:${ANGIE_STATUS_API_PORT}"
