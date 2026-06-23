# Limitations

Known boundaries and constraints of the Angie Docker image.

## 1. ModSecurity: WAF engine only, no default ruleset

The image loads the ModSecurity shared library, but **no rule set is bundled**.
Enabling the WAF module (`ANGIE_MODSECURITY_ENABLED=yes`) activates only the engine
itself; without rules, it performs no filtering. You must supply a ruleset --
such as [OWASP Core Rule Set](https://coreruleset.org/) -- and point ModSecurity
at it via a custom configuration file mounted under `/etc/angie/custom`.

## 2. All modules are dynamic and disabled by default

Brotli, GeoIP2, ModSecurity, and the substitutions filter are all built as
dynamic modules. None are loaded unless explicitly enabled through the
corresponding `ANGIE_*` environment variable at container start. A module whose
`load_module` directive is absent from `modules.d/` is completely inert,
regardless of whether its shared library is present in the image.

## 3. Configuration runs once per container lifetime

The entrypoint scripts in `/docker-entrypoint.d/` run **only once**, when the
container first starts. The `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` script
enforces this explicitly: it writes a sentinel comment into `angie.conf` on
first run and exits early on any subsequent execution that finds that sentinel.

As a consequence, changing any `ANGIE_*` variable takes effect **only after
recreating the container** (`docker compose up --force-recreate` or
`docker rm` + `docker run`). A plain `docker restart` re-executes the
entrypoint, but the idempotency guards prevent re-applying configuration, so the
old settings remain in effect.

## 4. No TLS listener by default

The image `EXPOSE`s port 80 (privileged) or 8080 (unprivileged). The
`050-ssl.conf` snippet is active by default -- it is a git-tracked symlink in
`http-conf.d/` -- but it contains only SSL session cache and cipher-preference
tuning. No `server` block in the shipped configuration uses `listen ... ssl`,
so HTTPS is not served out of the box. To terminate TLS, add a vhost with an
`ssl` listener via the `/etc/angie/custom` volume.

## 5. `latest` tag means Alpine only

The `latest` tag on Docker Hub (`6run0/angie`) and GHCR
(`ghcr.io/6run0/docker-angie`) resolves to the Alpine variant. To use the Debian
variant, pull an explicit tag such as `debian` or `1.11.8-build1-debian`. There
is no `latest-debian` convenience alias.

## 6. Worker-process autotune is a no-op on a read-only filesystem

When `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` is set, the entrypoint script
(`30-tune-worker-processes.sh`) rewrites `worker_processes` in `angie.conf` in
place using `sed -i`. If the container filesystem is read-only (e.g., deployed
with `readOnlyRootFilesystem: true`), the `touch /etc/angie/angie.conf` probe
fails and the script exits without tuning, logging an error. The
`worker_processes` directive retains its baked-in default value.

## 7. Platform support: `linux/amd64` and `linux/arm64` only

Images are built and tested only for `linux/amd64` and `linux/arm64`. Other
architectures (e.g., `linux/arm/v7`, `linux/s390x`) are not supported and no
manifest entries exist for them.

## 8. The default image requires a root user

The default image binds port 80, and its pid file (`/run/angie.pid`) and cache
directories (`/var/cache/angie/*`) are root-owned. Running the default image
as a non-root user will cause an immediate startup failure with a clear error
message. For rootless operation, use the `-unprivileged` image variant, which
listens on port 8080 and has its paths relocated accordingly.
See [security.md](security.md) for details.

---

[English](limitations.md) | [Русский](limitations.ru.md)

- [Configuration reference](configuration.md)
- [Security hardening](security.md)
