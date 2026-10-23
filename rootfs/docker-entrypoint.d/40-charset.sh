#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_CHARSET_UTF8_ENABLED:=no}"

# Reset before re-enabling per env (declarative toggle, see
# docker-entrypoint-common.sh). charset and charset_types are core, so an
# orphan never breaks `angie -t`.
reset_httpconf 011-charset.conf

case "${ANGIE_CHARSET_UTF8_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl httpconf en "011-charset.conf" &&
    ngx_info "UTF-8 charset for text responses is enabled"
  ;;
esac
