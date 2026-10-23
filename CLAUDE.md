# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Docker image build for the [Angie web server](https://angie.software) (an nginx
fork) bundled with five dynamic modules: Brotli, Zstandard, GeoIP2, ModSecurity
(WAF), and the substitutions filter. Two base distributions are built from the
same `rootfs/`: `alpine/Dockerfile` and `debian/Dockerfile`. Each has three
stages: `runtime` (everything shared, no `EXPOSE`/`HEALTHCHECK`/version
labels), `unprivileged` (overlays `rootfs-unprivileged/`, port 8080) and
`standard` (port 80, last, so a build without `--target` yields it) - four
images in total. There is no application source code here - the deliverable is
the images, their entrypoint scripts, the vendored `angie-ctl` and the Angie
configuration tree. The rationale behind the layout is in
[`docs/architecture.md`](docs/architecture.md).

## Build & run

```bash
# Build a single variant (build context is the repo root, '.')
docker build --target standard -t angie-alpine -f alpine/Dockerfile .
docker build --target standard -t angie-debian -f debian/Dockerfile .
# The unprivileged target shares the cached runtime stage with standard
docker build --target unprivileged -t angie-alpine-unprivileged -f alpine/Dockerfile .

# Build + run all variants via compose
docker compose up --build
```

Validation is wired through the Makefile: `make lint` (shellcheck, hadolint,
gixy config lint, actionlint/zizmor, docs, offline local-link check, and
`ci/check-conf-vars.sh`, which requires every variable the image declares to
carry the `$_stock_` prefix) and `make test`, which runs `make test-unit` (no
Docker: `test/angie-ctl.sh` drives the vendored `angie-ctl` against a
throwaway tree, `test/check-conf-vars.sh` covers the prefix linter), then
builds all four images and runs against each:

- regular images: `test/smoke.sh` and `test/smoke-layout.sh` with `PORT=80`;
- unprivileged images: `test/smoke-unprivileged.sh` and `test/smoke-layout.sh`
  with `PORT=8080`.

`test/smoke-layout.sh` holds the checks shared by both variants (`/data`
layout, overlay refusals, features); variant-specific behaviour goes into
`smoke.sh` or `smoke-unprivileged.sh`. `.NOTPARALLEL: test` is load-bearing:
the suites share one daemon and a 30 s health budget per container. Two
opt-in targets need network and stay out of `make test`: `make test-acme`
(`test/acme-e2e.sh`, issuance against a local Pebble CA) and
`make test-build-mirrors` (`test/build-mirrors.sh`, build refusals on bad
package mirrors). CI
(`.github/workflows/ci.yml`) runs the same lint + unit + build + smoke pipeline
on every push/PR. All shell scripts - entrypoint and tests alike - are POSIX `sh`
(`#!/bin/sh`), checked with `shellcheck -s sh`.

## Architecture: the available.d / .d activation model

This is the single most important concept and spans many files.

- Config snippets and module-load files are **shipped disabled**. They live in
  `*-available.d/` directories:
  - `rootfs/etc/angie/http-conf-available.d/` - `http {}`-context snippets
    (gzip, brotli, ssl, log formats, geoip2, websocket map, ...).
  - `rootfs/etc/angie/modules-available.d/` - `load_module` directives for the
    dynamic modules.
- The **active** directories are what `angie.conf` actually includes (not the
  `-available` ones). `modules.d/` ships empty (only `.gitkeep`) - every module
  is enabled purely at runtime. `http-conf.d/` ships **two git-tracked symlinks
  active by default** - `010-common.conf` and `050-ssl.conf` (each pointing into
  `../http-conf-available.d/`) - plus `.gitkeep`. The build adds two more,
  `030-log-format-json.conf` and `040-log-json.conf`, so the skeleton logs in
  the `40-log.sh` default format even when the entrypoint does not run;
  everything else there is activated at runtime. Note `050-ssl.conf` is active
  but inert: it sets only SSL session/cipher tuning and no server does
  `listen ... ssl`.
- Activation happens **at container start**, not at build time, and only ever
  in the live copy under `/data/conf` (see "Runtime layout" below). The helper
  `angie-ctl` is vendored in this repo (`rootfs/usr/local/bin/angie-ctl`,
  unit-tested by `test/angie-ctl.sh`) and symlinks a snippet from
  `-available.d` into the active dir:
  - `angie-ctl httpconf en <name>.conf` enables an http-conf snippet.
  - `angie-ctl mod en <name>.conf` enables a module load.

  It takes the tree root from `ANGIE_ETC` (image `ENV ANGIE_ETC=/data/conf`)
  and runs `ANGIE_BIN` for its config test (image
  `ENV ANGIE_BIN=/usr/local/bin/angie-runtime`, a wrapper that adds
  `-p /data/conf -c angie.conf`). `--reload` runs `ANGIE_RELOAD_CMD`, set to
  `kill -HUP 1` in the image: with `pid off` there is no `angie -s reload`, and
  tini (pid 1) forwards HUP to the master.
