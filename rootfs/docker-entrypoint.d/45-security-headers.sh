#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_SECURITY_HEADERS_ENABLED:=no}"

case "${ANGIE_SECURITY_HEADERS_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  angie-ctl httpconf en "055-security-headers.conf" &&
    ngx_info "Security headers are enabled"
  ;;
esac
