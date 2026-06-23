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

### WebSocket

| Variable | Default | Description |
|---|---|---|
| `ANGIE_MAP_WEBSOCKET_ENABLED` | `no` | Enable the WebSocket variable map, which sets the `Connection` upgrade header for upstream WebSocket proxying. |

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

## Build arguments

These arguments are passed to `docker build` with `--build-arg`. Refer to
[usage.md](usage.md) for full build examples.

### Angie version and image metadata (both Dockerfiles)

| Argument | Default | Description |
|---|---|---|
| `ANGIE_VERSION` | current pin | Upstream Angie version installed (core + all modules), pinned via apk's `=~` operator and apt `madison` resolution so the image is reproducible. The release workflow injects this from the git tag and refuses to publish if it disagrees with the pin. |
| `IMAGE_VERSION` | `dev` | Packaging version stamped into `org.opencontainers.image.version` (the image tag minus the variant suffix, e.g. `1.11.8-build1`). Set by the release workflow. |
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
