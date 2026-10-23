#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_GZIP_ENABLED:=no}"
: "${ANGIE_GZIP_STATIC_ENABLED:=no}"

# Reset gzip before re-enabling per env (declarative toggle, see
# docker-entrypoint-common.sh). gzip is core (no module), so an orphan never
# breaks `angie -t`; this only prevents "stuck enabled". Static before base.
reset_httpconf 021-gzip_static.conf 020-gzip.conf

enable_gzip() {
  ngx_ctl httpconf en "020-gzip.conf" &&
    ngx_info "gzip configuration is enabled"
}

enable_gzip_static() {
  enable_gzip
  ngx_ctl httpconf en "021-gzip_static.conf" &&
    ngx_info "gzip static compression enabled"
}

case "${ANGIE_GZIP_STATIC_ENABLED}" in
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