- `rootfs/etc/angie/snippets/` is outside the activation model: plain files for
  `server {}`/`location {}` context, included by name (`include
  snippets/healthz.conf;`) by the built-in vhost and by consumer vhosts alike.

When adding a feature: create the snippet in the matching `-available.d/`
directory, then enable it from an entrypoint script - do **not** drop it directly
into the active `.d/` dir.

## Runtime layout: `/data` and the two variants

- `/etc/angie` is a skeleton the entrypoint never edits. `10-conf-overlay.sh`
  (runs first) copies it, minus `custom/`, into `/data/conf` on **every** start,
  so no state of a previous run survives, even on a persistent volume. The copy
  is marked by `/data/conf/.angie-conf-overlay`; a non-empty `/data/conf`
  without that marker, one owned by another uid, or a symlinked `/data/conf` or
  `/data/tmp` aborts startup instead of being overwritten.
- `/data` is the only writable location: `/data/conf` (live tree), `/data/tmp`
  (the five `*_temp_path` directives in `010-common.conf`), `/data/acme` (ACME
  state, refused when it is a symlink). A read-only root works with one
  `--tmpfs /data` or volume; an unwritable `/data` fails startup (checked with a
  `mktemp` write probe).
- angie runs with `-p /data/conf -c angie.conf` (in `CMD`). Inside the
  container use `angie-runtime ...` or pass `-p /data/conf -c angie.conf`
  explicitly; a bare `angie -t`/`-T` reads the skeleton, not the served config.
- `conf.d/10-pid.conf` sets `pid off`: reload is `docker kill -s HUP` (or
  `angie-ctl --reload`), stop is `STOPSIGNAL SIGQUIT` (graceful), capped by
  `worker_shutdown_timeout`.
- Regular image: root master on port 80, workers run as `angie`
  (`conf.d/05-worker-user.conf`: `user angie;`). `/data` and `/data/tmp` are
  `0755 root:root`, and `10-conf-overlay.sh` rebuilds `/data/tmp` root-owned
  0755 on each start (the root master chowns temp dirs to the worker). The
  entrypoint refuses a non-root start unless `ANGIE_UNPRIVILEGED` is set.
- Unprivileged image: `ENV ANGIE_UNPRIVILEGED=1`, numeric
  `USER 65532:65532` (`APP_UID`/`APP_GID` build args), port 8080
  (`rootfs-unprivileged/etc/angie/http.d/default.conf`), an empty
  `05-worker-user.conf`, `/data` and `/data/tmp` `1777` so any
  `docker run --user` can build its own tree.
- `ANGIE_HTTP_PORT` (80 or 8080, derived from `ANGIE_UNPRIVILEGED` in
  `docker-entrypoint-common.sh`) is what toggles compare consumer ports against;
  `is_root` gates the root-only steps (chown, readability checks as `angie`).

## Architecture: entrypoint flow

`ENTRYPOINT` is `tini -- /docker-entrypoint.sh`; `CMD` is
`angie -p /data/conf -c angie.conf -g 'daemon off;'`.

- `rootfs/docker-entrypoint.sh` - only runs the configuration phase when `$1` is
  `angie`/`angie-debug`. It executes every executable `*.sh` in
  `/docker-entrypoint.d/` in shell glob order (two-digit prefixes sort
  numerically; no `find | sort` pipeline, whose subshell would swallow `set -e`),
  then validates the fully-assembled config once with a final `"$@" -t`
  (fail-fast) before `exec "$@"`. The whole argument list is tested so `-p`/`-c`
  point at the live tree. The toggles mutate config with `ngx_ctl`, which calls
  `angie-ctl --no-test`, so this is the **only** config test of the run - a
  transient inconsistency mid-toggling (e.g. an orphaned geoip2 log format not
  yet reset when an earlier toggle enabled its snippet) is harmless; only the
  final state is tested. Non-executable or non-`.sh` files are skipped with a
  warning.
- `rootfs/docker-entrypoint-common.sh` is **sourced** by every entrypoint script.
  It provides the `ngx_err/ngx_warning/ngx_notice/ngx_info` loggers (gated by
  `ANGIE_ENTRYPOINT_QUIET_LOGS`; JSON lines unless
  `ANGIE_ERROR_LOG_JSON_ENABLED` is falsy), the live-tree paths
  (`ANGIE_DATA_DIR`, `ANGIE_CONF_DIR`, `ANGIE_TMP_DIR`, exported `ANGIE_ETC`),
  `ANGIE_HTTP_PORT`, `is_root`, the `ngx_ctl` wrapper around `angie-ctl`, the
  `reset_httpconf`/`reset_module` declarative-reset helpers, and the
  `enable_log_format`/`enable_log` helpers. Logging goes to fd 3, which maps to
  stderr or `/dev/null` when quiet.
