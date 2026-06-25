#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_MAP_WEBSOCKET_ENABLED:=no}"

# Reset the WebSocket map before re-enabling per env, so disabling it
# (clearing ANGIE_MAP_WEBSOCKET_ENABLED) actually takes effect on a persistent
# /etc/angie volume instead of leaving the snippet stuck on. The map directive
# is core, so the orphan never breaks `angie -t`.
reset_httpconf 060-map-websocket.conf

case "${ANGIE_MAP_WEBSOCKET_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  angie-ctl httpconf en "060-map-websocket.conf" &&
    ngx_info "variable map for WebSocket is enabled"
  ;;
esac
