#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

# Real IP is opt-in by presence: setting ANGIE_REAL_IP_FROM (the trusted proxy
# list) turns the feature on, mirroring the GEOIP2_DB_COUNTRY convention. No
# separate _ENABLED flag.
if [ -z "${ANGIE_REAL_IP_FROM:-}" ]; then
  exit 0
fi

: "${ANGIE_REAL_IP_HEADER:=X-Forwarded-For}"
: "${ANGIE_REAL_IP_RECURSIVE:=on}"

# The trusted-proxy entries are substituted into config directives. Restrict each
# to an IPv4/IPv6/CIDR charset so a value cannot break out of the directive
# (config injection) or abort the rendering below. The list is space- or
# comma-separated.
real_ip_from_directives=""
for _entry in $(printf '%s' "$ANGIE_REAL_IP_FROM" | tr ',' ' '); do
  case "$_entry" in
  *[!0-9a-fA-F:./]*)
    ngx_err "ANGIE_REAL_IP_FROM entry has unsupported characters (allowed: 0-9 a-f A-F : . /): $_entry"
    exit 1
    ;;
  esac
  real_ip_from_directives="${real_ip_from_directives}set_real_ip_from ${_entry};
"
done

if [ -z "$real_ip_from_directives" ]; then
  ngx_warning "ANGIE_REAL_IP_FROM is set but yielded no valid entries; skipping real_ip"
  exit 0
fi

# real_ip_header accepts the proxy_protocol keyword or a request header field
# name. Both fit [A-Za-z0-9_-]; reject anything else before substitution.
case "$ANGIE_REAL_IP_HEADER" in
*[!A-Za-z0-9_-]*)
  ngx_err "ANGIE_REAL_IP_HEADER has unsupported characters (allowed: A-Za-z0-9 _ -): $ANGIE_REAL_IP_HEADER"
  exit 1
  ;;
esac

case "$ANGIE_REAL_IP_RECURSIVE" in
on | off) ;;
*)
  ngx_err "ANGIE_REAL_IP_RECURSIVE must be 'on' or 'off', got: $ANGIE_REAL_IP_RECURSIVE"
  exit 1
  ;;
esac

# Render the active config from the pristine template every start: idempotent
# across restarts (a changed proxy list is re-applied) and the template is never
# mutated in place. The multi-line set_real_ip_from block is spliced in with
# sed's `r` (append after the placeholder line) then the placeholder is deleted;
# the validated charsets above keep the '|' delimiter and the directives safe.
real_ip_conf="${HTTP_CONF_AVAILABLE_DIR}/015-real-ip.conf"
directives_file=$(mktemp)
# Clean up the temp file on any exit: under `set -e` a sed failure would abort
# before an explicit rm could run.
trap 'rm -f "$directives_file"' EXIT
printf '%s' "$real_ip_from_directives" >"$directives_file"
sed \
  -e "/%%REAL_IP_FROM_DIRECTIVES%%/r ${directives_file}" \
  -e "/%%REAL_IP_FROM_DIRECTIVES%%/d" \
  -e "s|%%REAL_IP_HEADER%%|${ANGIE_REAL_IP_HEADER}|g" \
  -e "s|%%REAL_IP_RECURSIVE%%|${ANGIE_REAL_IP_RECURSIVE}|g" \
  "${real_ip_conf}.template" >"$real_ip_conf"

angie-ctl httpconf en 015-real-ip.conf &&
  ngx_info "Real IP configured for trusted proxies: ${ANGIE_REAL_IP_FROM}"
