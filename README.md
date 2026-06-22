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

### Build arguments

- `DEBIAN_MIRROR` / `DEBIAN_SECURITY_MIRROR` (Debian only) default to the
  official `https://deb.debian.org`. Point them at a local mirror to speed up
  builds:

  ```bash
  docker build -t angie-debian -f debian/Dockerfile \
    --build-arg DEBIAN_MIRROR=http://mirror.example.org/debian \
    --build-arg DEBIAN_SECURITY_MIRROR=http://mirror.example.org/debian-security .
  ```

- `ANGIE_CTL_COMMIT` pins the commit of the angie-ctl helper.

### Makefile

A `Makefile` orchestrates the common tasks:

```bash
make lint     # shellcheck (POSIX sh) + hadolint
make build    # build both images
make test     # build + smoke-test both images
```

## Notes

- The default configuration increases `worker_connections` and `worker_rlimit_nofile` to 65536
to support high concurrency. Adjust these values in `rootfs/etc/angie/angie.conf` if necessary.

- The entrypoint installs **angie‑ctl** (from the commit specified in the build argument `ANGIE_CTL_COMMIT`) into `/usr/local/bin`.
This utility is used to enable or disable configuration snippets and modules at runtime.

## Health check

Both images define a `HEALTHCHECK` that probes `GET /healthz` on port 80 — the
default server answers it with `200 ok`. Every other request to an unmatched
host is denied with `444` (connection closed), which drops scanner / stray
Host-header noise. Add your own server blocks via the custom volume to serve
real traffic.

## Configuration is applied at container creation

The entrypoint enables snippets and (optionally) rewrites `worker_processes`
once, at container start, and guards against re-applying. Changing an `ANGIE_*`
variable therefore takes effect by **recreating** the container, not by
`docker restart` (a restart reuses the already-configured writable layer). Treat
the container as disposable: change env, recreate.

## Running as non-root

The default images run as root and the Angie master drops worker processes to
the `angie` user — the conventional nginx model. Under `docker run --user` the
entrypoint skips privileged setup (ownership fixes, `worker_processes` autotune)
with a notice, but the regular image is **not** fully rootless: angie still needs
root-owned paths (pidfile, temp dirs) and binds port 80.

For a fully rootless deployment use the **unprivileged** image variant, built on
top of the regular one (`alpine/Dockerfile.unprivileged`,
`debian/Dockerfile.unprivileged`). It moves the pidfile and temp paths into
`/tmp` and listens on **8080**, so it runs under any uid with no added
capabilities:

```bash
make build-alpine-unprivileged          # or build-debian-unprivileged
docker run --user 65534:65534 -p 8080:8080 angie-alpine-unprivileged
```

Runtime `ANGIE_*` toggles are baked in at build time for this variant (a non-root
uid cannot rewrite `/etc/angie/*.d`); customize it via the `/etc/angie/custom`
volume or by deriving your own image.

## ModSecurity (WAF)

`ANGIE_MODSECURITY_ENABLE=yes` loads the ModSecurity module, but the image ships
**no rules** — enabling it alone blocks nothing. Provide an engine config and a
ruleset (e.g. the [OWASP Core Rule Set](https://coreruleset.org/)) through the
`/etc/angie/custom` volume and reference them from a server or location:

1. Mount a `modsecurity.conf` with `SecRuleEngine On` plus your `Include`
   directives, and the rules themselves, under `/etc/angie/custom`.
2. Turn it on in a custom server block:

   ```nginx
   # /etc/angie/custom/http.d/app.conf
   server {
     listen 80;
     server_name app.example.com;

     modsecurity on;
     modsecurity_rules_file /etc/angie/custom/modsecurity/main.conf;

     # ... your locations ...
   }
   ```

## Testing

`make test` builds each image and runs `test/smoke.sh`, which starts the
container and asserts the toggles (gzip / brotli / log format), the `/healthz`
and `444` behavior, fail-fast on a broken entrypoint script, and non-root
startup. CI runs the same on every push and pull request; tagged `v*` releases
publish multi-arch images to `ghcr.io`.

## See also

- [Angie installation](https://angie.software/installation/)
