# Changelog

All notable changes to this image are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Images are versioned by the upstream Angie release plus a packaging build
number — `<angie>-build<N>` — not by semantic versioning of the packaging
itself. The build number increments when the same Angie version is repackaged
(base-image bump, entrypoint fix, `angie-ctl` update).

## [Unreleased]

## [1.12.0-build2] - 2026-07-16

### Added

- **Status API and Prometheus metrics** toggled with `ANGIE_STATUS_API_ENABLED`:
  a dedicated listener (default `0.0.0.0:8181`, configurable via
  `ANGIE_STATUS_API_HOST` / `ANGIE_STATUS_API_PORT` with charset validation)
  serving Angie's read-only JSON statistics tree at `/status/` and the stock
  `all` Prometheus template at `/metrics`. The port is not `EXPOSE`d and is
  never published by default — reachable from the container's Docker network
  until explicitly published.
- **Structured JSON error log** toggled with `ANGIE_ERROR_LOG_JSON_ENABLED`:
  switches the `error_log` in `angie.conf` to Angie 1.12.0's `format=json`
  (one object per line with time, level, message, and request/upstream
  context) and reverts it when unset. A customized `error_log` line is left
  alone; a read-only config is a warned no-op.

## [1.12.0-build1] - 2026-07-16

### Changed

- **Angie 1.12.0** — the packaged Angie is bumped from 1.11.8 to the current
  [1.12.0 upstream release](https://github.com/webserver-llc/angie/releases/tag/Angie-1.12.0).
- `angie-ctl` is bumped to the current upstream, which removed its per-call
  `angie -t` together with the `--no-test` flag; the entrypoint wrapper now
  invokes `angie-ctl` bare. No behavior change: per-call validation was already
  disabled in this image — the entrypoint still validates the assembled config
  once with its single final `angie -t`.
- Heads-up from the Angie 1.12.0 bump itself: the `resolver` directive now
  defaults to `conf` — DNS servers are read from `/etc/resolv.conf` (in a
  container, Docker's embedded DNS) and re-read on change — so dynamic upstream
  resolution works out of the box. Previously a missing `resolver` meant no
  dynamic resolution at all; restore that with `resolver off;` via
  `/etc/angie/custom`.

## [1.11.8-build4] - 2026-06-26

### Fixed

- Startup no longer aborts on a transient orphaned snippet left by an earlier
  toggle on a persistent `/etc/angie` volume. Entrypoint toggles now mutate
  config with `angie-ctl --no-test`, and the entrypoint validates the
  fully-assembled config once with a single final `angie -t` before starting
  angie. Previously each toggle ran its own `angie -t` against a half-assembled
  state, so an orphan from one feature (e.g. a geoip2 log format outliving
  geoip2) could fail that intermediate test and abort startup at an unrelated,
  earlier script. The final test also closes a gap where a config that cannot
  load would crash-loop angie after `exec` — it now fails loudly with the test
  output instead.

## [1.11.8-build3] - 2026-06-25

### Changed

- Feature toggles are now declarative. Every entrypoint toggle resets the
  snippets and modules it manages at the start of each run (via new
  `reset_httpconf` / `reset_module` helpers) and re-enables only what the current
  `ANGIE_*` environment requests. Removing a variable now disables its feature on
  the next start, instead of an enable-only toggle leaving it stuck on across
  restarts on a persistent `/etc/angie` volume. Layer custom configuration
  through `/etc/angie/custom`, not by hand-enabling shipped snippets — those are
  reset on the next start. `worker_processes` auto-tuning is the one exception
  (it rewrites `angie.conf` in place behind a one-time sentinel).

### Fixed

- A geoip2 log format left active by a prior run no longer breaks startup when
  geoip2 is disabled. `40-log.sh` now clears the orphaned `*-with-geoip2` log
  snippets before selecting a log (`50-geoip2.sh` re-enables them when geoip2 is
  active), so `angie -t` no longer fails with `unknown "geoip2_country_code"
  variable` on a persistent `/etc/angie` volume.
- A geoip2 map (`025-geoip2.conf`) and its module left active by a prior run no
  longer break startup when geoip2 is disabled. `50-geoip2.sh` now clears both
  before its early exits and re-enables them only when geoip2 genuinely comes
  up, so a stale `geoip2 <path>` pointing at a removed database no longer fails
  `angie -t` with `MMDB_open(...) failed` on a persistent `/etc/angie` volume.
- A real-ip config (`015-real-ip.conf`) left active by a prior run no longer
  keeps trusting a stale `set_real_ip_from` list after `ANGIE_REAL_IP_FROM` is
  removed. `35-real-ip.sh` now clears the orphan before its early exit, closing
  a `$remote_addr` spoofing window on a persistent `/etc/angie` volume.

## [1.11.8-build2] - 2026-06-23

### Added

- **Zstandard compression** — a fifth bundled dynamic module
  (`angie-module-zstd`), shipped disabled and toggled with `ANGIE_ZSTD_ENABLED`
  / `ANGIE_ZSTD_STATIC_ENABLED`, symmetric to the Brotli and gzip controls.
- **Real-IP recovery** behind a trusted proxy/load balancer/ingress via
  `ANGIE_REAL_IP_FROM` (plus `ANGIE_REAL_IP_HEADER` and
  `ANGIE_REAL_IP_RECURSIVE`), with charset validation of every trusted-proxy
  entry to prevent config injection. Uses the built-in real-IP module — no extra
  package.
- **Baseline security response headers** toggled with
  `ANGIE_SECURITY_HEADERS_ENABLED` (`X-Content-Type-Options`, `Referrer-Policy`,
  `X-Frame-Options`, `Permissions-Policy`), applied with `always`.

## [1.11.8-build1] - 2026-06-23

First public release: Angie 1.11.8 packaged for `linux/amd64` and `linux/arm64`.

### Added

- Angie 1.11.8 on two bases — **Alpine** (default) and **Debian** — each with a
  rootless **unprivileged** variant (uid/gid 65532, listening on 8080).
- Four bundled dynamic modules, shipped **disabled** and switched on at
  container start via `ANGIE_*` environment variables: Brotli, GeoIP2,
  ModSecurity (WAF), and the HTTP substitutions filter.
- Runtime feature toggles following the `ANGIE_*_ENABLED` convention, plus
  static-compression, log-format, WebSocket-map, and worker-process autotune
  controls (full reference in [docs/configuration.md](docs/configuration.md)).
- `available.d`/`.d` activation model: config snippets and module loads ship
  disabled and are symlinked active at start by `angie-ctl`.
- Custom-config overlay at the `/etc/angie/custom` volume, layered over every
  baked-in include without editing shipped files.
- Loopback-only `/healthz` liveness endpoint wired to the image `HEALTHCHECK`.
- OCI image labels, including `software.angie.version` exposing the packaged
  Angie version.
- Published to the GitHub Container Registry (`ghcr.io/6run0/docker-angie`) and
  Docker Hub (`6run0/angie`) with immutable `…-build<N>` and floating tags.

[Unreleased]: https://github.com/6RUN0/docker-angie/compare/v1.12.0-build2...HEAD
[1.12.0-build2]: https://github.com/6RUN0/docker-angie/releases/tag/v1.12.0-build2
[1.12.0-build1]: https://github.com/6RUN0/docker-angie/releases/tag/v1.12.0-build1
[1.11.8-build4]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build4
[1.11.8-build3]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build3
[1.11.8-build2]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build2
[1.11.8-build1]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build1
