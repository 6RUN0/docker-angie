# Configuration Reference

This document covers all runtime environment variables, volume mounts, exposed
ports, and build arguments for the `6run0/angie` Docker image.

See also: [../README.md](../README.md)

---

## Environment variables

All toggles accept the same set of truthy values:
`yes`, `on`, `1`, `true`, `enable`, `enabled`.
Any other value (including unset) is treated as disabled.

Feature-toggle variables have no effect when the image is started with a
`docker run --user` UID that does not own the Angie config directories
(`/etc/angie/http-conf.d`, `/etc/angie/modules.d`,
`/etc/angie/http-conf-available.d`). In that case the entrypoint warns and
falls back to the configuration baked in at build time. The unprivileged
(`-unprivileged`) image pre-chowns those directories to its default UID so
runtime toggling works out of the box.

### General

| Variable | Default | Description |
|---|---|---|
| `ANGIE_ENTRYPOINT_QUIET_LOGS` | unset | Suppress informational messages from the entrypoint. Only warnings and errors are printed. Set to any non-empty value to enable. |
| `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` | unset | Tune `worker_processes` at runtime by CPU count (reads cgroup v1/v2 quota and cpuset, takes the minimum). Has no effect if `/etc/angie/angie.conf` is read-only. Set to any non-empty value to enable. |

### Compression

| Variable | Default | Description |
|---|---|---|
| `ANGIE_BROTLI_ENABLED` | `no` | Load the Brotli filter module and enable Brotli on-the-fly compression. |
| `ANGIE_BROTLI_STATIC_ENABLED` | `no` | Enable Brotli compression and serving of pre-compressed `*.br` files. Implies `ANGIE_BROTLI_ENABLED`. |
| `ANGIE_GZIP_ENABLED` | `no` | Enable gzip on-the-fly compression. |
| `ANGIE_GZIP_STATIC_ENABLED` | `no` | Enable gzip compression and serving of pre-compressed `*.gz` files. Implies `ANGIE_GZIP_ENABLED`. |
| `ANGIE_ZSTD_ENABLED` | `no` | Load the Zstandard filter module and enable zstd on-the-fly compression (`zstd_comp_level 1`; raise per-vhost via the custom volume). |
| `ANGIE_ZSTD_STATIC_ENABLED` | `no` | Enable zstd compression and serving of pre-compressed `*.zst` files. Implies `ANGIE_ZSTD_ENABLED`. |

> **Note on caching:** only gzip sets `Vary: Accept-Encoding` (via `gzip_vary
> on`); brotli and zstd do **not** emit it on their own. While gzip is enabled
> it adds `Vary` to every response, including those another codec compressed. If
> you enable brotli or zstd **without** gzip behind a shared or CDN cache, the
> cache can hand a compressed body to a client that never requested that
> encoding -- keep gzip enabled, or add `Vary: Accept-Encoding` per-vhost.
> `ANGIE_ZSTD_STATIC_ENABLED` serves a sibling `*.zst` when one exists and the
> client accepts zstd, and silently falls back to on-the-fly compression
> otherwise -- a missing `*.zst` is not an error.

### Dynamic modules

| Variable | Default | Description |
|---|---|---|
| `ANGIE_MODSECURITY_ENABLED` | `no` | Load the ModSecurity module (WAF engine only; no rules ship by default -- mount a ruleset via the custom volume). |
| `ANGIE_SUBS_ENABLED` | `no` | Load the HTTP substitutions filter module. |

### GeoIP2

| Variable | Default | Description |
|---|---|---|
| `GEOIP2_DB_COUNTRY` | unset | Absolute path inside the container to a MaxMind GeoIP2 country database file. When set and the file is readable, the GeoIP2 module and its config snippet are enabled automatically. The path is restricted to the characters `A-Za-z0-9._/-`; any other character is rejected to prevent config injection. |

### Log formats

"Register" variables add the format definition to the Angie config so it can be
referenced; they do not change which format is written to `/dev/stdout`. "Use"
variables both register the format and activate it as the access log on
`/dev/stdout`. Only one "use" variable should be enabled at a time -- enabling
more than one causes each request to be logged multiple times.

