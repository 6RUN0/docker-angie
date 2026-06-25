# Troubleshooting

Common problems, their causes, and how to fix them.

See also: [../README.md](../README.md)

---

## 1. Port already in use (`bind: address already in use`)

**Symptom.** The container exits immediately with an error like:

```text
nginx: [emerg] bind() to 0.0.0.0:80 failed (98: Address already in use)
```

**Cause.** Another process on the host is already listening on the mapped port.

**Fix.** Map to a different host port:

```sh
docker run -p 8081:80 6run0/angie:alpine
```

To find which process owns the port:

```sh
# Linux
ss -tlnp sport = :80
# or
lsof -i :80
```

The unprivileged variant listens inside the container on port 8080, so map
accordingly:

```sh
docker run -p 8081:8080 6run0/angie:alpine-unprivileged
```

---

## 2. Every request returns 444 / connection closed with no response

**Symptom.** `curl http://localhost/` exits with "Empty reply from server" or
curl error 52. A browser shows a "connection was reset" page.

**Cause.** This is the intended default behavior. The built-in catch-all
`server` block returns 444 (connection close without response) for any request
that does not match a configured `server_name`. No virtual host has been added
yet.

**Fix.** Add your own server block via the `/etc/angie/custom` volume:

```sh
# /path/to/custom/http.d/mysite.conf
server {
  listen 80;
  server_name mysite.example.com;
  location / { return 200 "hello\n"; }
}
```

```sh
docker run -p 80:80 \
  -v /path/to/custom:/etc/angie/custom:ro \
  6run0/angie:alpine
```

**Health check is unaffected.** `GET /healthz` always returns `ok` (200) on
the loopback interface regardless of whether any user vhost is configured.

---

## 3. `ANGIE_*` toggle has no effect

### 3a. Container was restarted, not recreated

**Symptom.** You updated an environment variable and ran `docker restart
<container>`. The feature is still not active.

**Cause.** `docker restart` keeps the same container and therefore the same
environment variables that were baked in at `docker run` time. The entrypoint
scripts re-run on each start, but they see the original env, not the updated
one.

**Fix.** Remove and recreate the container:

```sh
docker rm -f mycontainer
docker run ... -e ANGIE_BROTLI_ENABLED=1 --name mycontainer 6run0/angie:alpine
```

With Compose, `docker compose up` (not `restart`) recreates containers whose
environment has changed.

### 3b. Running unprivileged with a foreign uid

**Symptom.** You ran the unprivileged image with `--user <uid>` where `<uid>`
is not the built-in `app` user (uid/gid 65532). Toggles are silently skipped
and the container starts with the configuration baked in at build time.

**Cause.** The entrypoint scripts call `angie-ctl` to symlink snippets into
`/etc/angie/*.d`. Those directories are pre-chowned to uid/gid 65532 at build
time. A different uid lacks write permission, so `skip_toggle_unless_writable`
in `docker-entrypoint-common.sh` detects the unwritable dirs, logs a warning,
and skips the toggle rather than aborting startup.

**Fix.** Either use the default uid:

```sh
docker run --user 65532:65532 6run0/angie:alpine-unprivileged
```

Or rebuild the unprivileged image with `--build-arg APP_UID=<your-uid>
--build-arg APP_GID=<your-gid>` so the activation dirs are owned by your
chosen identity.

---

## 4. Permission errors on mounted volumes

### 4a. `/etc/angie/custom` bind-mount

**Symptom.** Angie fails to start or logs permission errors reading config
files from `/etc/angie/custom`.

**Cause.** The `custom` directory is mounted read-only inside the container,
but the host directory or its files are not world-readable.

**Fix.** Ensure the host path is readable by the container's runtime user:

- **Default image (runs as root):** the host path must be at least
  `chmod o+r` or owned by root.
- **Unprivileged image (uid/gid 65532 by default):** chown the host path to
  65532 or make it world-readable:

  ```sh
  chown -R 65532:65532 /path/to/custom
  docker run --user 65532:65532 \
    -v /path/to/custom:/etc/angie/custom:ro \
    6run0/angie:alpine-unprivileged
  ```

### 4b. `CACHE_DIR` bind-mount

**Symptom.** Angie logs `chown` errors or the proxy cache fails at runtime.

**Cause.** When `CACHE_DIR` is set, `90-fix-cache-permission.sh` runs
`chown angie: <CACHE_DIR>` recursively at startup. This requires the container
to be running as root; the script skips silently on the unprivileged variant.

