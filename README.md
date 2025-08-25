# Custom docker image, based on Aline Linux for Angie

Added modules:

- [brotli](https://github.com/google/ngx_brotli)
- [geoip2](https://github.com/leev/ngx_http_geoip2_module)
- [modsecurity](https://github.com/owasp-modsecurity/ModSecurity-nginx)
- [ngx_http_subs_filter_module](https://github.com/yaoweibin/ngx_http_substitutions_filter_module)

## Volumes

- `/etc/angie/custom` — for custom Angie configuration

## Environment Variables

| Variable | Description | Default |
|--------- |-------------|---------|
| ANGIE_ENTRYPOINT_QUIET_LOGS | If set, suppresses entrypoint logs (except errors). | unset |
| ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE | If set, enables autotuning of worker processes in Angie. | unset |
| CACHE_DIR | If set, changes ownership of the specified cache directory to user 'angie'. | unset |
| GEOIP2_DB_COUNTRY | Path to the GeoIP2 country database for Angie GeoIP2 module. | unset |

No other environment variables or build arguments are defined by default.

## See also

- [Angie installation](https://angie.software/installation/)
