# Changelog

All notable changes to this image are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Images are versioned by the upstream Angie release plus a packaging build
number — `<angie>-build<N>` — not by semantic versioning of the packaging
itself. The build number increments when the same Angie version is repackaged
(base-image bump, entrypoint fix, `angie-ctl` update).

## [Unreleased]

### Fixed

- A geoip2 log format left active by a prior run no longer breaks startup when
  geoip2 is disabled. `40-log.sh` now clears the orphaned `*-with-geoip2` log
  snippets before selecting a log (`50-geoip2.sh` re-enables them when geoip2 is
  active), so `angie -t` no longer fails with `unknown "geoip2_country_code"
  variable` on a persistent `/etc/angie` volume.

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

[Unreleased]: https://github.com/6RUN0/docker-angie/compare/v1.11.8-build2...HEAD
[1.11.8-build2]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build2
[1.11.8-build1]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build1
