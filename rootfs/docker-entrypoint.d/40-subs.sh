#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_SUBS_ENABLED:=no}"

# Reset the substitutions module before re-enabling per env (declarative
# toggle, see docker-entrypoint-common.sh): only ANGIE_SUBS_ENABLED loads it.
reset_module http_subs_filter.conf

case "${ANGIE_SUBS_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl mod en "http_subs_filter.conf" &&
    ngx_info "Substitutions module enabled"
  ;;
esac
