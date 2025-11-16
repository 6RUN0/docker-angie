#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_BROTLI_ENABLED:=no}"
: "${ANGIE_BROTLI_STATIC_ENABLE:=no}"

enable_brotli() {
  angie-ctl mod en "http_brotli_filter.conf" &&
    ngx_info "Brotli module is enabled"
  angie-ctl httpconf en "020-brotli.conf" &&
    ngx_info "Brotli configuration is enabled"
}

enable_brotli_static() {
  enable_brotli
  angie-ctl mod en "http_brotli_static.conf" &&
    ngx_info "Brotli static module is enabled"
  angie-ctl httpconf en "021-brotli_static.conf" &&
    ngx_info "Brotli static compression enabled"
}

case "${ANGIE_BROTLI_STATIC_ENABLE}" in
yes | on | 1 | true | enable | enabled)
  enable_brotli_static
  exit 0
  ;;
esac

case "${ANGIE_BROTLI_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  enable_brotli
  exit 0
  ;;
esac
