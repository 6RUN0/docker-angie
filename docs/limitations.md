# Limitations

Known boundaries of the Angie Docker image.

## 1. ModSecurity includes the engine, not a ruleset

`ANGIE_MODSECURITY_ENABLED=yes` loads ModSecurity but does not block anything
without rules. Supply and review a ruleset through `/etc/angie/custom`.

## 2. Optional dynamic modules are disabled by default

Brotli, GeoIP2, ModSecurity, substitutions, and Zstandard are loaded only when
enabled. The ACME client is built into Angie but remains inactive until both the
toggle and a referencing custom server are present.

## 3. Environment is fixed when a container is created

The entrypoint rebuilds `/data/conf` on every start, so a restart re-applies the
same environment. Changing Compose or `docker run` environment values requires
container recreation. Editing `/etc/angie/custom` does not: validate the live
tree and send HUP.

## 4. No TLS listener by default

The image provides TLS defaults but no `listen ... ssl` server. Add a custom
vhost or terminate TLS upstream. HSTS and Console Light should not be exposed
before TLS is working.

## 5. `latest` is Alpine only

Use `debian` or an immutable Debian tag explicitly. Unprivileged tags carry the
`-unprivileged` suffix; there is no rootless `latest` alias.

## 6. `/data` must be writable

Both image variants support a read-only root filesystem, but the entrypoint must
build `/data/conf` and Angie must write `/data/tmp`. Mount `/data` as tmpfs or a
volume. Do not mount `/data/conf` by itself.

A persistent `/data/conf` is tied to its creating UID. A container running as a
different UID fails rather than overwriting it. Use a fresh volume or change
ownership outside the application container.

## 7. ACME requires persistent storage

`/data/acme` holds account keys and certificates. A tmpfs loses them on every
recreation, triggers new certificate orders, and can hit CA rate limits. HTTP is
the only challenge flow prepared by the image; DNS and ALPN require additional
network and DNS configuration.

## 8. Open-file caching delays file updates

With `ANGIE_OPEN_FILE_CACHE_ENABLED=yes`, descriptor and metadata caching can
make an edited or replaced file appear stale for the configured validity
interval. Disable it while diagnosing file-deployment issues.

## 9. Ports and privileges differ by variant

The standard image needs a root master or `CAP_NET_BIND_SERVICE` for port 80;
workers run as `angie`. The unprivileged image uses port 8080 and needs no
capabilities. It cannot bind an ACME challenge port below 1024 internally.

## 10. Supported platforms

Published images target `linux/amd64` and `linux/arm64`. Other architectures
are not built or tested.

## 11. Kubernetes conditions are documented, not cluster-tested

Use `readOnlyRootFilesystem: true`, mount writable `emptyDir` or persistent
storage at `/data`, and match the service/healthcheck port to the chosen image
variant. The project does not currently claim end-to-end Kubernetes validation.

---

[Configuration](configuration.md) | [Security](security.md)

Russian: [limitations.ru.md](limitations.ru.md).
