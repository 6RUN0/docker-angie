#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_SECURITY_HEADERS_ENABLED:=no}"

# Reset security headers before re-enabling per env, so disabling them
# (clearing ANGIE_SECURITY_HEADERS_ENABLED) actually takes effect on a
# persistent /etc/angie volume instead of leaving the snippet stuck on. These
# are core add_header directives, so the orphan never breaks `angie -t`.
reset_httpconf 055-security-headers.conf

case "${ANGIE_SECURITY_HEADERS_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl httpconf en "055-security-headers.conf" &&
    ngx_info "Security headers are enabled"
  ;;
esac
