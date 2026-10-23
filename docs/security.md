# Security and Running Without Root

Privilege model and hardening guidance for both image variants.

## User model

| Property | Standard | Unprivileged |
|---|---|---|
| Master process | root | uid/gid 65532 by default; arbitrary UID supported |
| Worker process | package user `angie` | same as master |
| Public HTTP port | 80 | 8080 |
| Capabilities | retain Docker defaults for the root master | none |
| Live config and temporary files | `/data/conf`, `/data/tmp` | `/data/conf`, `/data/tmp` |

Both variants use the same immutable `/etc/angie` skeleton and feature toggles.
The standard image keeps the conventional root master so it can bind port 80,
then runs workers as `angie`. The unprivileged image removes the `user`
directive and can run under any UID, although its default identity is 65532.

`/data` is root-owned 0755 in the standard image, so workers cannot write next
to the temporary paths the root master hands them; the unprivileged image
creates it with mode 1777 so any runtime UID can build its tree. The entrypoint
refuses to replace a non-empty `/data/conf` it did not create and refuses a
tree owned by a different UID. This prevents an arbitrary runtime identity from
overwriting another identity's configuration. Use a fresh volume or correct
ownership when changing UID.

## Running under another UID

The unprivileged image needs write access in exactly one place, `/data`, which
it creates with mode 1777. `docker run --user <any uid>` therefore applies the
`ANGIE_*` toggles exactly as the default 65532 does, with no reduced feature
set. The one condition: `/data` must be writable for that UID. Under
`--read-only` without a `/data` mount, startup fails with exit code 1 and a
message naming `--tmpfs /data` and `-v angie-data:/data`, instead of falling
back to the build-time configuration. A persistent volume stays bound to the
UID that filled it, see [ACME keys](#acme-keys).

The standard image refuses a non-root master before any configuration runs:

```text
the default image requires a root master for port 80 and the angie worker user; use the unprivileged image for rootless operation
```

Its port 80 and the `user angie` directive need root; use the unprivileged
image for rootless operation instead of `--user`.

## Hardening

### Read-only root filesystem

Both variants need one writable mount:

```sh
# Standard image

docker run --read-only --tmpfs /data:mode=1777 \
  6run0/angie:alpine

# Unprivileged image

docker run --read-only --tmpfs /data:mode=1777 \
  --cap-drop ALL --security-opt no-new-privileges:true \
  6run0/angie:alpine-unprivileged
```

The standard master also needs to change worker identity and temporary-file
ownership; `NET_BIND_SERVICE` alone is insufficient. Use the unprivileged image
to drop all capabilities.

Both Dockerfiles strip setuid and setgid bits from every file of the image
filesystem, so `su`, `passwd` and similar binaries do not elevate a non-root
process (on Debian, 11 binaries from shadow and util-linux carried them).

Use a persistent `-v angie-data:/data` instead of tmpfs when ACME or a
disk-backed cache is enabled. `/data/acme` contains private account keys and
certificates. Do not mount `/data/conf` directly.

### Restrict network exposure

Publish only the required port. The optional status listener defaults to 8181
and is deliberately not exposed by the image. If other containers need it,
keep it on an internal network; if the host needs it, bind to loopback.

```sh
docker run -p 127.0.0.1:8080:8080 \
  6run0/angie:alpine-unprivileged
```

No TLS listener is enabled by default. Add one in
`/etc/angie/custom/http.d`, or terminate TLS in front of the container.

## Configuration trust boundaries

`/etc/angie/custom` is trusted code. Angie configuration can expose files,
proxy traffic, load modules, and weaken access controls. Mount it read-only and
review changes. The image loads only these subdirectories:

- `conf.d` in the main context;
- `http-conf.d` in the `http` context;
- `http.d` for virtual hosts.

Make directories traversable and files readable by the worker identity. In the
standard image, a root master successfully validating a file does not prove the
`angie` worker can read it at request time.

## Configuration traps

None of these produces an error: `angie -t` passes and the health check stays
green.

`/healthz` answers anyone who comes from loopback. `$_stock_loopback` keys on
`$realip_remote_addr`, the TCP peer before real-IP substitution, so
`X-Forwarded-For: 127.0.0.1` does not pass it even with `ANGIE_REAL_IP_FROM`
set (measured on the 1.12.4 Alpine image, 2026-10-23, with
`ANGIE_REAL_IP_FROM=172.17.0.0/16`: such a request from the host got `404`, a
plain request from inside the container `200`). A loopback neighbour passes honestly: a sidecar or a proxy in
the same network namespace, and with it whatever it forwards from outside.
Such a proxy must not forward `/healthz`. `allow`/`deny` would not help: the
endpoint's `return` runs in the rewrite phase, before the access phase.

Image variables can be replaced silently. A `$_stock_*` variable redeclared in
`/etc/angie/custom` wins over the image's, `$_stock_loopback` included, see
[configuration.md](configuration.md#variables-declared-by-the-image).

gzip compresses proxied responses regardless of upstream headers
(`gzip_proxied any` in `020-gzip.conf`). Compressing a response that reflects
attacker-controlled input next to a secret is the BREACH precondition. When
proxying authenticated content, restrict `gzip_proxied` or disable compression
for those locations.

Every shipped access-log format writes the query string: `path` is
`$request_uri` in `json`, `logfmt`, their GeoIP2 variants and `matomo`,
`extended` logs `ru="$request_uri"`, `main` logs `"$request"`. A secret in the
URL (`?token=`, `?api_key=`, a session id) lands in the container's stdout. If secrets travel in query parameters, use your own format
with `$uri`. The Console Light path lands there too, so it is no secret from
anyone reading container logs; basic auth is the panel's protection.

The Status API listens on `0.0.0.0:8181` when enabled, so a metrics collector
in a neighbouring container can reach it. Its only protection is that the port
is not published: the snippet has no `allow`, `deny` or authentication. In
Kubernetes nothing is published either, the port is open to every pod by pod
IP until a NetworkPolicy closes it. For the same reason
`ANGIE_STATUS_API_PORT` equal to the public port (80 standard, 8080
unprivileged) fails startup: on a shared socket a request with the Status API
`server_name` in `Host` would bypass the catch-all `return 444`. The check
knows only the built-in port; a collision with your own listener from
`/etc/angie/custom` is yours to avoid.

Security headers do not merge. Any `add_header` in a `server` or `location`,
even for an unrelated header, replaces the inherited set, and the headers of
`055-security-headers.conf` disappear together with CORS and HSTS. Repeat them
where you add your own, see
[troubleshooting.md](troubleshooting.md#25-security-headers-vanish-in-my-location).

`ANGIE_CORS_ASSETS_ENABLED` allows less than its name suggests. The header
value comes from a map on the response content type, not on the request
`Origin`: fonts and images get `Access-Control-Allow-Origin: *`, documents,
JSON and every other type get no header. The toggle fixes fonts a browser
refuses to load cross-origin; it does not open your API to other origins. The
other side: `*` on an image lets a script on any page read it, so do not enable
the toggle on a site serving images behind authentication. With two chained
Angie servers both using the toggle the header is sent twice, and the browser
rejects such a response outright; keep it on one of them.

## Environment values never reach the configuration verbatim

Every value substituted into a directive is checked first, against a
character set or a list of values: `GEOIP2_DB_COUNTRY`, `ANGIE_REAL_IP_FROM`,
`ANGIE_REAL_IP_HEADER`, `ANGIE_REAL_IP_RECURSIVE`, `ANGIE_STATUS_API_HOST`,
`ANGIE_STATUS_API_PORT`, `ANGIE_ACME_DIRECTORY`, `ANGIE_ACME_CLIENT`,
`ANGIE_ACME_CHALLENGE`, `ANGIE_ACME_EMAIL`, `ANGIE_ACME_HTTP_PORT`,
`ANGIE_HSTS_MAX_AGE`, `ANGIE_WORKER_SHUTDOWN_TIMEOUT`, `ANGIE_CONSOLE_PATH` and
`ANGIE_CONSOLE_HTPASSWD_FILE`. The allowed sets are in
[configuration.md](configuration.md#environment-variables) and in each
refusal message. A value with a foreign character fails container startup
instead of being rendered into the configuration; this is what closes
configuration injection through the environment.

## Console Light

Console Light exposes operational status. Keep all three controls:

1. a random `ANGIE_CONSOLE_PATH` of at least 16 characters;
2. a readable htpasswd file through `ANGIE_CONSOLE_HTPASSWD_FILE`;
3. TLS in front of the public listener.

Generate values without putting the password in the environment:

```sh
openssl rand -hex 16
printf 'admin:%s\n' "$(openssl passwd -6)" > console.htpasswd
chmod 0644 console.htpasswd
```

Mount the containing directory at `/etc/angie/custom:ro`. Setting
`ANGIE_CONSOLE_HTPASSWD_FILE=none` disables authentication and should be used
only on a separately protected private listener.

## ACME keys

ACME state is stored under `/data/acme`. Protect the persistent volume and its
backups as secret material. Do not use tmpfs: losing the state causes a fresh
account/certificate order after recreation and can exhaust CA rate limits.
Use a staging CA during initial configuration.

The unprivileged variant cannot bind an internal challenge port below 1024;
publish host port 80 to its internal 8080 listener. The standard variant may
use its default port 80.

## TLS

No TLS listener ships: no `server` does `listen ... ssl`, and only the plain
HTTP port is in `EXPOSE`. The active-by-default `050-ssl.conf` sets the policy
any TLS listener of yours inherits in the `http` context:

- protocols TLSv1.2 and TLSv1.3, Angie's default; the file pins no floor;
- for TLS 1.2 only the six ECDHE AEAD suites of the Mozilla intermediate
  profile; TLS 1.3 suites are not set by `ssl_ciphers`;
- `ssl_session_tickets off`: Angie keeps the ticket key until reload, and a
  leaked key decrypts all recorded traffic. Resumption goes through the shared
  `ssl_session_cache`.

Measured on the 1.12.4 Alpine image (2026-10-23, OpenSSL 3.5.8 client):
`openssl s_client -tls1_2 -cipher ECDHE-RSA-AES256-SHA` is refused with
`SSL alert number 40`, without a cipher choice the handshake settles on
`ECDHE-RSA-AES256-GCM-SHA384`, and the server issues no session ticket. For an
old client that needs CBC suites, override `ssl_ciphers` in its `server {}`.

Add the listener in `/etc/angie/custom/http.d` with your certificate paths:
port 443 in the standard image; 8443 in the unprivileged image, published as
`-p 443:8443`, because a privileged port under a non-root master depends on
the runtime, see [configuration.md](configuration.md#ports).

## HSTS

HSTS is browser state, not merely a response header. Before enabling
`ANGIE_HSTS_ENABLED`, confirm HTTPS works for the full lifetime and for every
subdomain if `ANGIE_HSTS_INCLUDE_SUBDOMAINS=yes`.

To withdraw HSTS safely:

1. keep the toggle enabled and set `ANGIE_HSTS_MAX_AGE=0`;
2. serve that header over valid HTTPS long enough for clients to receive it;
3. only then disable the toggle.

Removing the header immediately does not clear existing client state.

## Secrets

Do not pass passwords, private keys, or API credentials as environment
variables: they are visible through container inspection and often process
metadata. Mount secret files read-only or use the runtime's secret mechanism.
Keep GeoIP databases, TLS material, htpasswd files, and ACME state readable only
by the identities that need them.

## Reporting vulnerabilities

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/6RUN0/docker-angie/security/advisories/new).
Do not open a public issue for an undisclosed vulnerability.

---

[Back to README](../README.md)

Russian: [security.ru.md](security.ru.md).
