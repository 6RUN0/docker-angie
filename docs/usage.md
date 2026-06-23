# Usage

Practical guide for running and building the Angie Docker image.

---

## Table of contents

- [Running from a registry](#running-from-a-registry)
- [Building from source](#building-from-source)
- [Makefile targets](#makefile-targets)
- [Entrypoint and execution order](#entrypoint-and-execution-order)
- [Inspecting the effective configuration](#inspecting-the-effective-configuration)
- [Logs](#logs)
- [Fail-fast on entrypoint errors](#fail-fast-on-entrypoint-errors)

---

## Running from a registry

Images are published to two registries under the same tags:

- Docker Hub: `6run0/angie`
- GHCR: `ghcr.io/6run0/docker-angie`

Supported architectures: `linux/amd64`, `linux/arm64`.

### Minimal smoke-test

Pull and confirm the health endpoint responds. `/healthz` is loopback-only, so
query it from inside the container (exactly what the built-in HEALTHCHECK does):

```sh
docker run -d --name angie -p 8080:80 6run0/angie:alpine
docker exec angie wget -qO- http://127.0.0.1/healthz   # prints: ok
```

`GET /healthz` returns `200 ok` only to loopback clients; a request through the
published port (a non-loopback source) gets `404`. All other requests to an
unknown `Host` header are silently dropped with connection-close (`444`).

### Realistic deployment with feature toggles

```sh
docker run -d \
  -p 80:80 \
  -e ANGIE_BROTLI_ENABLED=1 \
  -e ANGIE_GZIP_ENABLED=1 \
  -e ANGIE_MODSECURITY_ENABLED=1 \
  -v /path/to/my/angie/conf:/etc/angie/custom:ro \
  6run0/angie:alpine
```

Drop your vhosts and extra snippets into `/path/to/my/angie/conf/http.d/`.
The image includes parallel `custom/` includes at every level of `angie.conf`
so user config layers cleanly on top of the baked tree.

See `../README.md` for the full `ANGIE_*` variable reference.

### Rootless (unprivileged) variant

The `-unprivileged` variant runs without any elevated privileges. The listener
moves to port 8080 (no `CAP_NET_BIND_SERVICE` required) and pid/temp paths
relocate to `/tmp/angie`.

```sh
docker run -d \
  -p 8080:8080 \
  -e ANGIE_BROTLI_ENABLED=1 \
  -v /path/to/my/angie/conf:/etc/angie/custom:ro \
  6run0/angie:alpine-unprivileged
```

The default uid inside this image is `65532` (distroless "nonroot"). You can
override it freely:

```sh
docker run --user 1000:1000 -p 8080:8080 6run0/angie:alpine-unprivileged
```

When the runtime uid does not own the activation directories the entrypoint
scripts fall back to the configuration baked at build time and log a warning
-- the container still starts.

The standard (non-unprivileged) image requires root and refuses to start under
`--user`, emitting a clear error message rather than crashing with `EACCES`.

---

## Building from source

The build context is always the repository root (`.`).

### Alpine and Debian base images

```sh
docker build -t angie-alpine -f alpine/Dockerfile .
docker build -t angie-debian -f debian/Dockerfile .
```

### Rootless overlays

The unprivileged images are built on top of the corresponding base image.
Supply the local base tag via `--build-arg BASE_IMAGE`:

```sh
# Alpine rootless (base must be built first)
docker build \
  -f alpine/Dockerfile.unprivileged \
  --build-arg BASE_IMAGE=angie-alpine \
  -t angie-alpine-unprivileged \
  .

# Debian rootless
docker build \
  -f debian/Dockerfile.unprivileged \
  --build-arg BASE_IMAGE=angie-debian \
  -t angie-debian-unprivileged \
  .
```

Optional build args (`APP_USER`, `APP_GROUP`, `APP_UID`, `APP_GID`) let you
set the unprivileged user identity at build time (default uid/gid: `65532`).

### All variants via Compose

```sh
docker compose up --build
```

### Via Make

```sh
make build              # all four images
make build-alpine       # Alpine only
make build-debian       # Debian only
make build-alpine-unprivileged
make build-debian-unprivileged
```

---

## Makefile targets

| Target | Description |
|---|---|
| `help` | Show all available targets |
| **Lint** | |
| `lint` | Run all linters |
| `lint-shell` | `shellcheck` on entrypoint scripts (POSIX sh) and `test/*.sh` (bash) |
| `lint-docker` | `hadolint` on all four Dockerfiles |
| `lint-config` | `gixy` security-lint of the standalone vhost fragments |
| `lint-config-full` | `gixy` on the full effective config (requires `angie-alpine` to be built) |
| `lint-ci` | `actionlint` + `zizmor` on the GitHub Actions workflows |
| **Build** | |
| `build` | Build all four images |
| `build-alpine` | Build the Alpine image |
| `build-debian` | Build the Debian image |
| `build-alpine-unprivileged` | Build the rootless Alpine image (depends on `build-alpine`) |
| `build-debian-unprivileged` | Build the rootless Debian image (depends on `build-debian`) |
| **Test** | |
| `test` | Smoke-test all four images |
| `test-alpine` | Build + smoke-test the Alpine image |
| `test-debian` | Build + smoke-test the Debian image |
| `test-alpine-unprivileged` | Build + smoke-test the rootless Alpine image |
| `test-debian-unprivileged` | Build + smoke-test the rootless Debian image |
| **Other** | |
| `clean` | Remove the four locally built images |

Image names default to `angie-alpine`, `angie-debian`, etc. Override on the
command line:

```sh
make build IMAGE_ALPINE=myrepo/angie:latest
```

---

## Entrypoint and execution order

The entrypoint chain is:

```text
tini -- /docker-entrypoint.sh  [CMD: angie -g 'daemon off;']
```

`tini` acts as PID 1, reaping zombie processes and forwarding signals to
`angie`.

### Configuration phase

`docker-entrypoint.sh` sources `docker-entrypoint-common.sh` (loggers,
`is_root`, `skip_toggle_unless_writable`, `enable_log`/`enable_log_format`
helpers) and then checks the first argument:

- If `$1` is `angie` or `angie-debug`, the configuration phase runs.
- For any other command (e.g. `sh`) the phase is skipped and `exec "$@"` is
  called immediately. This lets you run arbitrary commands inside the container
  without triggering the Angie setup.

### Script execution

During the configuration phase every file in `/docker-entrypoint.d/` is
visited in `sort -V` order (the two-digit numeric prefix on each filename
already sorts correctly under the shell's lexical glob expansion, so no
external sort is needed):

| File pattern | Behaviour |
|---|---|
| `*.sh` and executable | Executed in the main shell; a non-zero exit aborts startup immediately. |
| `*.sh` but not executable | Skipped with a `warning` log message. |
| Any other file | Skipped with a `warning` log message. |

The scripts shipped in this image follow the numbering scheme below:

| Range | Purpose |
|---|---|
| `30-*` | System tuning (e.g. `worker_processes` autotune) |
| `40-*` | Feature toggles (gzip, brotli, log format, WAF, subs, websocket map) |
| `50-*` | GeoIP2 setup (path validation, config rendering, module activation) |
| `90-*` | Permission fixups |

After all scripts complete successfully, `docker-entrypoint.sh` prints
`configuration complete; ready for start up` and calls `exec "$@"`, replacing
itself with the Angie process.

### Toggle convention

Every feature toggle script follows the same pattern:

```sh
: "${ANGIE_SOME_FEATURE:=no}"
case "${ANGIE_SOME_FEATURE}" in
yes | on | 1 | true | enable | enabled)
  angie-ctl httpconf en "NNN-snippet.conf"
  ;;
esac
```

The accepted truthy values are: `yes`, `on`, `1`, `true`, `enable`, `enabled`.

---

## Inspecting the effective configuration

After the container is running, dump the fully resolved Angie configuration
(all includes expanded, comments stripped):

```sh
docker exec <container> angie -T
```

This is also how `make lint-config-full` works: it starts a temporary
container, polls until `angie -T` succeeds, captures the output, and runs
`gixy` against it.

---

## Logs

### Access and error logs

Angie writes access and error logs to `stdout`/`stderr` so the Docker log
driver captures them without any extra configuration.

The default access-log format is `logfmt`. See
[configuration.md](configuration.md) for the full list of available formats
(`main`, `logfmt`, `logfmt-with-geoip2`, `extended`, `matomo`) and the
corresponding `ANGIE_LOG_*` toggle variables.

Only one access-log format can be active at a time. The `enable_log` helper
in `docker-entrypoint-common.sh` disables the entire `040-log-*.conf` group
before enabling the requested format, so switching formats is idempotent
across restarts and cannot produce duplicate `access_log` directives.

### Entrypoint logs

`docker-entrypoint-common.sh` opens file descriptor 3 at startup:

- `ANGIE_ENTRYPOINT_QUIET_LOGS` unset or empty: fd 3 maps to stderr --
  entrypoint messages appear in `docker logs`.
- `ANGIE_ENTRYPOINT_QUIET_LOGS` set to any non-empty value: fd 3 maps to
  `/dev/null` -- entrypoint messages are suppressed.

All entrypoint log functions (`ngx_err`, `ngx_warning`, `ngx_notice`,
`ngx_info`) write to fd 3 with the format:

```text
YYYY/MM/DD HH:MM:SS [level] <pid>: entrypoint: <message>
```

---

## Fail-fast on entrypoint errors

A script in `/docker-entrypoint.d/` that exits with a non-zero status causes
the entrypoint to log an error and exit with the same code immediately:

```text
YYYY/MM/DD HH:MM:SS [err] 1: entrypoint:
  /docker-entrypoint.d/99-myscript.sh failed with exit 7, aborting startup
```

The container stops before Angie starts. This prevents a half-applied
configuration from being served silently.

You can verify the behaviour:

```sh
# Create a failing script and mount it
printf '#!/bin/sh\nexit 7\n' > /tmp/99-fail.sh
chmod +x /tmp/99-fail.sh
docker run --rm \
  -v /tmp/99-fail.sh:/docker-entrypoint.d/99-fail.sh:ro \
  6run0/angie:alpine
# Container exits non-zero; Angie never starts.
```

---

[Russian version](usage.ru.md) |
[Configuration](configuration.md) |
[Compose](compose.md) |
[Back to README](../README.md)
