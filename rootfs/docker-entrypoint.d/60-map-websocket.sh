#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_MAP_WEBSOCKET_ENABLE:=no}"

case "${ANGIE_MAP_WEBSOCKET_ENABLE}" in
yes | on | 1 | true | enable | enabled)
  angie-ctl httpconf en "060-map-websocket.conf" &&
    ngx_info "variable map for WebSocket is enabled"
  ;;
esac
