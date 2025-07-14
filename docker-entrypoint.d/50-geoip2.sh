#!/bin/sh -e

. /docker-entrypoint-common.sh

if [ -z "$GEOIP2_DB_COUNTRY" ]; then
  exit 0
fi

if [ ! -r "$GEOIP2_DB_COUNTRY" ]; then
  ngx_warning "GeoIP database '$GEOIP2_DB_COUNTRY' not found"
  exit 0
fi

cat <<EOF >/etc/angie/modules.d/geoip2_http.conf
load_module modules/ngx_http_geoip2_module.so;
EOF

cat <<EOF >/etc/angie/http-conf.d/025-geoip2.conf
geoip2 $GEOIP2_DB_COUNTRY {
  auto_reload 1h;
  \$geoip2_country_code default=ZZ source=\$remote_addr country iso_code;
}
EOF

cat <<EOF >/etc/angie/http-conf.d/030-log-format-loki-with-geoip2.conf
# Loki log format with geoip
log_format loki_with_geoip 'remote_addr=\$remote_addr'
  ' remote_user=\$remote_user'
  ' host=\$host'
  ' path=\$request_uri'
  ' method=\$request_method'
  ' status=\$status'
  ' referrer=\$http_referer'
  ' user_agent="\$http_user_agent"'
  ' length=\$bytes_sent'
  ' gzip_ratio=\$gzip_ratio'
  ' brotli_ratio=\$brotli_ratio'
  ' request_time=\$request_time'
  ' upstream_addr=\$upstream_addr'
  ' date=\$time_iso8601'
  ' country="\$geoip2_country_code"'
  ' request_id=\$request_id';
EOF

cat <<EOF >etc/angie/http-conf.d/040-log.conf
# Logging Settings
access_log /dev/stdout loki_with_geoip;
error_log /dev/stderr;
EOF