| Variable | Default | Description |
|---|---|---|
| `ANGIE_LOG_FORMAT_EXTENDED` | `no` | Register the `extended` log format (detailed fields). Does not change the active log. |
| `ANGIE_LOG_FORMAT_LOGFMT` | `no` | Register the `logfmt` (key=value) format. Does not change the active log. |
| `ANGIE_LOG_FORMAT_MAIN` | `no` | Register the classic `main` log format. Does not change the active log. |
| `ANGIE_LOG_FORMAT_MATOMO` | `no` | Register the `matomo` log format (Matomo analytics). Does not change the active log. |
| `ANGIE_LOG_EXTENDED` | `no` | Register and use the `extended` format for `/dev/stdout`. |
| `ANGIE_LOG_LOGFMT` | `yes` | Register and use the `logfmt` format for `/dev/stdout`. On by default -- the out-of-the-box access log is logfmt. |
| `ANGIE_LOG_MAIN` | `no` | Register and use the `main` format for `/dev/stdout`. |
| `ANGIE_LOG_MATOMO` | `no` | Register and use the `matomo` format for `/dev/stdout`. |
| `ANGIE_LOG_FORMAT_LOGFMT_GEOIP2` | `no` | Requires GeoIP2 active (`GEOIP2_DB_COUNTRY` set and readable). Register the `logfmt-with-geoip2` format (adds `country` field) without activating it. |
| `ANGIE_LOG_LOGFMT_GEOIP2` | `no` | Requires GeoIP2 active (`GEOIP2_DB_COUNTRY` set and readable). Register and use the `logfmt-with-geoip2` format for `/dev/stdout`. |

### Error log

| Variable | Default | Description |
|---|---|---|
| `ANGIE_ERROR_LOG_JSON_ENABLED` | `no` | Switch the error log (`/dev/stderr`) to Angie's structured JSON format: one object per line with `time`, `level`, `pid`, `message`, plus request/upstream context and `tags` when applicable. The field set is fixed by Angie — unlike access-log formats it is not templatable (only `error_log`'s `filter=`/`rate=` parameters and `error_log_user_tag` customize behavior; set those via the custom volume). The toggle rewrites the shipped `error_log` line in `angie.conf` in place and reverts it when unset; it leaves a user-customized `error_log` line alone and is a no-op on a read-only filesystem. |

### WebSocket

| Variable | Default | Description |
|---|---|---|
| `ANGIE_MAP_WEBSOCKET_ENABLED` | `no` | Enable the WebSocket variable map, which sets the `Connection` upgrade header for upstream WebSocket proxying. |

### Real IP

Recover the real client address when the image runs behind a trusted proxy,
load balancer, or ingress (uses the built-in `ngx_http_realip_module`; no
package needed). Enabled by presence: setting `ANGIE_REAL_IP_FROM` turns it on.

| Variable | Default | Description |
|---|---|---|
| `ANGIE_REAL_IP_FROM` | unset | Space- or comma-separated list of trusted proxy addresses/CIDRs (IPv4 or IPv6). When set, the real-IP snippet is rendered and enabled. Each entry is restricted to the characters `0-9 a-f A-F : . /`; any other character is rejected to prevent config injection. |
| `ANGIE_REAL_IP_HEADER` | `X-Forwarded-For` | Header (or the `proxy_protocol` keyword) the real client address is read from. Restricted to `A-Za-z0-9_-`. |
| `ANGIE_REAL_IP_RECURSIVE` | `on` | `on` walks the `X-Forwarded-For` chain right-to-left, skipping trusted addresses, to find the real client behind multiple proxies; `off` uses the last (rightmost) address in the header, the one inserted by your nearest trusted proxy. Must be `on` or `off`. |

> **Security:** list **only** proxies you actually trust. A wildcard such as
> `0.0.0.0/0` lets any client forge the chosen header and spoof `$remote_addr`,
> which also defeats the loopback gate protecting the `/healthz` endpoint. The
> container `HEALTHCHECK` itself is unaffected: it connects to `127.0.0.1`
> without an `X-Forwarded-For` header, so real-IP performs no rewrite and
> `$remote_addr` stays loopback.
>
> **Note:** `ANGIE_REAL_IP_HEADER=proxy_protocol` additionally requires the
> listener to run in PROXY-protocol mode (`listen ... proxy_protocol`), which
> the baked-in `:80` (or `:8080` unprivileged) listener does not. Supply a
> custom vhost with a `proxy_protocol` listener via `/etc/angie/custom` to use
> this mode.

