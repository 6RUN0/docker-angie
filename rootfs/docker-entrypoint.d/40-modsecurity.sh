#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_MODSECURITY_ENABLED:=no}"

# Reset the ModSecurity module before re-enabling per env, so disabling it
# (clearing ANGIE_MODSECURITY_ENABLED) actually unloads it on a persistent
# /etc/angie volume instead of leaving the load_module stuck on.
reset_module http_modsecurity.conf

case "${ANGIE_MODSECURITY_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl mod en "http_modsecurity.conf" &&
    ngx_info "ModSecurity module is enabled"
  ;;
esac