**Fix.** For the default image, ensure the mounted directory is writable by
the container:

```sh
docker run \
  -e CACHE_DIR=/var/cache/angie/proxy \
  -v /host/cache:/var/cache/angie/proxy \
  6run0/angie:alpine
```

For the unprivileged image, pre-chown the host path before mounting:

```sh
chown -R 65532:65532 /host/cache
docker run --user 65532:65532 \
  -e CACHE_DIR=/var/cache/angie/proxy \
  -v /host/cache:/var/cache/angie/proxy \
  6run0/angie:alpine-unprivileged
```

---

## 5. GeoIP2 module has no effect

**Symptom.** GeoIP2 variables (`$geoip2_data_country_code`, etc.) are empty
or the module is not loaded.

**Cause.** `50-geoip2.sh` activates GeoIP2 only when `GEOIP2_DB_COUNTRY` is
set to a path that exists and is readable inside the container. If the path is
wrong, missing, or not mounted, the script logs a warning and exits 0 without
enabling the module.

```sh
# Script behavior (from rootfs/docker-entrypoint.d/50-geoip2.sh):
# - GEOIP2_DB_COUNTRY unset  -> silently skipped
# - path does not exist or not readable -> warning, module not loaded
# - path contains characters outside [A-Za-z0-9._/-] -> fatal error, startup aborted
```

**Fix.** Mount the MaxMind `.mmdb` database and point the variable at the
in-container path:

```sh
docker run \
  -e GEOIP2_DB_COUNTRY=/geoip/GeoLite2-Country.mmdb \
  -v /host/path/to/GeoLite2-Country.mmdb:/geoip/GeoLite2-Country.mmdb:ro \
  6run0/angie:alpine
```

Verify the module loaded:

```sh
docker exec <container> angie -T 2>/dev/null | grep geoip2
```

**Related — startup aborts with `unknown "geoip2_country_code" variable`.** A
geoip2 log format enabled on a previous run can outlive geoip2 on a persistent
`/etc/angie` volume. angie validates the variables of every declared
`log_format`, so the orphaned `*-with-geoip2` format fails `angie -t` for the
whole config even when unused. `40-log.sh` clears these snippets at startup, so
recreating the container heals it; to fix a running container, disable both the
access log and its format together (a single `angie-ctl dis` call removes both
symlinks, then validates once):

```sh
docker exec <container> angie-ctl httpconf dis \
  040-log-logfmt-with-geoip2.conf 030-log-format-logfmt-with-geoip2.conf
```

The geoip2 map itself can orphan the same way — a stale `geoip2 <path>` left by
a prior run fails `angie -t` with `MMDB_open(...) failed` once the database is
gone. The entrypoint clears the map and its module at startup, so recreating the
container heals this too.

**General rule.** Feature toggles are declarative: the entrypoint resets the
snippets and modules it manages at every start, then re-enables only what the
current `ANGIE_*` environment asks for. Removing a variable disables its feature
on the next start (restart or recreate the container so the entrypoint re-runs),
even on a persistent `/etc/angie` volume. Layer your own configuration through
the `/etc/angie/custom` volume rather than enabling shipped snippets by hand —
a hand-enabled snippet is disabled again on the next start. For example,
disabling the default access log (`ANGIE_LOG_LOGFMT=no`) without selecting
another format leaves the config with no global `access_log` at all — that is
the declarative result, not a fault (`angie -t` still passes). The one exception
is `worker_processes` auto-tuning (`ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE`),
which rewrites `angie.conf` in place behind a one-time sentinel: a value tuned on
a prior run stays until you reset the file or recreate the volume (this is a
benign performance value and never fails `angie -t`).

---

## 6. ModSecurity is enabled but nothing is blocked

**Symptom.** `ANGIE_MODSECURITY_ENABLED=1` is set, Angie starts, but malicious
requests pass through without being blocked.

**Cause.** The image loads the ModSecurity dynamic module (`libmodsecurity`)
and enables the Angie connector, but it does not bundle any rule set. Without
rules, the WAF engine runs in detection mode with nothing to match against and
blocks nothing.

**Fix.** Supply an external rule set such as the OWASP Core Rule Set (CRS):

```sh
docker run \
  -e ANGIE_MODSECURITY_ENABLED=1 \
  -v /host/path/to/crs:/etc/angie/modsec/crs:ro \
  6run0/angie:alpine
```

