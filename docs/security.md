# Security and Running Without Root

This document describes the user and privilege model of the Angie Docker images,
hardening options, and responsible disclosure guidance.

## User model

### Standard image (`6run0/angie`, `ghcr.io/6run0/docker-angie`)

The standard image starts its master process as **root**. This is the classical
nginx/Angie model:

- The master process binds to port 80 (requires `CAP_NET_BIND_SERVICE` or root).
- It owns root-controlled paths: the pidfile `/run/angie.pid` and proxy/cache
  temp directories.
- After binding, the master forks workers and drops their privileges to the
  package user `angie` (set via `user angie;` in `angie.conf`).

The container is therefore **not rootless**: the master remains root throughout
its lifetime, and the workers run as `angie`. Entrypoint steps that require root
(chown of cache directories, htpasswd files) are gated by an `is_root` check in
`90-fix-cache-permission.sh` and `90-fix-htpasswd-permission.sh`; when the
container is started with `docker run --user`, those steps are skipped with a
notice. Similarly, `30-tune-worker-processes.sh` writes to `/etc/angie/angie.conf`
and exits cleanly when the file is not writable (read-only FS or non-root user).

### Unprivileged image (`6run0/angie:...-unprivileged`, `ghcr.io/6run0/docker-angie:...-unprivileged`)

The unprivileged variant is a separate image built on top of the standard one.
It is designed to run under any uid with no Linux capabilities.

Key differences from the standard image:

| Property | Standard | Unprivileged |
|---|---|---|
| Default user | root | `app` (uid/gid 65532) |
| Listener port | 80 | 8080 |
| Pidfile / temp | root-owned paths | `/tmp/angie/` (0777, no sticky bit) |
| `user angie;` directive | present | removed at build time |
| Capabilities needed | `CAP_NET_BIND_SERVICE` (or root) for port 80 | none |

**The `app` user.** The image creates a dedicated user `app` with uid/gid 65532
(the distroless "nonroot" value, chosen to avoid collisions with typical host
users). The identity is controlled by build arguments:

```text
--build-arg APP_USER=app
--build-arg APP_GROUP=app
--build-arg APP_UID=65532
--build-arg APP_GID=65532
```

**Runtime feature toggles.** The build process `chown`s the activation
directories (`/etc/angie/http-conf.d`, `/etc/angie/modules.d`,
`/etc/angie/http-conf-available.d`) to `app:app`. When the container runs under
the default user (`app`), `ANGIE_*` environment-variable toggles work normally:
the entrypoint scripts can create and remove symlinks via `angie-ctl`.

When a custom `--user <uid>` is supplied that does not own those directories, the
entrypoint scripts detect the write failure and fall back to the configuration
that was baked in at build time. Feature toggles are silently skipped with a
warning in that case.

**`/tmp/angie/`.** The directory is created world-writable without the sticky
bit so that any uid -- including a foreign `docker run --user` -- can create the
pidfile and temp directories it needs. The absence of the sticky bit allows
Angie's `rename(angie.pid.tmp -> angie.pid)` to succeed across uid boundaries.

## Hardening recommendations

The flags below apply to `docker run`. Equivalent options exist in Compose
(`security_opt`, `cap_drop`, `tmpfs`) and Kubernetes (`securityContext`).

### Drop all capabilities

```sh
docker run --cap-drop ALL 6run0/angie:alpine-unprivileged ...
```

The unprivileged image needs no Linux capabilities. For the standard image
binding to port 80 you must restore one:

```sh
docker run --cap-drop ALL --cap-add NET_BIND_SERVICE 6run0/angie ...
```

### Read-only root filesystem

```sh
# Unprivileged image -- /tmp already holds pid and temp paths
docker run --read-only --tmpfs /tmp 6run0/angie:alpine-unprivileged ...

# Standard image -- /tmp, /run, and /var/cache/angie need writable space
docker run --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  --tmpfs /var/cache/angie \
  6run0/angie ...
```

Note: `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` requires writing to
`/etc/angie/angie.conf`. On a read-only filesystem, `30-tune-worker-processes.sh`
detects the unwritable file and exits without error -- autotune is silently
disabled. This is expected behavior; set `worker_processes` explicitly via a
custom config volume instead.

### Prevent privilege escalation

```sh
docker run --security-opt no-new-privileges:true ...
```

This prevents any `setuid` binary inside the container from gaining additional
privileges. Combine it with `--cap-drop ALL`.

### Restrict network exposure

Publish only the ports your workload needs:

```sh
# Unprivileged
docker run -p 127.0.0.1:8080:8080 6run0/angie:alpine-unprivileged ...

# Standard
docker run -p 80:80 6run0/angie ...
```

The images `EXPOSE` a single HTTP port (80 or 8080). There is no TLS listener
by default; the shipped `050-ssl.conf` configures SSL session and cipher tuning
only -- no `listen ... ssl` directive is active. HTTPS requires a custom vhost
configuration mounted via the `/etc/angie/custom` volume.

### Compose example (unprivileged, fully hardened)

```yaml
services:
  angie:
    image: ghcr.io/6run0/docker-angie:alpine-unprivileged
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./config:/etc/angie/custom:ro
```

## Secrets management

Do not pass secrets as plain environment variables. Environment variables are
visible in `docker inspect`, process listings, and container logs.

Preferred approaches:

- **Config volume.** Mount credentials (htpasswd files, TLS certificates, API
  keys for GeoIP2) into `/etc/angie/custom` as files:

  ```sh
  docker run -v /path/to/secrets:/etc/angie/custom:ro 6run0/angie ...
  ```

- **Docker / Compose secrets.** Use the `secrets:` stanza in Compose or
  `docker secret` in Swarm to bind-mount secret files at a well-known path, then
  reference that path from your Angie config.

## Network exposure

The standard image `EXPOSE`s port **80** only. The unprivileged image `EXPOSE`s
port **8080** only. No other ports are opened by default.

TLS termination is not active out of the box. The included `050-ssl.conf` sets
SSL session cache, timeout, and cipher preferences but does not define any
`server` block with `listen ... ssl`. To enable HTTPS, add a server definition
under `/etc/angie/custom/` that includes a `listen 443 ssl;` directive and the
appropriate certificate paths.

## Reporting vulnerabilities

Please report security vulnerabilities **privately**. Do not open a public
GitHub issue for a vulnerability.

Submit a report via GitHub Security Advisories:
<https://github.com/6RUN0/docker-angie/security/advisories/new>

Alternatively, contact the maintainer directly. We aim to acknowledge reports
within 72 hours and to coordinate disclosure before any public announcement.

---

- [Back to README](../README.md)
- [Russian version](./security.ru.md)
