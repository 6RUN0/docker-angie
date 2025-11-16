#!/bin/sh -e

. /docker-entrypoint-common.sh

if [ -z "${GEOIP2_DB_COUNTRY:-}" ]; then
  exit 0
fi

if [ ! -r "${GEOIP2_DB_COUNTRY}" ]; then
  ngx_warning "GeoIP database '$GEOIP2_DB_COUNTRY' not found"
  exit 0
fi

: "${ANGIE_LOG_FORMAT_LOGFMT_GEOIP2:=no}"
: "${ANGIE_LOG_LOGFMT_GEOIP2:=no}"

angie-ctl mod en http_geoip2.conf &&
  ngx_info "GeoIP2 module enabled"

sed -i -e "s/%%GEOIP2_DB_COUNTRY%%/$GEOIP2_DB_COUNTRY/" /etc/angie/http-conf-available.d/025-geoip2.conf
angie-ctl httpconf en 025-geoip2.conf &&
  ngx_info "GeoIP2 database configured: ${GEOIP2_DB_COUNTRY}"

case "${ANGIE_LOG_FORMAT_LOGFMT_GEOIP2}" in
yes | on | 1 | true | enable | enabled)
  enable_log_format "logfmt-with-geoip2"
  ;;
esac

case "${ANGIE_LOG_LOGFMT_GEOIP2}" in
yes | on | 1 | true | enable | enabled)
  enable_log "logfmt-with-geoip2"
  ;;
esac
