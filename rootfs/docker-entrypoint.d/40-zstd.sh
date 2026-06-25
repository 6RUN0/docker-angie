#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_ZSTD_ENABLED:=no}"
: "${ANGIE_ZSTD_STATIC_ENABLED:=no}"

# Reset zstd before re-enabling per env, so disabling it (clearing the
# ANGIE_ZSTD_* variables) actually takes effect on a persistent /etc/angie
# volume instead of leaving an orphaned `zstd on;` whose module might no longer
# be loaded. Disable the config (consumer of the module directives) before the
# module itself.
reset_httpconf 021-zstd_static.conf 020-zstd.conf
reset_module http_zstd_static.conf http_zstd_filter.conf

enable_zstd() {
  ngx_ctl mod en "http_zstd_filter.conf" &&
    ngx_info "Zstd module is enabled"
  ngx_ctl httpconf en "020-zstd.conf" &&
    ngx_info "Zstd configuration is enabled"
}

enable_zstd_static() {
  enable_zstd
  ngx_ctl mod en "http_zstd_static.conf" &&
    ngx_info "Zstd static module is enabled"
  ngx_ctl httpconf en "021-zstd_static.conf" &&
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
