# Configuration Reference

Runtime environment variables, mounts, ports, snippets, and build arguments for
`6run0/angie`. See also [usage.md](usage.md) and [security.md](security.md).

## Environment variables

Boolean toggles accept `yes`, `on`, `1`, `true`, `enable`, and `enabled`.
Anything else disables the feature. Two variables are presence switches:
`ANGIE_ENTRYPOINT_QUIET_LOGS` and
`ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` are enabled by any non-empty value,
including `no` and `0`.

The entrypoint applies settings to a fresh copy of the immutable `/etc/angie`
skeleton under `/data/conf`. Consequently all toggles work in both image
variants, under an arbitrary UID in the unprivileged image, and with a read-only
root filesystem, provided `/data` is writable.

### General

| Variable | Default | Description |
|---|---|---|
| `ANGIE_ENTRYPOINT_QUIET_LOGS` | unset | Suppress all entrypoint messages, including errors; failures remain visible through the exit code. Any non-empty value enables it. |
| `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE` | unset | Set `worker_processes` from cgroup v1/v2 quota and cpuset at every start. Any non-empty value enables it. |
| `ANGIE_ERROR_LOG_JSON_ENABLED` | `yes` | Use Angie's JSON error log and JSON entrypoint records. Set to a non-truthy value for text logs. |
| `ANGIE_WORKER_SHUTDOWN_TIMEOUT` | `8s` | Graceful worker shutdown limit. Accepts a positive number with optional `ms`, `s`, or `m`; keep it below the container stop grace period. |
| `CACHE_DIR` | unset | Standard image only: an existing directory whose entries not owned by `angie` are chowned to `angie` at startup; symbolic links are skipped. No-op in the unprivileged image. |

### Error log format

`ANGIE_ERROR_LOG_JSON_ENABLED` switches two things at once: the `error_log`
line in the main context of the live `angie.conf`, and the format of the
entrypoint's own lines on stderr. The JSON field set of Angie's error log is
fixed by Angie and, unlike the access-log formats, has no template in the
image. The toggle rewrites only the two shipped lines,
`error_log /dev/stderr;` and `error_log /dev/stderr format=json;`. Any other
`error_log` line in a replaced `angie.conf` is left alone with the warning
`31-error-log-json.sh: neither known error_log state found in
/data/conf/angie.conf (customized config?); leaving error_log as is`.

With the default `yes`, each entrypoint line is one JSON object with Angie's
keys in Angie's order:

```json
{"time":"2026-10-23T10:50:42Z","level":"info","pid":64,"message":"ACME client 'le' configured: https://acme.invalid/directory, challenge=http, state /data/acme","tags":["entrypoint"]}
```

Differences from Angie's own records: `time` has whole seconds (busybox `date`
has no fractions), there is no `tid` or `connection`, and `tags` is always
`["entrypoint"]`, which is how a collector separates the two sources. Levels
are Angie's: `error`, `warn`, `notice`, `info`. Quotes, backslashes and control
characters in `message` are escaped, so a value from the environment cannot
break the line; search for a quoted substring in its escaped form (`\"`). A
failed final `angie -t` is reported as one `error` record with its lines joined
by `\n` inside `message`.

Three kinds of stderr lines stay plain text even with `yes`, so a collector
needs a fallback for unparsed lines:

- Angie messages printed while parsing the configuration, before
  `error_log ... format=json` takes effect, for example
  `[notice] 7#7: creating implicit client block for "@acme"`;
- output of shell utilities inside `/docker-entrypoint.d/` scripts, such as a
  failing `cp` or `sed` under `set -e`;
- `angie-ctl` refusals.

