#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_ZSTD_ENABLED:=no}"
: "${ANGIE_ZSTD_STATIC_ENABLED:=no}"

enable_zstd() {
  angie-ctl mod en "http_zstd_filter.conf" &&
    ngx_info "Zstd module is enabled"
  angie-ctl httpconf en "020-zstd.conf" &&
    ngx_info "Zstd configuration is enabled"
}

enable_zstd_static() {
  enable_zstd
  angie-ctl mod en "http_zstd_static.conf" &&
    ngx_info "Zstd static module is enabled"
  angie-ctl httpconf en "021-zstd_static.conf" &&
    ngx_info "Zstd static compression enabled"
}

case "${ANGIE_ZSTD_STATIC_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  enable_zstd_static
  exit 0
  ;;
esac

case "${ANGIE_ZSTD_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  enable_zstd
  exit 0
  ;;
esac
