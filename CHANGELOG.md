# Changelog

All notable changes to this image are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Images are versioned by the upstream Angie release plus a packaging build
number - `<angie>-build<N>` - not by semantic versioning of the packaging
itself. The build number increments when the same Angie version is repackaged
(base-image bump, entrypoint fix, `angie-ctl` update).

## [Unreleased]

### Added

- Added the same runtime feature set to the standard and unprivileged Alpine
  and Debian images: ACME, Console Light 1.9.0, UTF-8 charset, content-type
  expiry maps, open-file caching, HSTS, asset CORS, JSON/GeoIP2 access logs,
  reusable server/location snippets, and a configurable graceful worker
  shutdown timeout (default `8s`). Error, access, and entrypoint logs now use
  JSON by default.
- Both image variants now support a read-only root filesystem with one writable
  `/data` mount. The immutable skeleton remains under `/etc/angie`; the
  entrypoint assembles `/data/conf` and uses `/data/tmp` at every start.

### Changed

- **BREAKING:** `alpine/Dockerfile.unprivileged` and
  `debian/Dockerfile.unprivileged` are removed. Build the unprivileged image
  from the same Dockerfile with
  `docker build --target unprivileged -f alpine/Dockerfile .` (or
  `debian/Dockerfile`); `--build-arg BASE_IMAGE` is gone. A build without
  `--target` still yields the standard image. The unprivileged image exposes
  only `8080/tcp`, no longer `80/tcp` as well, and its
  `org.opencontainers.image.base.name` names the Alpine or Debian base, not the
  Angie image.
- **BREAKING:** generated configuration and temporary paths moved to `/data`.
  Keep consumer files under `/etc/angie/custom`, mount `/data` rather than
  `/data/conf`, validate with
  `angie -p /data/conf -c angie.conf -t`, and reload with
  `docker kill -s HUP <container>`. `angie -s reload` is unavailable because
  the image uses `pid off`.
- Standard images retain a root master, `angie` workers, and port 80;
  unprivileged images retain port 8080, uid/gid 65532, and arbitrary-UID
  support. Both now use the same runtime layout and toggles.
- `angie-ctl` is vendored in the image and tests the live tree through
  `ANGIE_BIN=/usr/local/bin/angie-runtime`; activation targets
  `ANGIE_ETC=/data/conf`. Entrypoint activation uses `--no-test` followed by one
  final configuration check. `angie-ctl --reload` sends HUP to pid 1
  (`ANGIE_RELOAD_CMD="kill -HUP 1"`), which tini forwards to the master.
- **BREAKING:** `/etc/angie` is a read-only skeleton: the entrypoint never
  edits it, and angie serves the copy in `/data/conf`. Changes made in
  `/etc/angie` inside a running container are not served; use
  `/etc/angie/custom` or `angie-ctl` on the live tree. `/data` must be
  writable: with `--read-only` and no `/data` mount the start fails with exit
  code 1 and a message naming the mount to add.
- **BREAKING:** the image's log formats are renamed `angie_main`,
  `angie_extended`, `angie_logfmt`, `angie_logfmt_with_geoip` and
  `angie_matomo` (new: `angie_json`, `angie_json_with_geoip`). A consumer
  `access_log ... main;` fails the startup check with
  `unknown log format "main"`; switch to the `angie_` name or declare your own
  `log_format` under a name the image does not use.
- **BREAKING:** variables the image declares carry the `$_stock_` prefix:
  `$connection_upgrade`, `$loopback` and `$geoip2_country_code` are now
  `$_stock_connection_upgrade`, `$_stock_loopback` and
  `$_stock_geoip2_country_code`. A consumer config using an old name fails the
  startup check with `unknown "connection_upgrade" variable` (and likewise);
  declare your own `map` or switch to the new name. The prefix keeps a
  consumer `map`/`geo` of the same name from silently replacing the image's.
