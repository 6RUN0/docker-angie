#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_MODSECURITY_ENABLED:=no}"

# Reset the ModSecurity module before re-enabling per env (declarative toggle,
# see docker-entrypoint-common.sh): only ANGIE_MODSECURITY_ENABLED loads it.
reset_module http_modsecurity.conf

case "${ANGIE_MODSECURITY_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl mod en "http_modsecurity.conf" &&
    ngx_info "ModSecurity module is enabled"
  ;;
esac
