#!/bin/sh -e

. /docker-entrypoint-common.sh

# Reset real-ip before deciding whether it is on this start (declarative
# toggle, see docker-entrypoint-common.sh). An active 015-real-ip.conf would
# otherwise keep trusting a stale set_real_ip_from list after the operator
# removed ANGIE_REAL_IP_FROM. Core realip directives never fail `angie -t`, so
# this is a silent security trap rather than a startup break: a stale
# trusted-proxy range lets a client forge the real-ip header and spoof
# $remote_addr.
reset_httpconf 015-real-ip.conf

# Real IP is opt-in by presence: setting ANGIE_REAL_IP_FROM (the trusted proxy
# list) turns the feature on, mirroring the GEOIP2_DB_COUNTRY convention. No
# separate _ENABLED flag.
if [ -z "${ANGIE_REAL_IP_FROM:-}" ]; then
  exit 0
fi

: "${ANGIE_REAL_IP_HEADER:=X-Forwarded-For}"
: "${ANGIE_REAL_IP_RECURSIVE:=on}"

# real_ip_header accepts the proxy_protocol keyword or a request header field
# name. Both fit [A-Za-z0-9_-]; reject anything else before substitution and
# before the messages below that name the header. The refusal does not echo the
# value: a newline in it would forge a line in a plain-text log.
case "$ANGIE_REAL_IP_HEADER" in
*[!A-Za-z0-9_-]*)
  ngx_err "ANGIE_REAL_IP_HEADER has unsupported characters (allowed: A-Za-z0-9 _ -)"
  exit 1
  ;;
esac

# The trusted-proxy entries are substituted into config directives. Restrict each
# to an IPv4/IPv6/CIDR charset so a value cannot break out of the directive
# (config injection) or abort the rendering below. The list is space- or
# comma-separated.
#
# Globbing is off for the loop: the unquoted expansion is needed for word
# splitting, but would also expand `*`, `?` and `[` against the working dir
# (`/` for the entrypoint). `set -f` is shell-wide, so it is restored right
# after the loop.
real_ip_from_directives=""
set -f
for _entry in $(printf '%s' "$ANGIE_REAL_IP_FROM" | tr ',' ' '); do
  case "$_entry" in
  *[!0-9a-fA-F:./]*)
    ngx_err "ANGIE_REAL_IP_FROM entry has unsupported characters (allowed: 0-9 a-f A-F : . /): $_entry"
    exit 1
    ;;
  esac
  case "$_entry" in
  # A zero-length mask trusts the whole address space (0.0.0.0/0, ::/0,
  # 10.0.0.1/0), and a pair of short ones does too: any client could set its
  # $remote_addr by header. No real proxy setup needs a prefix shorter than /8
  # (IPv4) or /16 (IPv6), so those are refused.
  */*)
    # Leading zeros are stripped: angie reads /0001 as /1. A non-numeric mask
    # is left for `angie -t` to reject.
    _prefix=$(printf '%s' "${_entry##*/}" | sed 's/^0*//')
    case "$_entry" in
    *:*) _min_prefix=16 ;;
    *) _min_prefix=8 ;;
    esac
    case "${_entry##*/}" in
    '' | *[!0-9]*) ;;
    *)
      if [ -z "$_prefix" ]; then
        ngx_err "ANGIE_REAL_IP_FROM entry $_entry trusts every address, so any client could forge its address with the ${ANGIE_REAL_IP_HEADER} header. List the addresses or the subnet of your proxies instead, for example ANGIE_REAL_IP_FROM=172.18.0.0/16"
        exit 1
      fi
      if [ "${#_prefix}" -le 2 ] && [ "$_prefix" -lt "$_min_prefix" ]; then
        ngx_err "ANGIE_REAL_IP_FROM entry $_entry has a prefix shorter than /$_min_prefix, so any client in that range could forge its address with the ${ANGIE_REAL_IP_HEADER} header. List the addresses or the subnet of your proxies instead, for example ANGIE_REAL_IP_FROM=172.18.0.0/16"
        exit 1
      fi
      ;;
    esac
    ;;
  esac
  real_ip_from_directives="${real_ip_from_directives}set_real_ip_from ${_entry};
"
done
set +f

if [ -z "$real_ip_from_directives" ]; then
  ngx_warning "ANGIE_REAL_IP_FROM is set but yielded no valid entries; skipping real_ip"
  exit 0
fi

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
#
# The temp file sits next to the snippet in the live tree, which 10-conf-overlay.sh
# has proven writable; a bare `mktemp` targets /tmp, which is read-only under
# `docker run --read-only`. A dot-prefixed non-.conf name is never picked up by
# the include masks or the reset_httpconf patterns if it is orphaned.
real_ip_conf="${HTTP_CONF_AVAILABLE_DIR}/015-real-ip.conf"
directives_file=$(mktemp "${HTTP_CONF_AVAILABLE_DIR}/.real-ip-directives.XXXXXX")
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

ngx_ctl httpconf en 015-real-ip.conf &&
  ngx_info "Real IP configured for trusted proxies: ${ANGIE_REAL_IP_FROM}"