### Security headers

| Variable | Default | Description |
|---|---|---|
| `ANGIE_SECURITY_HEADERS_ENABLED` | `no` | Emit a conservative baseline of response headers (with `always`, so they apply to error responses too): `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN`, `Permissions-Policy: camera=(), microphone=(), geolocation=()`. HSTS, CSP, and the deprecated `X-XSS-Protection` are deliberately omitted -- add them per-vhost via the custom volume. |

> **Note:** `add_header` does **not** merge across contexts. A `server` or
> `location` that defines its own `add_header` replaces the inherited set,
> dropping these headers there. If a custom vhost adds headers, repeat the
> baseline ones too.

### Status API and Prometheus metrics

Expose Angie's built-in monitoring API on a dedicated listener: `/status/`
serves the JSON statistics tree (server info, connections, and -- once you
declare `status_zone`s or upstream `zone`s in your vhosts -- per-zone and
per-upstream metrics, including the certificate and response-time sections
added in Angie 1.12.0), and `/metrics` serves the same data rendered with the
stock `all` Prometheus template. Any other URI on this listener returns `444`.

The port is **not** in the image `EXPOSE` list and is never published by
default: with the default `0.0.0.0` host the listener is reachable from the
container's Docker network (e.g. a Prometheus scraper in a neighbor
container), and from the host only after an explicit publish such as
`-p 127.0.0.1:8181:8181`. The open-source `api` endpoint is read-only
(configuration writes are an Angie PRO feature); restrict access further with
`allow`/`deny` via the custom volume if your network model needs it.

| Variable | Default | Description |
|---|---|---|
| `ANGIE_STATUS_API_ENABLED` | `no` | Enable the status listener with `/status/` (JSON API) and `/metrics` (Prometheus). |
| `ANGIE_STATUS_API_HOST` | `0.0.0.0` | Listen address. Restricted to the characters `0-9 a-f A-F : . [ ] *` (IPv4, bracketed IPv6 such as `[::]`, or `*`); hostnames and other characters are rejected to prevent config injection. |
| `ANGIE_STATUS_API_PORT` | `8181` | Listen port, digits only, `1-65535`. Keep it >= 1024 so the same value works in the unprivileged image. |

### Filesystem

| Variable | Default | Description |
|---|---|---|
| `CACHE_DIR` | unset | If set to an existing directory path, the entrypoint recursively chowns it to the `angie` user at startup. Useful when mounting a bind-mounted proxy cache directory. Only runs as root (no-op in the unprivileged image). |

---

## Variable dependencies

- `ANGIE_BROTLI_STATIC_ENABLED` activates the base Brotli toggle
  (`ANGIE_BROTLI_ENABLED`) before enabling the static module. Setting only the
  static variable is sufficient.
- `ANGIE_GZIP_STATIC_ENABLED` activates the base gzip toggle
  (`ANGIE_GZIP_ENABLED`) before enabling static. Setting only the static
  variable is sufficient.
- `ANGIE_ZSTD_STATIC_ENABLED` activates the base zstd toggle
  (`ANGIE_ZSTD_ENABLED`) before enabling the static module. Setting only the
  static variable is sufficient.
- `ANGIE_REAL_IP_HEADER` and `ANGIE_REAL_IP_RECURSIVE` are processed by the
  real-IP entrypoint script (`35-real-ip.sh`) and have no effect unless
  `ANGIE_REAL_IP_FROM` is set.
- `ANGIE_LOG_FORMAT_*` variables only register a format definition. They do not
  select an active access log. Use `ANGIE_LOG_*` variables to both register and
  activate a format.
- `ANGIE_LOG_LOGFMT_GEOIP2` and `ANGIE_LOG_FORMAT_LOGFMT_GEOIP2` are processed
  by the GeoIP2 entrypoint script (`50-geoip2.sh`) and are silently ignored
  when `GEOIP2_DB_COUNTRY` is unset or the database file is not readable.
- When a "use" log variable is set, the entrypoint disables all other active
  access-log snippets first to ensure only one `access_log` directive is active.

