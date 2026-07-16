# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Docker image build for the [Angie web server](https://angie.software) (an nginx
fork) bundled with five dynamic modules: Brotli, Zstandard, GeoIP2, ModSecurity
(WAF), and the substitutions filter. Two base variants are built from the same `rootfs/`:
`alpine/Dockerfile` and `debian/Dockerfile`. There is no application source code
here — the deliverable is the image, its entrypoint scripts, and the Angie
configuration tree.

## Build & run

```bash
# Build a single variant (build context is the repo root, '.')
docker build -t angie-alpine -f alpine/Dockerfile .
docker build -t angie-debian -f debian/Dockerfile .

# Build + run all variants via compose
docker compose up --build
```

Validation is wired through the Makefile: `make lint` (shellcheck, hadolint,
gixy config lint, actionlint/zizmor, docs) and `make test` (builds all four
images and runs `test/smoke.sh` / `test/smoke-unprivileged.sh` against them).
CI (`.github/workflows/ci.yml`) runs the same lint + build + smoke pipeline on
every push/PR. All shell scripts — entrypoint and tests alike — are POSIX `sh`
(`#!/bin/sh`), checked with `shellcheck -s sh`.

## Architecture: the available.d / .d activation model

This is the single most important concept and spans many files.

- Config snippets and module-load files are **shipped disabled**. They live in
  `*-available.d/` directories:
  - `rootfs/etc/angie/http-conf-available.d/` — `http {}`-context snippets
    (gzip, brotli, ssl, log formats, geoip2, websocket map, …).
  - `rootfs/etc/angie/modules-available.d/` — `load_module` directives for the
    dynamic modules.
- The **active** directories are what `angie.conf` actually includes (not the
  `-available` ones). `modules.d/` ships empty (only `.gitkeep`) — every module
  is enabled purely at runtime. `http-conf.d/` ships **two git-tracked symlinks
  active by default** — `010-common.conf` and `050-ssl.conf` (each pointing into
  `../http-conf-available.d/`) — plus `.gitkeep`; everything else there is
  activated at runtime. Note `050-ssl.conf` is active but inert: it sets only
  SSL session/cipher tuning and no server does `listen ... ssl` (the image
  `EXPOSE`s 80 only).
- Activation happens **at container start**, not at build time. The external
  helper `angie-ctl` (cloned from `ANGIE_CTL_REPO` at a pinned `ANGIE_CTL_COMMIT`
  in the Dockerfile, installed to `/usr/local/bin/angie-ctl`) symlinks a snippet
  from `-available.d` into the active dir:
  - `angie-ctl httpconf en <name>.conf` → enables an http-conf snippet.
  - `angie-ctl mod en <name>.conf` → enables a module load.

When adding a feature: create the snippet in the matching `-available.d/`
directory, then enable it from an entrypoint script — do **not** drop it directly
into the active `.d/` dir.

## Architecture: entrypoint flow

`ENTRYPOINT` is `tini -- /docker-entrypoint.sh`; `CMD` is `angie -g 'daemon off;'`.

- `rootfs/docker-entrypoint.sh` — only runs the configuration phase when `$1` is
  `angie`/`angie-debug`. It executes every executable `*.sh` in
  `/docker-entrypoint.d/` in `sort -V` order, then validates the fully-assembled
  config once with a final `angie -t` (fail-fast) before `exec "$@"`. The toggles
  mutate config with `angie-ctl`, which runs no config test of its own, so this
  is the **only** config test of the run — a transient inconsistency
  mid-toggling (e.g. an orphaned geoip2
  log format not yet reset when an earlier toggle enabled its snippet) is
  harmless; only the final state is tested. Non-executable or non-`.sh` files are
  skipped with a warning.
- `rootfs/docker-entrypoint-common.sh` is **sourced** by every entrypoint script.
  It provides the `ngx_err/ngx_warning/ngx_notice/ngx_info` loggers (gated by
  `ANGIE_ENTRYPOINT_QUIET_LOGS`), the `ngx_ctl` wrapper around `angie-ctl`,
  the `reset_httpconf`/`reset_module` declarative-reset helpers, and the
  `enable_log_format`/`enable_log` helpers. Logging goes to fd 3, which maps to
  stderr or `/dev/null` when quiet.
- `rootfs/docker-entrypoint.d/NN-*.sh` — one feature toggle per file, numbered to
  control order (30 tune, 35 real-ip, 40 features, 45 security headers,
  50 geoip2, 60 websocket, 90 permission fixups). Each reads its `ANGIE_*` env
  var and calls `ngx_ctl` (the `angie-ctl` wrapper from
  `docker-entrypoint-common.sh`) to enable the corresponding snippet. angie-ctl
  performs no per-call config test; validation is deferred to the entrypoint's
  final `angie -t`. The conventional toggle pattern is:

  ```sh
  : "${ANGIE_SOME_FEATURE:=no}"
  case "${ANGIE_SOME_FEATURE}" in
  yes | on | 1 | true | enable | enabled)
    ngx_ctl httpconf en "NNN-snippet.conf"
    ;;
  esac
  ```

  Follow this exact accepted-truthy set for any new toggle. `_STATIC`/extended
  variants call the base helper first, then enable the extra snippet (see
  `40-brotli.sh`, `40-gzip.sh`).

Scripts that templatize config use `sed` placeholder substitution: `50-geoip2.sh`
rewrites `%%GEOIP2_DB_COUNTRY%%` inside `025-geoip2.conf` before enabling it.
`30-tune-worker-processes.sh` is the outlier — it rewrites `worker_processes` in
`angie.conf` in place (cgroup v1/v2 CPU detection) and no-ops on a read-only FS.

## Angie config layout (`rootfs/etc/angie/`)

- `angie.conf` — top-level; intentionally contains only `include` directives.
  Every include has a parallel `/etc/angie/custom/...` include so users can layer
  config via the `/etc/angie/custom` volume without editing baked-in files.
- `http.d/default.conf` — the only active vhost: a catch-all `server` returning
  `444` on `:80`. Real vhosts are expected via the custom volume.
- Numeric filename prefixes (`010-`, `020-`, `030-log-format-…`, `040-log-…`)
  encode load order within the `http {}` context; keep new snippets in that scheme
  (formats are `030-`, active-log selection is `040-`).

## Conventions

- `.editorconfig`: 2-space indent, LF, UTF-8, final newline, trim trailing ws —
  applies to all files including shell and conf.
- `.dockerignore` whitelists only `rootfs/` and `rootfs-unprivileged/` into the
  build context (the latter is overlaid by the `*.unprivileged` Dockerfiles).
- Both Dockerfiles pin third-party code by commit (`ANGIE_CTL_COMMIT`) and clone
  with a shallow `x_git_clone` helper; the Debian build also routes apt through a
  configurable mirror. Keep the alpine and debian Dockerfiles in sync when
  changing the installed module set or the angie-ctl pin.
- Branching: work lands on `develop`; `main` is the default/PR target.

## Releasing

Cutting a new image release (build-number bump or Angie version bump) follows
[`docs/release-checklist.md`](docs/release-checklist.md). Key point: the current
tag is hard-coded in `README*`, `CHANGELOG*`, and `docs/dockerhub-overview.md`
examples, so a bump must actualize those (and re-check `CLAUDE.md`), not only the
Dockerfile `ARG ANGIE_VERSION` pins.