Your ModSecurity configuration should `Include` the rule files. See
[limitations.md](limitations.md) for the full list of WAF constraints and
[configuration.md](configuration.md) for the `ANGIE_MODSECURITY_ENABLED` toggle.

---

## 7. Container killed by OOM / out-of-memory

**Symptom.** The container exits with status 137 (killed by SIGKILL), and the
host OOM killer log shows the Angie master or worker process as the victim.

**Cause.** The default configuration is tuned for high-concurrency production
use:

- `worker_rlimit_nofile 65536` - maximum open file descriptors per worker
- `worker_connections 32768` - maximum simultaneous connections per worker

Under a Docker memory limit this can exhaust the container's address space or
trigger the OOM killer before connection queues actually fill up.

**Fix.** Lower the limits via the custom volume:

```sh
# /path/to/custom/angie.conf or a snippet under custom/http.d/
worker_rlimit_nofile 8192;
events {
  worker_connections 4096;
}
```

```sh
docker run \
  -m 256m \
  -v /path/to/custom:/etc/angie/custom:ro \
  6run0/angie:alpine
```

Or raise the container memory limit to match the expected concurrency.

---

## 8. `exec format error` / wrong architecture

**Symptom.** The container fails immediately with:

```text
standard_init_linux.go:228: exec user process caused "exec format error"
```

**Cause.** Docker pulled the image for a different CPU architecture than the
host (e.g., arm64 image on an amd64 host, or vice versa). The image supports
`linux/amd64` and `linux/arm64`.

**Fix.** Pull the correct architecture explicitly:

```sh
docker run --platform linux/amd64 6run0/angie:alpine
docker run --platform linux/arm64 6run0/angie:alpine
```

When building multi-arch images with Buildx, specify `--platform
linux/amd64,linux/arm64`.

---

## 9. Container exits immediately on startup

**Symptom.** `docker ps` never shows the container as running. `docker logs
<container>` shows an error from one of the entrypoint scripts.

**Cause.** The entrypoint runs every executable `*.sh` file inside
`/docker-entrypoint.d/` in lexical order. If any script exits non-zero, the
main shell (`set -e` is active) aborts and the container exits before Angie
starts. Common sub-causes:

- A custom script mounted into `/docker-entrypoint.d/` has a bug or exits
  non-zero.
- A custom script is not marked executable (the entrypoint logs a warning and
  skips it, but this can mask a missing feature).
- The default image is started as a non-root user (see section 3b).

**Fix.** Inspect the logs:

```sh
docker logs <container>
```

The failing script and its exit code are printed:

```text
<timestamp> [error] 99-zz-fail.sh failed with exit 7, aborting startup
```

Check the script's exit code, shebang, and executable bit:

```sh
ls -la /path/to/script.sh
# must be -rwxr-xr-x
```

For a non-executable script, the warning is:

```text
<timestamp> [warn] ignoring /docker-entrypoint.d/myscript.sh, not executable
```

Apply `chmod +x` and restart.

---

## 10. `worker_processes` autotune has no effect (read-only filesystem)

**Symptom.** `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE=1` is set but
`worker_processes` in `angie.conf` remains `auto` rather than a concrete
number.

**Cause.** `30-tune-worker-processes.sh` rewrites `/etc/angie/angie.conf` in
place with `sed -i`. If the filesystem is mounted read-only (e.g., via
`--read-only` or a read-only bind-mount covering `/etc/angie`), the `touch`
probe at the start of the script detects the immutable filesystem, logs an
error, and exits 0 without modifying the file.

Angie continues to start normally with `worker_processes auto`, which lets the
master process determine the count at runtime. The autotune script provides a
cgroup-aware override (cpuset + CPU quota for both v1 and v2), which is more
accurate in CPU-limited containers than the Angie built-in `auto`.

**Fix.** Either remove the read-only constraint on `/etc/angie`, or accept
`worker_processes auto` and rely on Angie's own detection. For a persistent
writable container layer the tune is applied only once (the script detects its
own sentinel comment and skips on subsequent restarts).

See [configuration.md](configuration.md) for
`ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` and
[limitations.md](limitations.md) for filesystem constraints.

---

[Russian version](troubleshooting.ru.md) |
[Configuration](configuration.md) |
[Security](security.md) |
[Usage](usage.md) |
[Back to README](../README.md)