---

## Volumes

### `/etc/angie/custom`

The primary extension point. Mount a directory here to layer additional Angie
configuration on top of the baked-in defaults without editing the image:

```text
docker run -v /host/angie/custom:/etc/angie/custom:ro 6run0/angie
```

The directory is included by `angie.conf` after all built-in includes. Place
server blocks, additional `http {}` snippets, and TLS certificates here.
Mounting read-only (`:ro`) is recommended when the container does not need to
write to the config at runtime.

### `CACHE_DIR` (bind-mounted cache)

When using Angie as a caching proxy, mount a host directory for the cache and
pass its path via `CACHE_DIR` so the entrypoint fixes ownership:

```text
docker run -v /host/cache:/var/cache/angie \
  -e CACHE_DIR=/var/cache/angie \
  6run0/angie
```

---

## Ports

| Variant | Port | Notes |
|---|---|---|
| Standard (`6run0/angie`, `6run0/angie:latest`) | `80` | Requires root or `CAP_NET_BIND_SERVICE`. |
| Unprivileged (`6run0/angie:...-unprivileged`) | `8080` | Bindable without privileges. |

The health endpoint is available at `GET /healthz` and returns `ok`. Requests
for unrecognised virtual hosts return `444` (connection closed without a
response).

---

## DNS resolution

Since Angie 1.12.0 (image `1.12.0-build1`), the `resolver` directive defaults
to `conf` in the `http` and `stream` modules: Angie reads its DNS servers from
`/etc/resolv.conf` — inside a container that is Docker's embedded DNS — and
re-reads the file whenever it changes. Dynamic name resolution (`proxy_pass`
with variables, upstream `server ... resolve`) therefore works against Docker
DNS out of the box, without a `resolver` line in your vhosts.

Previously, omitting `resolver` disabled dynamic resolution entirely. To
restore that behavior, set `resolver off;` (new in 1.12.0) via the custom
volume.

---

## Build arguments

These arguments are passed to `docker build` with `--build-arg`. Refer to
[usage.md](usage.md) for full build examples.

### Angie version and image metadata (both Dockerfiles)

| Argument | Default | Description |
|---|---|---|
| `ANGIE_VERSION` | current pin | Upstream Angie version installed (core + all modules), pinned via apk's `=~` operator and apt `madison` resolution so the image is reproducible. The release workflow injects this from the git tag and refuses to publish if it disagrees with the pin. |
| `IMAGE_VERSION` | `dev` | Packaging version stamped into `org.opencontainers.image.version` (the image tag minus the variant suffix, e.g. `1.12.0-build1`). Set by the release workflow. |
| `VCS_REF` | empty | Source commit stamped into `org.opencontainers.image.revision`. Set by the release workflow. |

The image carries OCI labels: the `org.opencontainers.image.*` set (`title`,
`description`, `source`, `url`, `documentation`, `licenses`, `version`,
`revision`) plus `software.angie.version` (the exact Angie version). Read them
with `docker inspect --format '{{json .Config.Labels}}' <image>`.

### Unprivileged image identity (`Dockerfile.unprivileged`)

| Argument | Default | Description |
|---|---|---|
| `APP_USER` | `app` | Username of the dedicated unprivileged OS user created inside the image. |
| `APP_GROUP` | `app` | Group name of the dedicated unprivileged OS group. |
| `APP_UID` | `65532` | UID of the unprivileged user (matches the distroless "nonroot" convention). |
| `APP_GID` | `65532` | GID of the unprivileged group. |

### Debian-specific (`debian/Dockerfile`)

| Argument | Default | Description |
|---|---|---|
| `DEBIAN_MIRROR` | upstream default | APT mirror URL for Debian packages. Override to use an internal mirror. |
| `DEBIAN_SECURITY_MIRROR` | upstream default | APT mirror URL for Debian security updates. |

### angie-ctl pin (both Dockerfiles)

| Argument | Default | Description |
|---|---|---|
| `ANGIE_CTL_COMMIT` | pinned SHA | Git commit hash of the [angie-ctl](https://github.com/6RUN0/angie-ctl) helper to clone at build time. Override to test a newer revision. |

---

[Русский](configuration.ru.md)
