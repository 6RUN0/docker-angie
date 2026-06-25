#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_SUBS_ENABLED:=no}"

# Reset the substitutions module before re-enabling per env, so disabling
# it (clearing ANGIE_SUBS_ENABLED) actually unloads it on a persistent
# /etc/angie volume instead of leaving the load_module stuck on.
reset_module http_subs_filter.conf

case "${ANGIE_SUBS_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  angie-ctl mod en "http_subs_filter.conf" &&
    ngx_info "Substitutions module enabled"
  ;;
esac
