#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_MODSECURITY_ENABLE:=no}"

case "${ANGIE_MODSECURITY_ENABLE}" in
yes | on | 1 | true | enable | enabled)
  angie-ctl mod en "http_modsecurity.conf" &&
    ngx_info "ModSecurity module is enabled"
  ;;
esac
