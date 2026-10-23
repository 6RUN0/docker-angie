# Troubleshooting

Use the live prefix in every manual check:

```sh
docker exec angie angie -p /data/conf -c angie.conf -t
docker exec angie angie -p /data/conf -c angie.conf -T
```

A bare `angie -t` checks the packaged prefix, not necessarily the assembled
runtime tree.

## 1. Port already in use

Map a different host port. The internal port stays 80 for the standard image
and 8080 for the unprivileged image:

```sh
docker run -p 8081:80 6run0/angie:alpine
docker run -p 8081:8080 6run0/angie:alpine-unprivileged
```

## 2. Requests return 444

The built-in catch-all deliberately closes requests that do not match a custom
`server_name`. Add a server under `/etc/angie/custom/http.d`. `/healthz` is a
loopback-only health endpoint and returns 404 to non-loopback clients.

## 3. An `ANGIE_*` setting has no effect

### Container was restarted instead of recreated

Docker does not change a container's environment on `docker restart`. Recreate
it (`docker compose up -d --force-recreate`) after editing environment values.
A restart does re-run the entrypoint, but with the original values.

### Custom config overrides or duplicates the feature

Inspect the complete live tree with the `-T` command above. `add_header` in a
nested context replaces inherited headers. A manually declared `log_format`,
map, or listener can also conflict with an image-managed one.

## 4. `/data` is not writable

**Symptom:** startup reports that `/data` is not writable.

With a read-only root filesystem, mount the sole writable runtime path:

```sh
docker run --read-only --tmpfs /data:mode=1777 6run0/angie:alpine
```

For ACME use `-v angie-data:/data` instead. Mounting only `/data/conf` is not
supported.

## 4b. `CACHE_DIR` bind-mount

**Symptom:** the proxy cache fails with permission errors at runtime.

**Cause:** with `CACHE_DIR` set, `90-fix-cache-permission.sh` chowns the
directory contents to `angie` at startup, skipping symbolic links. It runs only
in the standard image as root; the unprivileged image skips it with a notice.

**Fix:** for the standard image, mount the directory writable:

```sh
docker run \
  -e CACHE_DIR=/var/cache/angie/proxy \
  -v /host/cache:/var/cache/angie/proxy \
  6run0/angie:alpine
```

For the unprivileged image, change the owner on the host before mounting:

```sh
chown -R 65532:65532 /host/cache
docker run --user 65532:65532 \
  -e CACHE_DIR=/var/cache/angie/proxy \
  -v /host/cache:/var/cache/angie/proxy \
  6run0/angie:alpine-unprivileged
```

A cache entry that is a symbolic link keeps its owner. htpasswd files get the
same fix only under `/etc/angie/custom`; on a read-only mount the entrypoint
only warns, so make them readable by `angie` on the host.

## 5. `/data/conf` belongs to another UID

The entrypoint refuses to rebuild a live tree created by a different UID. This
is intentional protection against overwriting another container's files. Run
with the original UID, use a fresh volume, or repair ownership from a separate
root container. Do not add `chown` privileges to the application container just
to bypass the check.

A non-empty `/data/conf` without the image ownership marker is likewise
rejected. Empty it only after confirming it contains no user data; user config
belongs in `/etc/angie/custom`.

## 6. Custom configuration is silently absent

Only these globs are loaded:

```text
/etc/angie/custom/conf.d/*.conf
/etc/angie/custom/http-conf.d/*.conf
/etc/angie/custom/http.d/*.conf
```

A file at the mount root is ignored. Directories must be traversable and files
readable by the runtime/worker UID. An unreadable glob can look empty without an
Angie error. Typical safe public-config modes are 0755 for directories and 0644
for files; use tighter ownership-aware modes for secrets.

## 7. Reload does not work

`angie -s reload` needs a pid file, while this image uses `pid off`. Validate the
live tree, then signal the container:

```sh
docker exec angie angie -p /data/conf -c angie.conf -t
docker kill -s HUP angie
```

This reloads changes from `/etc/angie/custom`. It does not change the
container's environment; recreate for environment changes.

## 8. GeoIP2 variables are empty

`GEOIP2_DB_COUNTRY` must name a mounted, readable regular file. The allowed path
characters are `A-Za-z0-9._/-`. GeoIP2 access-log variants are ignored unless
the database is active. Verify with the live `-T` command and search for
`geoip2`.

## 9. ModSecurity does not block requests

The image contains the engine, not a ruleset. Mount a ruleset and include it
from custom configuration. `ANGIE_MODSECURITY_ENABLED=yes` alone performs no
filtering.

## 10. Console Light fails at startup or returns 401

Check all of the following:

- `ANGIE_CONSOLE_PATH` is at least 16 allowed characters without `/`;
- `ANGIE_CONSOLE_HTPASSWD_FILE` is an absolute, non-empty, readable file;
- the standard image's `angie` workers, not only the root master, can read it;
- the request includes the secret path and valid basic-auth credentials.

`ANGIE_CONSOLE_HTPASSWD_FILE=none` removes authentication; do not use it on an
unprotected listener. Put TLS in front of the console.

## 11. ACME repeatedly orders certificates

`/data/acme` is not persistent, usually because `/data` is tmpfs or the
container was recreated without its volume. Attach a persistent volume and keep
it across upgrades. Test with a staging CA before switching to production.

For HTTP validation, publish host port 80 to the image public port. The
standard image defaults to 80; the unprivileged image defaults to 8080 and
rejects internal challenge ports below 1024.

## 12. ACME validation is reset or redirected

Use the same HTTP listener for the normal redirect and the ACME challenge. The
ACME handler runs before rewrite processing, so it can answer the token while
other requests redirect to HTTPS. A separate challenge port with no custom
server can reset non-challenge requests.

DNS and ALPN challenges need additional DNS/network configuration not prepared
by this image.

## 13. HSTS remains after the toggle is disabled

Browsers cache HSTS. Re-enable it with `ANGIE_HSTS_MAX_AGE=0`, serve that header
through working HTTPS long enough for clients to receive it, then disable the
toggle. Clearing the server header alone cannot clear client state.

## 14. Changed files remain stale or return 404

Disable `ANGIE_OPEN_FILE_CACHE_ENABLED` while diagnosing deployments. Cached
file descriptors and negative lookups can remain valid briefly. For versioned
asset names, include `snippets/cache-busting.conf` only when the corresponding
unversioned file exists.

## 15. Container exits with code 137 during stop

Docker sent SIGKILL after its grace period expired. Keep
`ANGIE_WORKER_SHUTDOWN_TIMEOUT` (default `8s`) below `stop_grace_period` and
allow enough time for active connections. Prefer SIGQUIT/default container stop
for graceful shutdown.

## 16. Entrypoint output is missing

Any non-empty `ANGIE_ENTRYPOINT_QUIET_LOGS` value suppresses all entrypoint
messages, including errors. Unset it while diagnosing. JSON is the default;
set `ANGIE_ERROR_LOG_JSON_ENABLED=no` for human-readable text.

## 17. Configuration assembly fails

The entrypoint fails closed if a setup script or the final live-tree check
fails. Read the first JSON record with `"level":"error"`, then reproduce it with the explicit
`-t` command at the top of this document. It is normal for the container to stop
rather than serve a partially applied configuration.

## 18. Container killed by OOM

**Symptom:** the container exits with status 137 and the kernel log shows the
OOM killer taking an Angie master or worker.

**Cause:** `angie.conf` sets `worker_rlimit_nofile 65536` and, in `events {}`,
`worker_connections 32768`. Each worker allocates its connection array at
start, so memory grows with the worker count, and `worker_processes auto`
counts CPUs from the affinity mask (`--cpuset-cpus`), not from the `--cpus`
quota. Under a tight `-m` the OOM killer can fire before any load arrives.

**Fix:** neither directive can be overridden from the custom volume. A second
declaration in `custom/conf.d` fails startup with
`"worker_rlimit_nofile" directive is duplicate`, one in `custom/http-conf.d`
with `"worker_connections" directive is not allowed here`. Two ways work.

Reduce the worker count. `--cpus` alone does not: measured on a 16-CPU host
(Docker 29.9.0, 1.12.4 Alpine image, 2026-10-23), `--cpus 2 -m 256m` started
16 workers. Either of these started 2:

```sh
docker run --cpus 2 -m 256m \
  -e ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE=1 6run0/angie:alpine
docker run --cpuset-cpus 0-1 -m 256m 6run0/angie:alpine
```

Or replace the whole `angie.conf` when other limits are needed:

```sh
docker run -m 256m -v /path/to/angie.conf:/etc/angie/angie.conf:ro \
  6run0/angie:alpine
```

The price of the second way: you own the include list. Your file must repeat
every `include` of the shipped one (`modules.d`, `conf.d`, `http-conf.d`,
`http.d` and their `/etc/angie/custom` pairs), otherwise the toggles and the
custom volume stop working; `conf.d` carries `user angie` of the standard image
and `pid off`. The `:ro` mount is no obstacle: the file is copied to
`/data/conf` and the scripts edit the copy. Keep three lines in their shipped
form if their variables are needed: `30-tune-worker-processes.sh` looks for
`worker_processes`, `31-error-log-json.sh` for `error_log /dev/stderr;` or
`error_log /dev/stderr format=json;`, `32-worker-shutdown-timeout.sh` for
`worker_shutdown_timeout <number>[ms|s|m];`. A line written otherwise is not
rewritten: the last two scripts warn and continue, the first stays silent.

