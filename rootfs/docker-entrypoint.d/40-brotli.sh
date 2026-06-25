#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_BROTLI_ENABLED:=no}"
: "${ANGIE_BROTLI_STATIC_ENABLED:=no}"

# Reset brotli before re-enabling per env, so disabling it (clearing the
# ANGIE_BROTLI_* variables) actually takes effect on a persistent /etc/angie
# volume instead of leaving an orphaned `brotli on;` whose module might no longer
# be loaded. Disable the config (consumer of the module directives) before the
# module itself.
reset_httpconf 021-brotli_static.conf 020-brotli.conf
reset_module http_brotli_static.conf http_brotli_filter.conf

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
