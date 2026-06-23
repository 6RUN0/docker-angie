# Docker Compose examples

The `docker-compose.yml` at the repository root is aimed at **local image
builds** (`build: context: .`) with ports commented out by default. The
examples below use the **published images** from Docker Hub / GHCR and are
ready to run without cloning this repository or building anything locally.

Available tags:

| Tag | Base | Port | Runs as |
|-----|------|------|---------|
| `alpine` / `latest` | Alpine | 80 | root |
| `debian` | Debian | 80 | root |
| `alpine-unprivileged` | Alpine | 8080 | uid 65532 |
| `debian-unprivileged` | Debian | 8080 | uid 65532 |

GHCR mirror: `ghcr.io/6run0/docker-angie:<tag>`

---

## Minimal example

A single service that starts with no extra configuration. The built-in
`HEALTHCHECK` (port 80) fires automatically; the `healthcheck:` block below
overrides it only to show the compose syntax -- you can omit it entirely.

```yaml
services:
  angie:
    image: 6run0/angie:alpine
    container_name: angie
    restart: unless-stopped
    ports:
      - "8080:80"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost/healthz"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
```

```bash
docker compose up
```

The server is reachable at `http://localhost:8080/`.

---

## Realistic example with feature toggles and custom config

Mount your vhost and snippet files under `/etc/angie/custom` (read-only) and
enable built-in features via `ANGIE_*` environment variables. The path
`./angie-config` is a directory you create next to your `compose.yml`; it is
not baked into the image.

```yaml
networks:
  front:

services:
  angie:
    image: 6run0/angie:alpine
    container_name: angie
    restart: unless-stopped
    networks:
      - front
    ports:
      - "80:80"
    volumes:
      # Place your vhost conf, SSL certs, and custom snippets here.
      # The :ro flag prevents the container from writing back to the host.
      - ./angie-config:/etc/angie/custom:ro
    environment:
      ANGIE_BROTLI_ENABLED: "yes"
      ANGIE_GZIP_ENABLED: "yes"
      ANGIE_MAP_WEBSOCKET_ENABLE: "yes"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost/healthz"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
```

Accepted truthy values for all `ANGIE_*` toggles: `yes`, `on`, `1`, `true`,
`enable`, `enabled`. Any other value (or the variable being absent) leaves the
feature disabled.

See `../README.md` for the full environment-variable reference.

---

## Rootless (unprivileged) example

The `-unprivileged` images listen on port **8080** and default to uid/gid
`65532` -- no root, no `CAP_NET_BIND_SERVICE`. The `user:` key below is
redundant (the image already sets `USER 65532`) but makes the intent explicit
for auditors and k8s `runAsUser` parity.

```yaml
services:
  angie:
    image: 6run0/angie:alpine-unprivileged
    container_name: angie
    user: "65532:65532"
    restart: unless-stopped
    ports:
      - "8080:8080"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/healthz"]
      interval: 30s
      timeout: 3s
      start_period: 5s
      retries: 3
```

Override the runtime identity without rebuilding:

```bash
docker compose run --user 1000:1000 angie
```

Any uid that can write `/etc/angie/http-conf.d` and `/etc/angie/modules.d`
(chowned to `65532` in the image) can also toggle features via `ANGIE_*`
variables at startup. A foreign uid that cannot write those dirs falls back to
the baked-in defaults silently.

---

## Healthcheck port reference

| Image variant | Container port | Healthcheck URL |
|---------------|---------------|-----------------|
| `alpine` / `debian` | 80 | `http://127.0.0.1/healthz` |
| `alpine-unprivileged` / `debian-unprivileged` | 8080 | `http://127.0.0.1:8080/healthz` |

Both images ship a `HEALTHCHECK` instruction; the compose `healthcheck:` block
overrides it when you need different timing parameters. To keep the image
defaults, omit the `healthcheck:` key entirely.

---

- [English](compose.md) | [Russian](compose.ru.md)
- [Usage and configuration](../README.md)
