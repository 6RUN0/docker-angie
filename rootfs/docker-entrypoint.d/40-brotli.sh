#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_BROTLI_ENABLED:=no}"
: "${ANGIE_BROTLI_STATIC_ENABLED:=no}"

# Reset brotli before re-enabling per env (declarative toggle, see
# docker-entrypoint-common.sh), so no orphaned `brotli on;` outlives its
# module. Disable the config (consumer of the module directives) before the
# module itself.
reset_httpconf 021-brotli_static.conf 020-brotli.conf
reset_module http_brotli_static.conf http_brotli_filter.conf

enable_brotli() {
  ngx_ctl mod en "http_brotli_filter.conf" &&
    ngx_info "Brotli module is enabled"
  ngx_ctl httpconf en "020-brotli.conf" &&
    ngx_info "Brotli configuration is enabled"
}

enable_brotli_static() {
  enable_brotli
  ngx_ctl mod en "http_brotli_static.conf" &&
    ngx_info "Brotli static module is enabled"
  ngx_ctl httpconf en "021-brotli_static.conf" &&
    ngx_info "Brotli static compression enabled"
}

case "${ANGIE_BROTLI_STATIC_ENABLED}" in
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