## 19. `exec format error` or no matching manifest

**Symptom:** the container exits immediately with a message ending in
`exec format error`, or `docker pull` reports no matching manifest for the
host platform.

**Cause:** the host architecture is not in the image manifest. Published
images are `linux/amd64` and `linux/arm64` only, see
[limitations.md](limitations.md#10-supported-platforms).

**Fix:** on another architecture, build the image locally
(`docker build -t angie-alpine -f alpine/Dockerfile .`), or run the published
one under emulation when the host has a `binfmt_misc` handler for it
(`docker run --platform linux/amd64 6run0/angie:alpine`).

## 20. `angie -t` or `angie -T` shows the wrong configuration

**Symptom:** inside the container `angie -T` lacks the snippets the toggles
enabled, `angie -t` passes on a configuration known to be broken, or an
`angie-ctl` change does not show up.

**Cause:** the compiled-in prefix is `/etc/angie` (see `angie -V`), the
read-only skeleton. The served tree is `/data/conf`, selected by `-p` and `-c`
in `CMD`. A bare `angie -t` or `angie -T` reads the skeleton, a configuration
nobody runs.

**Fix:** use the wrapper that adds the live prefix, or the explicit form:

```sh
docker exec <container> angie-runtime -t
docker exec <container> angie-runtime -T
docker exec <container> angie -p /data/conf -c angie.conf -T
```

The exact command is in the image metadata:
`docker inspect -f '{{json .Config.Cmd}}' 6run0/angie:alpine`. `angie-ctl`
needs no flags: the image sets `ANGIE_ETC=/data/conf` and
`ANGIE_BIN=/usr/local/bin/angie-runtime`.

## 21. Proxying to `https` fails certificate verification

**Symptom:** `proxy_pass https://...` returns `502`, and the error log has

```text
upstream SSL certificate verify error: (20:unable to get local issuer certificate)
```

although `curl` from the host reaches the same address, and the image has a
CA store at `/etc/ssl/certs/ca-certificates.crt` (118 roots in the Alpine and
148 in the Debian 1.12.4 image, counted 2026-10-23).

**Cause:** usually the chain depth, not the store. `proxy_ssl_verify_depth`
defaults to 1, and public chains are usually longer. Measured 2026-10-23 on
the 1.12.4 Alpine image against `https://letsencrypt.org/` (4 certificates in
the served chain): the default depth gave `502` with the error above, depth 2
gave `200`.

**Fix:** allow the real chain length:

```nginx
location / {
  proxy_pass https://upstream.example;
  proxy_ssl_verify on;
  proxy_ssl_verify_depth 3;
  proxy_ssl_name upstream.example;
  proxy_ssl_server_name on;
  proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
}
```

Count the chain of a given upstream from outside:

```sh
echo | openssl s_client -connect upstream.example:443 \
  -servername upstream.example -showcerts 2>/dev/null | grep -c 'BEGIN CERT'
```

`proxy_ssl_trusted_certificate` is mandatory: the system store is not picked
up by itself, and startup fails with
`[emerg] no proxy_ssl_trusted_certificate for proxy_ssl_verify`.

## 22. `SSL alert number 80` with ACME enabled

**Symptom:** the container runs, the TLS listener is up, the startup
`angie -t` passed, but every handshake fails. The client reports

```text
SSL routines:ssl3_read_bytes:tlsv1 alert internal error
SSL alert number 80
```

`curl` shows it as `error:0A000438`, a browser as `ERR_SSL_PROTOCOL_ERROR`.

**Cause:** no certificate has been issued yet, and `$acme_cert_<name>` is
empty. The empty variable is valid for `angie -t`, so startup does not catch
it. The window between the first start and the first issuance always exists;
while it is open, the redirect from HTTP leads to a TLS listener that answers
nothing.

**Fix:** look at what the client got from the CA:

```sh
docker logs <container> 2>&1 | grep '"acme_client"'
docker exec <container> ls -l /data/acme/le/
```

Replace `le` with `ANGIE_ACME_CLIENT`. A non-empty `certificate.pem` means the
cause is elsewhere; until the first issuance the file exists with size 0.
Common log lines:

- `request to ACME server failed`: the CA directory is unreachable. Check
  `ANGIE_ACME_DIRECTORY` and outbound access from the container;
- `no resolver configured`: your configuration has `resolver off;`. The
  default `conf` works for ACME, `off` disables it, see
  [configuration.md](configuration.md#dns-name-resolution);
- a failed challenge: the CA could not fetch `/.well-known/acme-challenge/...`.
  Check that host port 80 is published to `ANGIE_ACME_HTTP_PORT` (`-p 80:80`
  standard, `-p 80:8080` unprivileged) and that the domain points to this host.

## 23. `ACME module will use port 80 for HTTP challenges, superuser required`

**Symptom:** this warning appears in the unprivileged image. Under a runtime
where uid 65532 cannot bind ports below 1024 (Kubernetes, plain runc) startup
then fails on `bind()`.

**Cause:** the warning names the wrong fix. `acme_http_port` defaults to 80,
nobody listens there in the unprivileged image, so the module opens a listener
of its own. The message appears only with your own `acme_client` in
`custom/http-conf.d` without `ANGIE_ACME_ENABLED`: the toggle sets
`acme_http_port` to the public port itself and refuses values below 1024 in
the unprivileged image. The standard image has a root master and listens on 80,
so it does not show the warning.

**Fix:** enable `ANGIE_ACME_ENABLED`, or add `acme_http_port 8080;` to your
snippet, matching an existing listener. The module then opens no listener and
the challenge is served by the existing `server {}`: the handler runs in the
`post_read` phase, before `rewrite`, so even a server doing only `return 301`
to HTTPS answers the token. Without the toggle, also set
`acme_client_path /data/acme;`: the default state path is not writable for a
non-root master and fails startup with
`mkdir() "/var/lib/angie/acme/<name>" failed (13: Permission denied)`.

Do not move the challenge to a dedicated port: the module's own listener drops
every request that is not a live token, the HTTP-to-HTTPS redirect included.

## 24. Application behind the proxy lost its `Cache-Control`

**Symptom:** the backend sends `Cache-Control: max-age=60, public`, the client
receives `no-cache` or a one-year lifetime instead. The status is `200`, the
logs show nothing.

**Cause:** an `expires` directive reached the proxying `location`, for example
`snippets/expires-by-type.conf` included at `server` level. `expires` does not
add to the upstream headers, it replaces `Cache-Control` and `Expires`: a
`text/html` response gets `epoch` from the type map, which is `no-cache`.

**Fix:** include `snippets/expires-by-type.conf` only in the `location` that
serves static files, never in one with `proxy_pass`:

```nginx
location /static/ {
  include snippets/expires-by-type.conf;
}

location /api/ {
  proxy_pass http://backend:8000;
}
```

`expires off;` inside a `location` cancels an inherited directive locally.

## 25. Security headers vanish in my `location`

**Symptom:** `ANGIE_SECURITY_HEADERS_ENABLED` is on, some paths carry the
headers and others do not. `angie -T` shows every `add_header` in place.

**Cause:** `add_header` sets do not merge across levels. A `server` or
`location` with any `add_header` of its own, even for an unrelated header,
replaces the inherited set. Measured on the 1.12.4 Alpine image (2026-10-23):
a `location` with only `add_header Cache-Control "nested-only";` returned

```text
HTTP/1.1 200 OK
Content-Type: application/octet-stream
Cache-Control: nested-only
```

while a sibling `location` without its own `add_header` returned
`X-Content-Type-Options: nosniff`. The `always` flag is unrelated: it is about
status codes, not inheritance. `expires` is not `add_header`, so
`snippets/expires-by-type.conf` does not trigger the replacement.

**Fix:** repeat the needed headers in the block where you declare your own;
`add_header` has no "append to inherited" mode.

Do not confuse this with selection by content type: `Referrer-Policy`,
`X-Frame-Options` and `Permissions-Policy` go only to documents, stylesheets and
similar types, see `055-security-headers.conf`. The tell: when the set is
replaced, `X-Content-Type-Options` disappears too, and it is sent with every
response type.

## 26. `IPv6 is unavailable` in the startup log

**Symptom:** a `notice` line:

```text
IPv6 is unavailable; the built-in listener serves 0.0.0.0:80 only
```

with `8080` in the unprivileged image.

**Cause:** the kernel has no IPv6 (built without it or booted with
`ipv6.disable=1`; the sign is a missing `/proc/net/if_inet6`). The entrypoint
removes the built-in `listen [::]:<port>` line from the live copy, otherwise
startup would fail with `(97: Address family not supported by protocol)`. This
is not an error. `sysctl net.ipv6.conf.all.disable_ipv6=1` does not lead here:
the IPv6 socket can still be created and the line stays.

**What remains yours:** `listen [::]` lines in the custom volume are not
touched and fail startup on such a kernel with the same error `97`. Keep files
without IPv6 listeners for such a host.

---

[Configuration](configuration.md) | [Usage](usage.md)

Russian: [troubleshooting.ru.md](troubleshooting.ru.md).
