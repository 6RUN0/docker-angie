#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_GZIP_ENABLED:=no}"
: "${ANGIE_GZIP_STATIC_ENABLE:=no}"

enable_gzip() {
  angie-ctl httpconf en "020-gzip.conf" &&
    ngx_info "gzip configuration is enabled"
}

enable_gzip_static() {
  enable_gzip
  angie-ctl httpconf en "021-gzip_static.conf" &&
    ngx_info "gzip static compression enabled"
}

case "${ANGIE_GZIP_STATIC_ENABLE}" in
yes | on | 1 | true | enable | enabled)
  enable_gzip_static
  exit 0
  ;;
esac

case "${ANGIE_GZIP_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  enable_gzip
  exit 0
  ;;
esac
