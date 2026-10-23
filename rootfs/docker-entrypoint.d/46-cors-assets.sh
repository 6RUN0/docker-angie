#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_CORS_ASSETS_ENABLED:=no}"

# Reset before re-enabling per env (declarative toggle, see
# docker-entrypoint-common.sh). map and add_header are core, so an orphan never
# breaks `angie -t`.
reset_httpconf 057-cors-assets.conf

case "${ANGIE_CORS_ASSETS_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl httpconf en "057-cors-assets.conf" &&
    ngx_info "CORS for fonts and images is enabled"
  ;;
esac
