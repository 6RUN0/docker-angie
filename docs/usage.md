# Usage

Practical guide for running and building the Angie Docker image.

---

## Table of contents

- [Running from a registry](#running-from-a-registry)
- [Building from source](#building-from-source)
- [Makefile targets](#makefile-targets)
- [Entrypoint and execution order](#entrypoint-and-execution-order)
- [Inspecting the effective configuration](#inspecting-the-effective-configuration)
- [Applying a configuration edit](#applying-a-configuration-edit)
- [Migrating from the writable `/etc/angie` layout](#migrating-from-the-writable-etcangie-layout)
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
  --read-only --tmpfs /data:mode=1777 \
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
moves to port 8080 (no `CAP_NET_BIND_SERVICE` required). Like the standard
variant, it uses `/data/conf` for the live configuration and `/data/tmp` for
temporary files; there is no pid file.

```sh
docker run -d \
  --read-only --tmpfs /data:mode=1777 \
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

The unprivileged image can run under any UID. `/data` must be writable by that
UID; a fresh `mode=1777` tmpfs satisfies this. A persistent `/data/conf` created
by another UID is rejected rather than overwritten.

The standard (non-unprivileged) image requires root and refuses to start under
`--user`, emitting a clear error message rather than crashing with `EACCES`.

---

## Building from source

The build context is always the repository root (`.`).

### Alpine and Debian base images

Each Dockerfile has two final targets: `standard` (root master, port 80) and
`unprivileged` (port 8080, see below). A build without `--target` produces
`standard`.

```sh
docker build --target standard -t angie-alpine -f alpine/Dockerfile .
docker build --target standard -t angie-debian -f debian/Dockerfile .
```

### Rootless targets

The unprivileged images come from the `unprivileged` target of the same
Dockerfile. Both targets share the `runtime` stage, so the second build takes
the package and config layers from the build cache and nothing has to be built
first:

```sh
docker build --target unprivileged -t angie-alpine-unprivileged -f alpine/Dockerfile .
docker build --target unprivileged -t angie-debian-unprivileged -f debian/Dockerfile .
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
| `lint-shell` | `shellcheck` on entrypoint scripts, helpers, and tests (POSIX sh) |
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
| `test` | Run helper tests and both smoke suites for all four images |
| `test-unit` | Test the vendored `angie-ctl` without Docker |
| `test-alpine` | Build + smoke-test the Alpine image |
| `test-debian` | Build + smoke-test the Debian image |
| `test-alpine-unprivileged` | Build + smoke-test the rootless Alpine image |
| `test-debian-unprivileged` | Build + smoke-test the rootless Debian image |
| **Other** | |
| `ci-local` | Run the GitHub Actions CI workflow locally through [act](https://github.com/nektos/act) |
| `clean` | Remove the four locally built images |

Image names default to `angie-alpine`, `angie-debian`, etc. Override on the
command line:

```sh
make build IMAGE_ALPINE=myrepo/angie:latest
```

`ci-local` runs every job of `.github/workflows/ci.yml`; `ACT_JOB` narrows it to
one (`make ci-local ACT_JOB=lint`). It needs `act` and a Docker daemon, and
fixture-mounting smoke tests only pass because the target binds the repository
at its own absolute path and points `TMPDIR` inside it: act runs the job in a
container while the job's `docker run` reaches the host daemon, so a path that
exists on only one side is silently replaced with an empty directory.

---

## Entrypoint and execution order

The entrypoint chain is:

```text
tini -- /docker-entrypoint.sh \
  [CMD: angie -p /data/conf -c angie.conf -g 'daemon off;']
```

`tini` acts as PID 1, reaping zombie processes and forwarding signals to
`angie`.

### Configuration phase

`docker-entrypoint.sh` sources `docker-entrypoint-common.sh` (loggers, runtime
paths, and activation helpers) and then checks the first argument:

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
| `10-*` | Rebuild `/data/conf` from the immutable skeleton |
| `30-*` | System tuning (e.g. `worker_processes` autotune) |
| `40-*` | Feature toggles, including ACME, Console, compression, logs, and modules |
| `45-*` / `46-*` | Response security, HSTS, and asset CORS |
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

After the container is running, test or dump the live configuration with its
explicit prefix:

```sh
docker exec <container> angie -p /data/conf -c angie.conf -t
docker exec <container> angie -p /data/conf -c angie.conf -T
```

The `/usr/local/bin/angie-runtime` wrapper supplies these arguments for image
health checks and scripts. Use the explicit form in operational procedures so
the checked tree is unambiguous.

## Applying a configuration edit

The custom volume remains mounted at `/etc/angie/custom`, so changing its files
does not require recreating the container. Validate and signal the container:

```sh
docker exec angie angie -p /data/conf -c angie.conf -t
docker kill -s HUP angie
```

`angie -s reload` is unsupported because the image uses `pid off`. Environment
variables are fixed in the container definition; change them by recreating the
container rather than sending HUP.

Inside the container `angie-ctl --reload` works too: the image sets
`ANGIE_RELOAD_CMD="kill -HUP 1"`, and tini (PID 1) forwards the signal to the
master. A toggle enabled this way lasts until the next start, which rebuilds
`/data/conf` from the skeleton and the environment.

## Migrating from the writable `/etc/angie` layout

This layout is a breaking change for consumers that mounted generated config
or temporary directories directly:

1. Keep user-owned files under `/etc/angie/custom/{conf.d,http-conf.d,http.d}`.
2. Remove mounts for `/etc/angie`, `/etc/angie/*.d`, `/run/angie.pid`,
   `/tmp/angie`, and `/var/cache/angie` that existed only to make the image
   writable.
3. Mount one writable `/data`; use tmpfs for stateless workloads and a
   persistent volume for ACME or disk-backed caches.
4. Update validation and reload commands to the explicit prefix and HUP forms
   above.

Never persist `/data/conf`: the entrypoint deliberately rebuilds it from the
new image at every start so updated defaults reach existing deployments.

---

## Logs

### Access and error logs

Angie writes access and error logs to `stdout`/`stderr` so the Docker log
driver captures them without any extra configuration.

The default access-log format is structured JSON. See
[configuration.md](configuration.md) for the full list of available formats
(`main`, `json`, `logfmt`, GeoIP2 variants, `extended`, `matomo`) and the
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

All entrypoint log functions write JSON by default, one object per line. Set
`ANGIE_ERROR_LOG_JSON_ENABLED=no` to use the text format:

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

[Configuration](configuration.md) |
[Compose](compose.md) |
[Back to README](../README.md)

Russian: [usage.ru.md](usage.ru.md).