- `docker stop` is graceful: `STOPSIGNAL SIGQUIT` lets angie finish open
  requests instead of cutting them (`SIGTERM`). Open connections are closed
  after `worker_shutdown_timeout` (`ANGIE_WORKER_SHUTDOWN_TIMEOUT`, default
  `8s`, below docker's 10 s `stop_grace_period`), so a stop with long-lived
  connections takes up to that long; `docker kill -s TERM <container>` stops
  at once.
- The built-in catch-all vhost no longer carries `default_server`; it stays the
  default by include order, and both `custom/http-conf.d` and `custom/http.d`
  are now included after the image's `http.d`. A consumer can declare
  `listen 80 default_server` (`8080` in the unprivileged image) in
  `custom/http.d` without `a duplicate default server`; a `server {}` in
  `custom/http-conf.d` no longer takes the default silently.
- `ANGIE_STATUS_API_PORT` equal to the built-in listener port (80, or 8080 in
  the unprivileged image) is refused at startup with exit code 1: on a shared
  socket a request with the status server's name would bypass the catch-all
  `444` and reach `/status/` and `/metrics`.
- The Alpine base moves from `alpine:3.22` to `alpine:3.24`; both bases are
  pinned by digest (`ALPINE_BASE_IMAGE`, `DEBIAN_BASE_IMAGE`). Package mirrors
  are build arguments (`ALPINE_MIRROR`, `DEBIAN_MIRROR`,
  `DEBIAN_SECURITY_MIRROR`, `ANGIE_MIRROR`).

### Removed

- `VOLUME /etc/angie/custom`: a `docker run` without its own mount no longer
  creates an anonymous volume per container. Mount `/etc/angie/custom`
  explicitly when you use it.

### Security

- Entrypoint startup refuses to overwrite an unmarked non-empty `/data/conf` or
  one owned by a different UID. Console Light requires a long secret path and,
  by default, a readable htpasswd file. ACME keys and certificates live under
  `/data/acme`; deployments using ACME must use persistent storage rather than
  tmpfs.
- In the standard image `/data` and `/data/tmp` are `root:root 0755`, and
  every start empties `/data/tmp` and resets it to `root:root 0755`: the root
  master chowns temp paths to the worker following links, and a
  worker-writable parent would let a compromised worker redirect that chown to
  a root file. Only the unprivileged image keeps `/data` and `/data/tmp` at
  `1777`.
- Startup refuses a symbolic link at `/data/conf`, `/data/tmp` or
  `/data/acme`, so cleanup and ACME keys never follow a planted link out of
  the data mount. The writability check of `/data` creates its probe file with
  `mktemp` instead of a predictable name.
- `ANGIE_ACME_DIRECTORY` must be an `https://` URL; any other value is refused
  at startup with exit code 1.
- The build checks the Angie signing key against `ANGIE_SIGNING_KEY_SHA256`
  before trusting it, and restricts the Angie repository to Angie's own
  packages (an `@angie` repository tag on Alpine, an APT origin pin on
  Debian), so it cannot replace base distribution packages. Setuid and setgid
  bits are cleared on every file in the image: `su` and `passwd` no longer
  raise the privileges of a non-root process.

## [1.12.4-build1] - 2026-10-20

### Changed

- **Angie 1.12.4** - bump the packaged Angie from 1.12.3 to the
  [1.12.4 upstream release](https://en.angie.software/angie/docs/oss_changes/),
  released on 2026-10-16.

## [1.12.3-build1] - 2026-10-14

### Changed

- **Angie 1.12.3** - the packaged Angie is bumped from 1.12.2 to the
  [1.12.3 upstream release](https://en.angie.software/angie/docs/oss_changes/),
  released on 2026-10-13. Fixes cover early stream logging crashes, incorrect
  log field names, HTTP/3 SSL statistics and upstream handshakes, stalled
  non-idempotent upstream requests, ACME IP-address and wildcard validation,
  shared-memory corruption with upstream keepalive and zone, mail proxy
  logging, and minimal builds.
- **Zstandard module** - the upstream `angie-module-zstd` package now uses
  module version 0.90.9. The installed module set is unchanged; new optional
  upstream modules are not added to these images.

## [1.12.2-build1] - 2026-09-19

### Changed

- **Angie 1.12.2** - the packaged Angie is bumped from 1.12.1 to the current
  [1.12.2 upstream release](https://github.com/webserver-llc/angie/releases/tag/Angie-1.12.2),
  a security release fixing worker process memory corruption/crash on OpenSSL
  3.5.0 and earlier, when an address whose default server also enables HTTP/3
  (`listen ... quic`, possibly on another port) accepts a plain HTTPS request
  that SNI routes to a `server` block without HTTP/3
  ([CVE-2026-90439](https://nvd.nist.gov/vuln/detail/CVE-2026-90439)); the fix
  was ported from nginx 1.31.6. The shipped configuration cannot reach it: no
  baked-in `server` listens with `ssl` or `quic`. TLS listeners layered in
  through `/etc/angie/custom` can.
- **Zstandard module source** - upstream switched the `angie-module-zstd`
  package to
  [myguard-labs/nginx-zstd-module](https://github.com/myguard-labs/nginx-zstd-module)
  0.90.8. Module file names and the `zstd*` directives used by
  `020-zstd.conf` / `021-zstd_static.conf` are unchanged.

## [1.12.1-build1] - 2026-07-18

### Changed

- **Angie 1.12.1** - the packaged Angie is bumped from 1.12.0 to the current
  [1.12.1 upstream release](https://github.com/webserver-llc/angie/releases/tag/Angie-1.12.1),
  a security release fixing worker process memory corruption/crash issues in
  `map` capture variables ([CVE-2026-42533](https://nvd.nist.gov/vuln/detail/CVE-2026-42533),
  [CVE-2026-60005](https://nvd.nist.gov/vuln/detail/CVE-2026-60005)) and SSI
  with unbuffered proxying
  ([CVE-2026-56434](https://nvd.nist.gov/vuln/detail/CVE-2026-56434)) - all
  ported from nginx 1.31.3 - plus Metric module and `least_time` upstream
  bugfixes.

## [1.12.0-build2] - 2026-07-16

### Added

- **Status API and Prometheus metrics** toggled with `ANGIE_STATUS_API_ENABLED`:
  a dedicated listener (default `0.0.0.0:8181`, configurable via
  `ANGIE_STATUS_API_HOST` / `ANGIE_STATUS_API_PORT` with charset validation)
  serving Angie's read-only JSON statistics tree at `/status/` and the stock
  `all` Prometheus template at `/metrics`. The port is not `EXPOSE`d and is
  never published by default - reachable from the container's Docker network
  until explicitly published.
- **Structured JSON error log** toggled with `ANGIE_ERROR_LOG_JSON_ENABLED`:
  switches the `error_log` in `angie.conf` to Angie 1.12.0's `format=json`
  (one object per line with time, level, message, and request/upstream
  context) and reverts it when unset. A customized `error_log` line is left
  alone; a read-only config is a warned no-op.

## [1.12.0-build1] - 2026-07-16

### Changed

- **Angie 1.12.0** - the packaged Angie is bumped from 1.11.8 to the current
  [1.12.0 upstream release](https://github.com/webserver-llc/angie/releases/tag/Angie-1.12.0).
- `angie-ctl` is bumped to the current upstream, which removed its per-call
  `angie -t` together with the `--no-test` flag; the entrypoint wrapper now
  invokes `angie-ctl` bare. No behavior change: per-call validation was already
  disabled in this image - the entrypoint still validates the assembled config
  once with its single final `angie -t`.
- Heads-up from the Angie 1.12.0 bump itself: the `resolver` directive now
  defaults to `conf` - DNS servers are read from `/etc/resolv.conf` (in a
  container, Docker's embedded DNS) and re-read on change - so dynamic upstream
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
  load would crash-loop angie after `exec` - it now fails loudly with the test
  output instead.

## [1.11.8-build3] - 2026-06-25

### Changed

- Feature toggles are now declarative. Every entrypoint toggle resets the
  snippets and modules it manages at the start of each run (via new
  `reset_httpconf` / `reset_module` helpers) and re-enables only what the current
  `ANGIE_*` environment requests. Removing a variable now disables its feature on
  the next start, instead of an enable-only toggle leaving it stuck on across
  restarts on a persistent `/etc/angie` volume. Layer custom configuration
  through `/etc/angie/custom`, not by hand-enabling shipped snippets - those are
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

- **Zstandard compression** - a fifth bundled dynamic module
  (`angie-module-zstd`), shipped disabled and toggled with `ANGIE_ZSTD_ENABLED`
  / `ANGIE_ZSTD_STATIC_ENABLED`, symmetric to the Brotli and gzip controls.
- **Real-IP recovery** behind a trusted proxy/load balancer/ingress via
  `ANGIE_REAL_IP_FROM` (plus `ANGIE_REAL_IP_HEADER` and
  `ANGIE_REAL_IP_RECURSIVE`), with charset validation of every trusted-proxy
  entry to prevent config injection. Uses the built-in real-IP module - no extra
  package.
- **Baseline security response headers** toggled with
  `ANGIE_SECURITY_HEADERS_ENABLED` (`X-Content-Type-Options`, `Referrer-Policy`,
  `X-Frame-Options`, `Permissions-Policy`), applied with `always`.

## [1.11.8-build1] - 2026-06-23

First public release: Angie 1.11.8 packaged for `linux/amd64` and `linux/arm64`.

### Added

- Angie 1.11.8 on two bases - **Alpine** (default) and **Debian** - each with a
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
  Docker Hub (`6run0/angie`) with immutable `...-build<N>` and floating tags.

[Unreleased]: https://github.com/6RUN0/docker-angie/compare/v1.12.4-build1...HEAD
[1.12.4-build1]: https://github.com/6RUN0/docker-angie/releases/tag/v1.12.4-build1
[1.12.3-build1]: https://github.com/6RUN0/docker-angie/releases/tag/v1.12.3-build1
[1.12.2-build1]: https://github.com/6RUN0/docker-angie/releases/tag/v1.12.2-build1
[1.12.1-build1]: https://github.com/6RUN0/docker-angie/releases/tag/v1.12.1-build1
[1.12.0-build2]: https://github.com/6RUN0/docker-angie/releases/tag/v1.12.0-build2
[1.12.0-build1]: https://github.com/6RUN0/docker-angie/releases/tag/v1.12.0-build1
[1.11.8-build4]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build4
[1.11.8-build3]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build3
[1.11.8-build2]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build2
[1.11.8-build1]: https://github.com/6RUN0/docker-angie/releases/tag/v1.11.8-build1

Russian: [CHANGELOG.ru.md](CHANGELOG.ru.md).
