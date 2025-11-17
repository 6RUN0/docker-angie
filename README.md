# Angie Docker Images with Extended Modules

This repository provides custom Docker images for the [Angie web server](https://angie.software)
with additional modules and configuration options.
It supports both Alpine and Debian bases and includes modules
for Brotli compression, GeoIP2, ModSecurity (WAF), and the substitutions filter.

## Modules included

The following third‑party modules are compiled and available:

- [ngx_brotli](https://github.com/google/ngx_brotli) - dynamic and static Brotli compression.
- [ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module) - GeoIP2 lookup by client IP.
- [ModSecurity‑nginx](https://github.com/owasp-modsecurity/ModSecurity-nginx) - ModSecurity web application firewall.
- [ngx_http_substitutions_filter_module](https://github.com/yaoweibin/ngx_http_substitutions_filter_module) - response body substitutions.

These modules are shipped as dynamic modules.
They are not enabled automatically; you need to turn them
on at runtime through the environment variables documented below.

## Volumes

- `/etc/angie/custom` — for custom Angie configuration

## Environment Variables

| Variable | Description | Default |
| -------- | ----------- | ------- |
| `ANGIE_ENTRYPOINT_QUIET_LOGS` | Suppress informational messages from the entrypoint (only warnings and errors will be printed). | unset |
| `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` | Tune `worker_processes` at runtime based on the number of CPU cores (has no effect if `/etc/angie/angie.conf` is read‑only). | unset |
| `ANGIE_BROTLI_ENABLED` | Load the Brotli filter module and enable Brotli compression. | `no` |
| `ANGIE_BROTLI_STATIC_ENABLE` | Enable Brotli plus serving pre‑compressed files (`*.br`). Implies `ANGIE_BROTLI_ENABLED`. | `no` |
| `ANGIE_GZIP_ENABLED` | Enable gzip compression. | `no` |
| `ANGIE_GZIP_STATIC_ENABLE` | Enable serving pre‑compressed gzip files (`*.gz`). Implies `ANGIE_GZIP_ENABLED`. | `no` |
| `ANGIE_MODSECURITY_ENABLE` | Enable the ModSecurity module. | `no` |
| `ANGIE_SUBS_ENABLE` | Enable the substitutions filter module. | `no` |
| `GEOIP2_DB_COUNTRY` | Absolute path to a GeoIP2 country database. When set and the file is readable, the GeoIP2 module and its configuration are enabled. | unset |
| `ANGIE_LOG_FORMAT_EXTENDED` | Register the `extended` log format. Does not change the active log unless one of the `ANGIE_LOG_*` variables below is set. | `no` |
| `ANGIE_LOG_FORMAT_LOGFMT` | Register the `logfmt` log format (key=value pairs). Enabled by default because this format is used for the default access log. | `yes` |
| `ANGIE_LOG_FORMAT_MAIN` | Register the classic `main` log format. | `no` |
| `ANGIE_LOG_FORMAT_MATOMO` | Register the `matomo` log format compatible with the Matomo analytics platform. | `no` |
| `ANGIE_LOG_EXTENDED` | Use the `extended` log format for `/dev/stdout`. | `no` |
| `ANGIE_LOG_LOGFMT` | Use the `logfmt` log format for `/dev/stdout`. | `yes` |
| `ANGIE_LOG_MAIN` | Use the `main` log format for `/dev/stdout`. | `no` |
| `ANGIE_LOG_MATOMO` | Use the `matomo` log format for `/dev/stdout`. | `no` |
| `ANGIE_LOG_FORMAT_LOGFMT_GEOIP2` | When using GeoIP2, register the `logfmt-with-geoip2` log format (adds a `country` field) without activating it. | `no` |
| `ANGIE_LOG_LOGFMT_GEOIP2` | When using GeoIP2, use the `logfmt-with-geoip2` log format for `/dev/stdout`. | `no` |
| `ANGIE_MAP_WEBSOCKET_ENABLE` | Enable the WebSocket variable map configuration to simplify upstream WebSocket proxying. | `no` |
| `CACHE_DIR` | If set, the entrypoint will change ownership of the specified cache directory to the `angie` user (useful with a bind‑mounted cache). | unset |

## Building

Use the provided Dockerfiles to build the images yourself:

```bash
# Build Alpine‑based image
docker build -t angie‑alpine -f alpine/Dockerfile .
# Build Debian‑based image
docker build -t angie‑debian -f debian/Dockerfile .
```

Alternatively, use the included `docker‑compose.yml` to build and run all variants:

```bash
docker compose up --build
```

## Notes

- The default configuration increases `worker_connections` and `worker_rlimit_nofile` to 65536
to support high concurrency. Adjust these values in `rootfs/etc/angie/angie.conf` if necessary.

- The entrypoint installs **angie‑ctl** (from the commit specified in the build argument `ANGIE_CTL_COMMIT`) into `/usr/local/bin`.
This utility is used to enable or disable configuration snippets and modules at runtime.

## See also

- [Angie installation](https://angie.software/installation/)
