#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_SECURITY_HEADERS_ENABLED:=no}"

# Reset security headers before re-enabling per env (declarative toggle, see
# docker-entrypoint-common.sh). These are core add_header directives, so an
# orphan never breaks `angie -t`.
reset_httpconf 055-security-headers.conf

case "${ANGIE_SECURITY_HEADERS_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl httpconf en "055-security-headers.conf" &&
    ngx_info "Security headers are enabled"
  ;;
esac
