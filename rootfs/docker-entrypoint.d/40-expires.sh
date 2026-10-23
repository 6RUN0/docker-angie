#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_EXPIRES_ENABLED:=no}"

# Reset before re-enabling per env (declarative toggle, see
# docker-entrypoint-common.sh). map is core, so an orphan never breaks
# `angie -t`.
#
# The toggle enables only the map declaration; the expires directive lives in
# snippets/expires-by-type.conf, included by the consumer. The reverse fails
# startup: the snippet without the map finds no variable.
reset_httpconf 023-expires.conf

case "${ANGIE_EXPIRES_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl httpconf en "023-expires.conf" &&
    ngx_info "expires map by content type is enabled"
  ;;
esac
