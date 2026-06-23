#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_SUBS_ENABLED:=no}"

case "${ANGIE_SUBS_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  angie-ctl mod en "http_subs_filter.conf" &&
    ngx_info "Substitutions module enabled"
  ;;
esac
