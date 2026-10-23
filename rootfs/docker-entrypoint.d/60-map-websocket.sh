#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_MAP_WEBSOCKET_ENABLED:=no}"

# Reset the WebSocket map before re-enabling per env (declarative toggle, see
# docker-entrypoint-common.sh). The map directive is core, so an orphan never
# breaks `angie -t`.
reset_httpconf 060-map-websocket.conf

case "${ANGIE_MAP_WEBSOCKET_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl httpconf en "060-map-websocket.conf" &&
    ngx_info "variable map for WebSocket is enabled"
  ;;
esac
