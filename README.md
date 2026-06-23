# Angie Docker image with Brotli, GeoIP2, ModSecurity (WAF), and substitutions

Production-ready [Angie](https://angie.software) (an nginx fork) packaged with four
dynamic modules, runtime feature toggles, and a non-root variant.

[![CI](https://github.com/6RUN0/docker-angie/actions/workflows/ci.yml/badge.svg)](https://github.com/6RUN0/docker-angie/actions/workflows/ci.yml)
[![Docker pulls](https://img.shields.io/docker/pulls/6run0/angie)](https://hub.docker.com/r/6run0/angie)
[![Image size](https://img.shields.io/docker/image-size/6run0/angie/alpine?label=alpine%20size)](https://hub.docker.com/r/6run0/angie/tags)
[![Architectures](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-blue)](#pull)
[![License: MIT](https://img.shields.io/github/license/6RUN0/docker-angie)](LICENSE)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange)](#versioning)

The bundled modules — Brotli, GeoIP2, ModSecurity (WAF), and the substitutions
filter — ship **disabled** and are switched on at container start through
`ANGIE_*` environment variables. Two bases are published: **Alpine** (default)
and **Debian**, each with a rootless **unprivileged** variant.

## Prerequisites

- Docker Engine 20.10+ (or any runtime that can pull OCI images).
- To build multi-arch images yourself: Docker with the `buildx` plugin.
- The default image binds port **80** inside the container; the unprivileged
  variant binds **8080** and runs as a non-root user.

## Pull

Images are published on every tagged `v*` release to two registries, for
`linux/amd64` and `linux/arm64`:

```bash
# GitHub Container Registry
docker pull ghcr.io/6run0/docker-angie:alpine

# Docker Hub
docker pull 6run0/angie:alpine
```

Pin an immutable tag for reproducible deployments — see [Versioning](#versioning).

## Quick start

```bash
docker run -d --name angie -p 8080:80 6run0/angie:alpine
```

Confirm it is live via the same loopback endpoint the built-in HEALTHCHECK uses
(`/healthz` is intentionally loopback-only, so query it from inside the
container):

```bash
docker exec angie wget -qO- http://127.0.0.1/healthz   # -> ok
```

From the host, every request to an unmatched host returns `444` (connection
closed) — add your own server blocks via the custom-config volume to serve real
traffic.

## Usage

Enable features with `ANGIE_*` variables and mount your config:

```bash
docker run -d --name angie \
  -p 80:80 \
  -e ANGIE_BROTLI_ENABLED=yes \
  -e ANGIE_GZIP_ENABLED=yes \
  -v "$PWD/angie-config:/etc/angie/custom:ro" \
  6run0/angie:alpine
```

Rootless deployment (listens on 8080, runs as uid/gid 65532):

```bash
docker run -d -p 8080:8080 6run0/angie:alpine-unprivileged
```

- Compose examples → [docs/compose.md](docs/compose.md)
- Building the images from source → [docs/usage.md](docs/usage.md)

## Configuration

Key toggles (full table of 20+ variables in
[docs/configuration.md](docs/configuration.md)):

| Variable | Default | Description |
| --- | --- | --- |
| `ANGIE_BROTLI_ENABLED` | `no` | Load the Brotli module and enable Brotli compression. |
| `ANGIE_GZIP_ENABLED` | `no` | Enable gzip compression. |
| `ANGIE_MODSECURITY_ENABLE` | `no` | Enable the ModSecurity WAF module. |
| `ANGIE_SUBS_ENABLE` | `no` | Enable the response-body substitutions filter. |
| `GEOIP2_DB_COUNTRY` | unset | Path to a GeoIP2 country DB; enables GeoIP2 when readable. |
| `ANGIE_MAP_WEBSOCKET_ENABLE` | `no` | Enable the WebSocket upgrade variable map. |
| `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` | unset | Tune `worker_processes` to the CPU count at start. |

Mount custom configuration at the **`/etc/angie/custom`** volume.

## Data and state

The image is **stateless** — all runtime config is derived from `ANGIE_*`
variables and the `/etc/angie/custom` volume at container start; nothing is
written that needs backing up. Configuration is applied **once at creation**, so
changing an `ANGIE_*` variable takes effect on container **recreate**, not
`docker restart`. The unprivileged image runs as uid/gid `65532` and owns
`/etc/angie/*.d`; see [docs/security.md](docs/security.md) for running under a
foreign `--user`.

## Limitations

- ModSecurity loads the engine only — no rule set ships by default; bring your
  own (e.g. the OWASP CRS).
- The bundled modules are dynamic and off until toggled.
- Full list → [docs/limitations.md](docs/limitations.md).

## Versioning

Tags follow the upstream release version with a variant suffix:

| Tag | Meaning |
| --- | --- |
| `<x.y.z>-alpine`, `<x.y.z>-debian` | Immutable, fully-qualified — **pin this**. |
| `<x.y>-alpine` | Latest patch of a minor line (stable releases only). |
| `alpine`, `debian` | Latest stable of that base. |
| `latest` | Latest stable **Alpine** image. |
| `*-unprivileged` | Rootless variant; suffixes the base/version tags (e.g. `alpine-unprivileged`, `<x.y.z>-alpine-unprivileged`), but not `latest`. |

Floating tags move only for stable `x.y.z` releases; a prerelease (e.g.
`1.2.3-rc1`) publishes its immutable tag only.

## Documentation

- [Configuration](docs/configuration.md) — full env/volume/port reference
- [Usage](docs/usage.md) — building, entrypoint, logs, exit codes
- [Compose](docs/compose.md) — ready-to-run compose files
- [Security](docs/security.md) — non-root, capabilities, secrets
- [Limitations](docs/limitations.md) — known boundaries
- [Troubleshooting](docs/troubleshooting.md) — common errors

Russian: [README.ru.md](README.ru.md).

## License

[MIT](LICENSE) for this packaging. Angie and the bundled third-party modules
retain their own respective licenses.