- `rootfs/docker-entrypoint.d/NN-*.sh` - one feature toggle per file, numbered to
  control order: 10 conf overlay (must run first), 30 tune worker processes,
  31 error-log-json, 32 worker shutdown timeout, 35 real-ip, 40 features (acme,
  brotli, charset, console, expires, gzip, log, modsecurity, open-file-cache,
  status-api, subs, zstd), 45 hsts and security headers, 46 asset CORS,
  50 geoip2 (after `40-log.sh`, whose log it overrides), 60 websocket map,
  90 permission fixups (`CACHE_DIR` and htpasswd chown; they act only under a
  root master without `ANGIE_UNPRIVILEGED` and exit early otherwise). Each
  activation toggle first resets what it owns, then reads its `ANGIE_*` env var and calls
  `ngx_ctl` to enable the corresponding snippet. The conventional toggle
  pattern is:

  ```sh
  : "${ANGIE_SOME_FEATURE:=no}"
  reset_httpconf NNN-snippet.conf
  case "${ANGIE_SOME_FEATURE}" in
  yes | on | 1 | true | enable | enabled)
    ngx_ctl httpconf en "NNN-snippet.conf"
    ;;
  esac
  ```

  Follow this exact accepted-truthy set for any new toggle. `_STATIC`/extended
  variants call the base helper first, then enable the extra snippet (see
  `40-brotli.sh`, `40-gzip.sh`).

Scripts that templatize config render a `.template` with `sed` placeholder
substitution on every start, before enabling the result: `35-real-ip.sh`
(`015-real-ip.conf`), `50-geoip2.sh` (`025-geoip2.conf`), `40-status-api.sh`
(`070-status-api.conf`), `40-acme.sh` (`080-acme.conf`), `45-hsts.sh`
(`056-hsts.conf`) and `40-console.sh` (`snippets/console.conf`, no activation).
Three outliers rewrite the live `angie.conf` in place, because the directive
sits in the main context: `30-tune-worker-processes.sh` (`worker_processes`,
cgroup v1/v2 CPU detection), `31-error-log-json.sh` (the `error_log` line,
toggled both ways) and `32-worker-shutdown-timeout.sh`
(`worker_shutdown_timeout`, which cannot be declared twice). A fourth in-place
edit is in `10-conf-overlay.sh`: without `/proc/net/if_inet6` it drops the
`listen [::]:<port>;` line from the live `http.d/default.conf`.

## Angie config layout (`rootfs/etc/angie/`)

- `angie.conf` - top-level; contains only main-context tuning directives and
  `include`s. Image includes are relative to the `/data/conf` prefix; every one
  has a parallel absolute `/etc/angie/custom/...` include so users layer config
  via a `/etc/angie/custom` mount without editing baked-in files. Inside
  `http {}` both custom includes come after the image's `http.d/`, so a consumer
  `server {}` in `custom/http-conf.d` cannot silently take the default server.
- `http.d/default.conf` - the only active vhost: a catch-all `server` with
  `server_name healthz-catchall.invalid`, no `default_server` flag, returning
  `444` on `:80` (`:8080` in the unprivileged overlay), plus `/healthz`
  (loopback-only) and the Console Light snippet. Real vhosts are expected via
  the custom mount and may declare their own `default_server`.
- Numeric filename prefixes (`010-`, `020-`, `030-log-format-...`, `040-log-...`)
  encode load order within the `http {}` context; keep new snippets in that scheme
  (formats are `030-`, active-log selection is `040-`).
- Variables the image declares carry the `$_stock_` prefix (`map`/`geo`
  re-declared in `custom` win silently); log format names carry `angie_`
  (`angie_json`, `angie_main`, ...). Keep both prefixes for new declarations.

## Conventions

- `.editorconfig`: 2-space indent, LF, UTF-8, final newline, trim trailing ws -
  applies to all files including shell and conf.
- `.dockerignore` whitelists only `rootfs/` and `rootfs-unprivileged/` into the
  build context (the latter is overlaid by the `unprivileged` stage).
- A new `rootfs/docker-entrypoint.d/*.sh` must be committed executable
  (`chmod +x`, mode `100755` in git): the entrypoint only warns about a
  non-executable `*.sh` and starts without that toggle.
- Keep the alpine and debian Dockerfiles in sync when changing the installed
  module set, the package pins or the runtime `ENV`/`STOPSIGNAL`/`HEALTHCHECK`,
  in every stage. `IMAGE_VERSION`/`VCS_REF` stay declared right before the last
  `LABEL` of each final stage: anywhere in `runtime` a new commit would
  invalidate the shared package layers.
- Branching: work lands on `develop`; `main` is the default/PR target.

## Releasing

Cutting a new image release (build-number bump or Angie version bump) follows
[`docs/release-checklist.md`](docs/release-checklist.md). Key point: the current
tag is hard-coded in `README*`, `CHANGELOG*`, and `docs/dockerhub-overview.md`
examples, so a bump must actualize those (and re-check `CLAUDE.md`), not only the
Dockerfile `ARG ANGIE_VERSION` pins.
