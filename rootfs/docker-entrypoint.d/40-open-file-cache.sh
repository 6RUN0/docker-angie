#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_OPEN_FILE_CACHE_ENABLED:=no}"

# Reset before re-enabling per env (declarative toggle, see
# docker-entrypoint-common.sh). open_file_cache* are core, so an orphan never
# breaks `angie -t`.
reset_httpconf 024-open-file-cache.conf

case "${ANGIE_OPEN_FILE_CACHE_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl httpconf en "024-open-file-cache.conf" &&
    ngx_info "open file cache is enabled"
  ;;
esac