With `no`, entrypoint lines use the text format described in
[usage.md](usage.md#entrypoint-logs).

### Compression and file delivery

| Variable | Default | Description |
|---|---|---|
| `ANGIE_BROTLI_ENABLED` | `no` | Load Brotli and enable on-the-fly compression. |
| `ANGIE_BROTLI_STATIC_ENABLED` | `no` | Serve pre-compressed `*.br`; implies the base Brotli toggle. |
| `ANGIE_GZIP_ENABLED` | `no` | Enable on-the-fly gzip. |
| `ANGIE_GZIP_STATIC_ENABLED` | `no` | Serve pre-compressed `*.gz`; implies the base gzip toggle. |
| `ANGIE_ZSTD_ENABLED` | `no` | Load Zstandard and enable on-the-fly compression. |
| `ANGIE_ZSTD_STATIC_ENABLED` | `no` | Serve pre-compressed `*.zst`; implies the base Zstandard toggle. |
| `ANGIE_CHARSET_UTF8_ENABLED` | `no` | Add UTF-8 to supported textual content types. |
| `ANGIE_EXPIRES_ENABLED` | `no` | Define the content-type cache map used by `snippets/expires-by-type.conf`; does not add `expires` by itself. |
| `ANGIE_OPEN_FILE_CACHE_ENABLED` | `no` | Cache open file descriptors and metadata. File changes may remain invisible for up to the configured validity interval. |

Only gzip adds `Vary: Accept-Encoding`. Add that header yourself when using
Brotli or Zstandard without gzip behind a shared cache.

### Modules and GeoIP2

| Variable | Default | Description |
|---|---|---|
| `ANGIE_MODSECURITY_ENABLED` | `no` | Load the ModSecurity engine. No ruleset is bundled. |
| `ANGIE_SUBS_ENABLED` | `no` | Load the response-body substitutions filter. |
| `GEOIP2_DB_COUNTRY` | unset | Readable absolute path to a MaxMind country database. Setting it enables GeoIP2. Allowed characters: `A-Za-z0-9._/-`. |

### Access logs

Access logs use JSON by default. `ANGIE_LOG_FORMAT_*` registers a named format
without selecting it. `ANGIE_LOG_*` registers and selects one format, disabling
other image-managed access logs. Image format names have an `angie_` prefix so
custom configuration can use conventional names such as `main`.

| Variable | Default | Description |
|---|---|---|
| `ANGIE_LOG_FORMAT_EXTENDED` / `ANGIE_LOG_EXTENDED` | `no` | Register / select the extended format. |
| `ANGIE_LOG_FORMAT_JSON` / `ANGIE_LOG_JSON` | `no` | Register / select structured JSON; selected anyway when no `ANGIE_LOG_*` is set. |
| `ANGIE_LOG_FORMAT_LOGFMT` / `ANGIE_LOG_LOGFMT` | `no` | Register / select logfmt. |
| `ANGIE_LOG_FORMAT_MAIN` / `ANGIE_LOG_MAIN` | `no` | Register / select the classic combined-style format. |
| `ANGIE_LOG_FORMAT_MATOMO` / `ANGIE_LOG_MATOMO` | `no` | Register / select the Matomo format. |
| `ANGIE_LOG_FORMAT_JSON_GEOIP2` / `ANGIE_LOG_JSON_GEOIP2` | `no` | Register / select JSON with a country field; requires GeoIP2. |
| `ANGIE_LOG_FORMAT_LOGFMT_GEOIP2` / `ANGIE_LOG_LOGFMT_GEOIP2` | `no` | Register / select logfmt with a country field; requires GeoIP2. |

### Proxying and response headers

| Variable | Default | Description |
|---|---|---|
| `ANGIE_MAP_WEBSOCKET_ENABLED` | `no` | Define the WebSocket upgrade map. |
| `ANGIE_REAL_IP_FROM` | unset | Space- or comma-separated trusted proxy addresses/CIDRs; setting it enables real-IP handling. |
| `ANGIE_REAL_IP_HEADER` | `X-Forwarded-For` | Header, or `proxy_protocol`, from which to read the client address. |
| `ANGIE_REAL_IP_RECURSIVE` | `on` | Walk the forwarding chain when `on`; must be `on` or `off`. |
| `ANGIE_SECURITY_HEADERS_ENABLED` | `no` | Add `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options`, and `Permissions-Policy`. |
| `ANGIE_HSTS_ENABLED` | `no` | Add HSTS only to HTTPS responses. Read [security.md](security.md#hsts) before enabling it. |
| `ANGIE_HSTS_MAX_AGE` | `16070400` | HSTS lifetime in seconds. Zero instructs clients to forget HSTS. |
| `ANGIE_HSTS_INCLUDE_SUBDOMAINS` | `no` | Add `includeSubDomains`; enable only when every subdomain supports HTTPS. |
| `ANGIE_CORS_ASSETS_ENABLED` | `no` | Add `Access-Control-Allow-Origin: *` to font and image responses, not documents or APIs. |

Trust only known proxy CIDRs. Broad ranges let clients forge `$remote_addr`.
Also note that `add_header` does not merge across contexts: a custom
`server`/`location` with its own `add_header` replaces inherited headers.

### Status API and Console Light

| Variable | Default | Description |
|---|---|---|
| `ANGIE_STATUS_API_ENABLED` | `no` | Serve read-only JSON `/status/` and Prometheus `/metrics` on a dedicated listener. |
| `ANGIE_STATUS_API_HOST` | `0.0.0.0` | Status listener address. |
| `ANGIE_STATUS_API_PORT` | `8181` | Status listener port, `1-65535`; it must differ from the public port. |
| `ANGIE_CONSOLE_ENABLED` | `no` | Serve Console Light through the built-in catch-all server. |
| `ANGIE_CONSOLE_PATH` | unset | Required secret URL segment, at least 16 characters, without slashes. Generate one with `openssl rand -hex 16`. |
| `ANGIE_CONSOLE_HTPASSWD_FILE` | `/etc/angie/custom/console.htpasswd` | Non-empty readable htpasswd file. `none` disables basic auth and is unsafe on an exposed listener. |

Console Light is served at `http://host:<public-port>/<path>/`. Put TLS in
front of it. The standard image uses port 80 and the unprivileged image uses
8080. Root workers must be able to read the htpasswd file.

### ACME

| Variable | Default | Description |
|---|---|---|
| `ANGIE_ACME_ENABLED` | `no` | Configure Angie's built-in ACME client and state directory `/data/acme`. |
| `ANGIE_ACME_CLIENT` | `le` | Client name used in `$acme_cert_<name>` variables. |
| `ANGIE_ACME_DIRECTORY` | unset | CA directory URL. If unset, declare `acme_client` yourself in `custom/http-conf.d`. |
| `ANGIE_ACME_EMAIL` | unset | Optional account email. |
| `ANGIE_ACME_CHALLENGE` | `http` | `http`, `dns`, or `alpn`. Only the HTTP flow is prepared by the image. |
| `ANGIE_ACME_HTTP_PORT` | image public port | HTTP challenge port: 80 in the standard image, 8080 in the unprivileged image. The unprivileged variant rejects ports below 1024. |

A certificate is requested only after a custom `server` refers to the client:

```nginx
server {
  listen 80;
  server_name site.example;
  acme le;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl;
  server_name site.example;
  ssl_certificate     $acme_cert_le;
  ssl_certificate_key $acme_cert_key_le;
}
```

For the unprivileged image use internal ports 8080/8443 and publish them as
80/443. Test with a staging CA first. ACME state contains account keys and
certificates, so mount a persistent volume at `/data`; tmpfs would request new
certificates after every recreation and can exhaust CA rate limits.

## Variable dependencies

- `ANGIE_BROTLI_STATIC_ENABLED`, `ANGIE_GZIP_STATIC_ENABLED` and
  `ANGIE_ZSTD_STATIC_ENABLED` enable their base toggle first; setting only the
  static variable is enough.
- `ANGIE_REAL_IP_HEADER` and `ANGIE_REAL_IP_RECURSIVE` are read only when
  `ANGIE_REAL_IP_FROM` is set; otherwise they are neither applied nor
  validated.
- `ANGIE_LOG_FORMAT_*` only registers a format. `ANGIE_LOG_*` registers and
  selects one; with several set, the first in the order `EXTENDED`, `JSON`,
  `LOGFMT`, `MAIN`, `MATOMO` wins, and with none set JSON is selected.
- The four `*_GEOIP2` log variables are handled by `50-geoip2.sh`, after
  `40-log.sh`, so `ANGIE_LOG_JSON_GEOIP2` or `ANGIE_LOG_LOGFMT_GEOIP2`
  overrides the selection above; with both set, logfmt wins. They are ignored
  while GeoIP2 is not active: silently when `GEOIP2_DB_COUNTRY` is unset, with
  the warning `GeoIP database '<path>' not found` when the file is unreadable.
  Startup continues in both cases.
- Selecting a log with `ANGIE_LOG_*` first disables every other image-managed
  `access_log`, so exactly one is active.
- `ANGIE_STATUS_API_HOST`/`_PORT`, `ANGIE_HSTS_MAX_AGE`/`_INCLUDE_SUBDOMAINS`,
  `ANGIE_CONSOLE_PATH`/`_HTPASSWD_FILE` and all `ANGIE_ACME_*` are read only
  when their `_ENABLED` toggle is on. An invalid value does not fail startup
  while the toggle is off.
- `ANGIE_ACME_CLIENT`, `ANGIE_ACME_CHALLENGE` and `ANGIE_ACME_EMAIL` end up in
  the `acme_client` directive, which the image declares only when
  `ANGIE_ACME_DIRECTORY` is set. Without it they are silently unused: the
  snippet is enabled with its state path and challenge port, but no client.
  An invalid `ANGIE_ACME_CLIENT` or `ANGIE_ACME_CHALLENGE` fails startup even
  without `ANGIE_ACME_DIRECTORY`; `ANGIE_ACME_EMAIL` is validated only with it.

## Volumes and live layout

### `/etc/angie/custom`

Mount user configuration read-only. Exactly three subdirectories are included:

- `custom/conf.d/*.conf` in the main context;
- `custom/http-conf.d/*.conf` in the `http` context;
- `custom/http.d/*.conf` for virtual hosts.

Files in the root of the mount are ignored. Directories need execute permission
and files need read permission for the runtime UID. An unreadable glob can look
like an empty directory without producing an Angie error.

### `/data`

`/data` is the sole writable runtime location:

- `/data/conf` is rebuilt from `/etc/angie` on every start;
- `/data/tmp` contains pidless runtime temporary files;
- `/data/acme` stores persistent ACME state when enabled.

Do not mount `/data/conf` directly. The entrypoint refuses to overwrite a
non-empty tree it did not create, and refuses a tree owned by another UID. When
changing the unprivileged runtime UID, use a new volume or change ownership from
outside the application container.

```sh
# Stateless/read-only deployment

docker run --read-only --tmpfs /data:mode=1777 6run0/angie:alpine

# Persistent state, required for ACME

docker run --read-only -v angie-data:/data 6run0/angie:alpine
```

No `VOLUME` instruction is declared, so Docker does not create anonymous volumes.

### `CACHE_DIR` (bind-mounted cache)

When using Angie as a caching proxy, mount a host directory for the cache and
pass its path via `CACHE_DIR` so the entrypoint fixes ownership:

```sh
docker run -v /host/cache:/var/cache/angie/proxy \
  -e CACHE_DIR=/var/cache/angie/proxy \
  6run0/angie:alpine
```

The fix runs only in the standard image, whose root master hands work to the
`angie` worker user. It recurses into the directory but never follows or
changes symbolic links: a link planted in the mount would otherwise hand its
root-owned target to the worker. In the unprivileged image the master and the
workers share one UID, so the host path must already belong to it, see
[troubleshooting.md](troubleshooting.md#4b-cache_dir-bind-mount).

Workers also read `auth_basic_user_file` at request time, so the standard image
chowns regular files matching `*htpasswd*` under `/etc/angie/custom` to `angie`;
other paths are not touched. On a read-only mount the chown fails and the
entrypoint only warns: make those files readable by the `angie` user on the
host.

## Reusable snippets

Include these from custom `server` or `location` blocks:

| File | Context | Purpose |
|---|---|---|
| `snippets/healthz.conf` | `server` | Loopback-only `/healthz`. |
| `snippets/proxy-headers.conf` | `location` | Common proxy headers and HTTP/1.1. |
| `snippets/status-api-locations.conf` | `server` | `/status/` and `/metrics`; also include the Prometheus template in `http` when the toggle is off. |
| `snippets/deny-dotfiles.conf` | `server` | Return 404 for dot paths except `/.well-known/`. |
| `snippets/robots-disallow-all.conf` | `server` | Serve a disallow-all `robots.txt`; this is advisory, not access control. |
| `snippets/expires-by-type.conf` | `server` or `location` | Apply the map enabled by `ANGIE_EXPIRES_ENABLED`. |
| `snippets/cache-busting.conf` | `server` | Map versioned asset names to an unversioned file. |
| `snippets/console.conf` | `server` | Rendered automatically when Console Light is enabled. |

Relative includes resolve from Angie's prefix (`/data/conf`), so the same paths
work from built-in and custom files.

## Behind a load balancer or TLS terminator

In this setup TLS ends in front of the container, and the image receives plain
HTTP on its public port (80 standard, 8080 unprivileged). Three things need
their own configuration.

Client address. Without real-IP handling `$remote_addr` and the access log hold
the proxy's address. Set `ANGIE_REAL_IP_FROM` to the proxy subnet, see
[Proxying and response headers](#proxying-and-response-headers).

Scheme seen by the application. `snippets/proxy-headers.conf` sends
`X-Forwarded-Proto $scheme`, and behind a terminator `$scheme` is always
`http`, so the application builds `http://` links and redirects. Take the
scheme from the terminator with a map and write the whole header set yourself
instead of including `proxy-headers.conf`: a second
`proxy_set_header X-Forwarded-Proto` on the same level does not replace the
first, both values are joined into one header.

```nginx
# /etc/angie/custom/http-conf.d/100-forwarded-proto.conf
map $http_x_forwarded_proto $forwarded_proto {
  default $scheme;
  https   https;
}
```

```nginx
# inside your location
proxy_http_version 1.1;
proxy_set_header Host $http_host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto $forwarded_proto;
proxy_set_header X-Request-ID $request_id;
proxy_pass http://app:3000;
```

The map trusts the header from any client that reaches the public port without
passing the terminator: do not publish that port around it.

HSTS and redirects. `ANGIE_HSTS_ENABLED` sends its header only when `$scheme`
is `https`, so behind a terminator it sends nothing; HSTS belongs to the
terminator. Redirects Angie builds itself (the trailing slash of a directory)
are absolute by default, with the listener's scheme and port: `http://<host>/...`
in the standard image, `http://<host>:8080/...` in the unprivileged one.
`absolute_redirect off;` in your `server {}` makes them relative.

## Variables declared by the image

The names below belong to the shipped tree. A variable of the same name
declared in `/etc/angie/custom` replaces the image's one without an error:
`angie -t` passes and the custom declaration wins. For example,
`map $host $_stock_loopback { default 1; }` in `custom/http-conf.d` makes
`/healthz` answer `ok` to remote clients instead of `404` (measured on the
1.12.4 image, 2026-10-23).

| Variable | Declared in | Present when |
|---|---|---|
| `$_stock_loopback` | `http-conf.d/010-common.conf` | always |
| `$_stock_time_ms` | `http-conf.d/010-common.conf` | always |
| `$_stock_connection_upgrade` | `060-map-websocket.conf` | `ANGIE_MAP_WEBSOCKET_ENABLED` |
| `$_stock_geoip2_country_code` | `025-geoip2.conf` | GeoIP2 is active |
| `$_stock_expires` | `023-expires.conf` | `ANGIE_EXPIRES_ENABLED` |
| `$_stock_cors_assets` | `057-cors-assets.conf` | `ANGIE_CORS_ASSETS_ENABLED` |
| `$_stock_x_frame_options` | `055-security-headers.conf` | `ANGIE_SECURITY_HEADERS_ENABLED` |
| `$_stock_referrer_policy` | `055-security-headers.conf` | `ANGIE_SECURITY_HEADERS_ENABLED` |
| `$_stock_permissions_policy` | `055-security-headers.conf` | `ANGIE_SECURITY_HEADERS_ENABLED` |
| `$_stock_hsts` | `056-hsts.conf` | `ANGIE_HSTS_ENABLED` |

Do not give your own variables the `$_stock_` prefix: a later image version may
take the name, and then your declaration silently replaces the image's.

## Ports

| Variant | Public HTTP | Default user |
|---|---:|---|
| Standard Alpine/Debian | 80 | root master, `angie` workers |
| Unprivileged Alpine/Debian | 8080 | uid/gid 65532; arbitrary UID supported |

The optional status listener defaults to 8181 and is not exposed automatically.

No TLS listener is configured, and no TLS port is in `EXPOSE`: the certificate
and host name come from the consumer. Declare `listen 443 ssl` (standard) or
`listen 8443 ssl` (unprivileged, published with `-p 443:8443`) in
`custom/http.d`. Whether a non-root master can bind a port below 1024 depends
on the runtime: Docker 20.10 and later set
`net.ipv4.ip_unprivileged_port_start=0`, Kubernetes and plain runc do not. A
`listen 443` in the unprivileged image is therefore not portable, and
`ANGIE_ACME_HTTP_PORT` below 1024 is refused there as image policy.

The built-in catch-all listens on `0.0.0.0` and `[::]` of the public port. On a
kernel without IPv6 (no `/proc/net/if_inet6`) the entrypoint removes the `[::]`
line from the live copy and logs the notice
`IPv6 is unavailable; the built-in listener serves 0.0.0.0:<port> only`. Your
own `listen [::]` lines are not touched and fail startup on such a kernel, see
[troubleshooting.md](troubleshooting.md#26-ipv6-is-unavailable-in-the-startup-log).

The catch-all is the default server of the public port by declaration order,
without a `default_server` flag, so `listen 80 default_server` (or
`8080 default_server`) in `custom/http.d` is accepted. Three consequences:

- taking the default also takes `/healthz` requests that do not carry the
  name `healthz-catchall.invalid`. The image `HEALTHCHECK` sends that name and
  keeps reaching the built-in endpoint; your own probe without it reaches your
  server;
- put the flag on both `listen` lines: the default is chosen separately for
  `0.0.0.0` and `[::]`, and one line leaves IPv6 clients with the image's
  `444`;
- without the flag a custom `server {}` never becomes the default, from
  `custom/http.d` or `custom/http-conf.d`: both are included after the
  built-in vhost.

## DNS name resolution

Since Angie 1.12.0 the `resolver` directive defaults to `conf` in the `http`
and `stream` modules (Angie documentation): Angie takes DNS servers from
`/etc/resolv.conf`, inside a container the Docker embedded DNS, and rereads the
file when it changes. Dynamic resolution (`proxy_pass` with variables,
`server ... resolve` in upstreams) works without a `resolver` line in your
vhosts.

`resolver off;` in custom configuration disables it, and with it the built-in
ACME client, which resolves the CA directory host at run time, see
[troubleshooting.md](troubleshooting.md#22-ssl-alert-number-80-with-acme-enabled).
A `resolver` line of your own in `custom/http-conf.d` is accepted with ACME
enabled: the ACME snippet declares none.

## Build arguments and vendored helper

Pass these to `docker build` with `--build-arg`; full build commands are in
[usage.md](usage.md#building-from-source). The release workflow passes only
`ANGIE_VERSION`, `IMAGE_VERSION` and `VCS_REF`, the same to both targets;
everything else keeps the Dockerfile default.

### Angie version and image metadata (`alpine/Dockerfile`, `debian/Dockerfile`)

| Argument | Default | Description |
|---|---|---|
| `ANGIE_VERSION` | `1.12.4` | Angie core and module version, pinned with apk `=~` (Alpine) or resolved to one exact package version with `apt-cache madison` (Debian). Release tags must match it. |
| `ANGIE_CONSOLE_VERSION` | `1.9.0` | Console Light package version; it has its own release cycle. |
| `IMAGE_VERSION` | `dev` | Value of the `org.opencontainers.image.version` label, the image tag without the variant suffix. |
| `VCS_REF` | empty | Source commit in the `org.opencontainers.image.revision` label. |

The image carries the labels `org.opencontainers.image.title`, `description`,
`source`, `url`, `documentation`, `licenses`, `version`, `revision` and
`base.name` (the distro base image argument, in both targets), plus
`software.angie.version`; `title` and `description` name the target.
`IMAGE_VERSION` and `VCS_REF` are declared right before the last `LABEL` of
each target, so changing them does not invalidate the shared `runtime` stage. Read them with
`docker inspect --format '{{json .Config.Labels}}' <image>`.

### Package sources (`alpine/Dockerfile`, `debian/Dockerfile`)

| Argument | Default | Description |
|---|---|---|
| `ANGIE_MIRROR` | `https://download.angie.software/angie` | Angie package mirror; `/alpine/v<branch>/main` or `/debian/<version>` is appended. Only Angie packages are taken from it: on Alpine the repository carries the `@angie` tag, on Debian `/etc/apt/preferences.d/angie` gives other packages from its host priority `-1` (matched by host without a numeric port; a pin that does not hold fails the build with `apt pin 'origin <host>' does not hold the Angie repository at priority -1`). |
| `ANGIE_SIGNING_KEY_URL` | key on `angie.software` | Where the package signing key is downloaded from. |
| `ANGIE_SIGNING_KEY` | keyring path of the distribution | Where the key is stored. |
| `ANGIE_SIGNING_KEY_SHA256` | digest of the default key, per Dockerfile | Expected sha256 of the downloaded key. A mismatch fails the build with `signing key sha256 mismatch for <url>` before the key is trusted. Recompute after a vendor key rotation with `curl -fsSL "$ANGIE_SIGNING_KEY_URL" \| sha256sum`; change it together with `ANGIE_SIGNING_KEY_URL`. |

### Alpine only (`alpine/Dockerfile`)

| Argument | Default | Description |
|---|---|---|
| `ALPINE_BASE_IMAGE` | `alpine:3.24` pinned by digest | Base image. |
| `ALPINE_MIRROR` | `https://dl-cdn.alpinelinux.org/alpine` | Alpine package mirror. `/etc/apk/repositories` is written from scratch: `main` and `community` of the base branch on this mirror plus the `ANGIE_MIRROR` repository. An unreachable URL fails the first `apk`. |

### Debian only (`debian/Dockerfile`)

| Argument | Default | Description |
|---|---|---|
| `DEBIAN_BASE_IMAGE` | `debian:trixie-slim` pinned by digest | Base image. |
| `DEBIAN_MIRROR` | `http://deb.debian.org/debian` | APT mirror for the release and `-updates` suites. `/etc/apt/sources.list.d/debian.sources` is written from scratch and a legacy `sources.list` is removed. An unreachable URL fails the first `apt-get update`. |
| `DEBIAN_SECURITY_MIRROR` | `http://deb.debian.org/debian-security` | APT mirror for the `-security` suite, written to the same file. |
| `ANGIE_SOURCE_LIST` | `/etc/apt/sources.list.d/angie.sources` | Where the APT source of the Angie repository is written. |

The Debian mirrors default to `http` on purpose: `debian:trixie-slim` ships no
`ca-certificates`, and the first `apt-get update` runs before they are
installed, so an `https` mirror fails there with `certificate verify failed`.
APT integrity rests on the repository GPG signatures, not the transport. The
Angie mirror host must differ from the `DEBIAN_MIRROR` and
`DEBIAN_SECURITY_MIRROR` hosts: the priority `-1` pin would hide Debian
packages too, and the build would fail on their installation. Alpine has no
such constraint: its base ships `ca-certificates-bundle`, hence the `https`
default.

### Unprivileged target (`--target unprivileged`)

| Argument | Default | Description |
|---|---|---|
| `APP_USER` | `app` | Name of the dedicated OS user. |
| `APP_GROUP` | `app` | Name of its group. |
| `APP_UID` | `65532` | uid of the default runtime identity (`USER` is numeric). |
| `APP_GID` | `65532` | gid of the default runtime identity. |

`angie-ctl` is vendored at `rootfs/usr/local/bin/angie-ctl`, not cloned during
the build. The current reviewed source revision is
`a69c1d102ec99a893a11f08015ea150c1e287482`; its vendored SHA-256 is
`2341a4a9f811a4f9fa463506149bd5a91dcd5a9ad2cb305473c87095bf247830`.
The revision comes from the upstream
[angie-ctl repository](https://github.com/6RUN0/angie-ctl); no workflow tracks
it, so an update requires manual source review, test execution, checksum
refresh, and a changelog entry.

---

Russian: [configuration.ru.md](configuration.ru.md).
