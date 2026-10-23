# Image Architecture

How the images are put together and why. Read before changing `rootfs/`,
`rootfs-unprivileged/`, a Dockerfile or an entrypoint script: half of the
decisions here are not obvious, and breaking them usually fails silently.

Not here: environment variables (`configuration.md`), operating recipes
(`usage.md`), the CI pipeline (`.github/workflows/`).

Two variants are built from one `rootfs/`, as two final targets of one
Dockerfile per distro (`alpine/Dockerfile`, `debian/Dockerfile`) on a shared
`runtime` stage. The regular image (`--target standard`, the default) runs a
root master on port 80 with workers as the `angie` user. The unprivileged image
(`--target unprivileged`) overlays `rootfs-unprivileged/` and runs everything
as one non-root uid on port 8080. `runtime` declares no `EXPOSE`: Docker
cannot drop an inherited one, so each target declares only its own port. Everything below applies to both unless a
section names a variant.

## Activation model: available.d and .d

Config snippets and module-load files ship **disabled**. They live in the
directories with the `-available` suffix:

- `rootfs/etc/angie/http-conf-available.d/` - snippets for the `http {}`
  context (gzip, brotli, ssl, log formats, geoip2, websocket map and others);
- `rootfs/etc/angie/modules-available.d/` - `load_module` directives for the
  dynamic modules.

`angie.conf` includes the active directories instead: `http-conf.d/` and
`modules.d/`. Activation is a symlink from the active directory into
`-available.d`, set by `angie-ctl`, a script vendored in this repository at
`rootfs/usr/local/bin/angie-ctl`:

```sh
angie-ctl httpconf en 020-gzip.conf          # enable an http-conf snippet
angie-ctl mod en http_brotli_filter.conf     # enable a module load
```

`modules.d/` ships empty (only `.gitkeep` keeps it in git): every module is
enabled at runtime only. `http-conf.d/` holds two tracked symlinks active by
default - `010-common.conf` and `050-ssl.conf` - plus `.gitkeep`. The build
adds two more as root, before `ENV ANGIE_ETC` is set, so they land in the
skeleton: `030-log-format-json.conf` and `040-log-json.conf`. They serve the
requests when the entrypoint did not run (`--entrypoint angie`, or a command
other than `angie` and `angie-debug`). Their format therefore stays in line
with the `40-log.sh` default: if the two diverged, such a run would log in a
format other than the documented one. Everything else is activated at start.

`050-ssl.conf` is active but inert: it sets the common TLS policy -
`ssl_session_cache`, `ssl_session_timeout`, `ssl_session_tickets off`,
`ssl_ciphers` (six ECDHE suites with AEAD from the Mozilla intermediate
profile) and `ssl_prefer_server_ciphers off` - while no server does
`listen ... ssl` (the regular image exposes port 80, the unprivileged one
8080). A TLS listener
added through the custom mount inherits this policy and overrides it in its
own `server {}`.

To add a feature, create the snippet in the matching `-available.d` and enable
it from an entrypoint script. Do not put the file into the active directory.

### What the model does not cover: snippets/

Activation works for the `http {}` context only: the symlink lands in a
directory that `angie.conf` includes inside `http {}`. Directives that must
sit inside `server {}` or `location {}` live in `rootfs/etc/angie/snippets/` -
plain files without activation, included by name
(`include snippets/healthz.conf;`).

The image's own files include them the same way a consumer does:
`http.d/default.conf` takes `/healthz` and the `console.conf` panel from
there, and the `070-status-api.conf.template` template takes the body of the
status listener. Copying the content instead of including it is not allowed:
the set of paths must stay one for the image and the consumer, or the two
drift apart on the first edit.

One snippet is rendered: `console.conf` ships as a one-comment stub, and
`40-console.sh` overwrites its copy in the live tree from the neighbouring
`console.conf.template` when `ANGIE_CONSOLE_ENABLED` is on. It has no
activation; the disabled state comes back with the skeleton copy on every
start.

A snippet needs no activation of its own but may depend on someone else's: a
directive inside `server {}` may rely on a variable declared in the `http {}`
context, and that declaration arrives by activation. `healthz.conf` uses
`$_stock_loopback` (declared by `010-common.conf`, active by default), and
`expires-by-type.conf` uses `$_stock_expires` (the `ANGIE_EXPIRES_ENABLED`
toggle). The failure is loud, `[emerg] unknown "_stock_expires" variable`, but
the link between the two directories is not visible from the tree.

The full list of files is in [configuration.md](configuration.md#reusable-snippets).

### Empty modules.d and .gitkeep

Losing `modules.d/` gives no error: `angie -t` passes, the health check is
green, the exit code is 0, and enabling a module silently does nothing. Keep
`.gitkeep` in it.

## Why activation happens at start, not at build

One image serves many uses: the set of enabled features is chosen by
environment variables at run time. Building a separate image for every
combination of `*_ENABLED` variables makes no sense, and keeping everything
enabled means loading five dynamic modules where one is needed.

Activation does not touch the shipped tree but its copy: `/etc/angie` is never
edited, and the live configuration lives in `/data/conf`, rebuilt on every
start (see "The only writable location"). So the state of a previous run does
not survive a restart even on a persistent volume, and removing an `ANGIE_*`
variable really turns the feature off.

## Entrypoint flow

`ENTRYPOINT` is `tini -- /docker-entrypoint.sh`, `CMD` is
`angie -p /data/conf -c angie.conf -g 'daemon off;'`. The `-p` and `-c` flags
point angie at the live tree; a relative `-c` resolves against the prefix, and
that is exactly what lets one tree work both as the skeleton and as the copy.

1. `docker-entrypoint.sh` configures only when `$1` is `angie` or
   `angie-debug`. Any other command goes straight to `exec`; a non-executable
   one gets `ngx_err "$1: not executable or not found"` and exit code 1.
2. In the regular image a non-root start is refused before any script runs,
   unless `ANGIE_UNPRIVILEGED` is set: a non-root master could neither bind
   port 80 nor switch workers to `angie`, and would fail later with an opaque
   `EACCES`. The unprivileged image sets `ANGIE_UNPRIVILEGED=1`.
3. It runs every executable `*.sh` from `/docker-entrypoint.d/` in shell glob
   order (numeric as well: the two-digit prefixes `10-`, `30-`, `90-` sort the
   same either way). There is deliberately no external `sort`: in a
   `find ... | sort -V | while` pipeline the loop body runs in a subshell that
   `set -e` does not reach, and a failed script would be lost silently. A
   non-executable file or a file not ending in `.sh` is skipped with a
   warning, not silently.
4. A failed script stops the start loudly: `ngx_err "$f failed with exit $rc,
   aborting startup"` and an exit with the same code.
5. After all scripts comes the **single** check, `"$@" -t`, over the fully
   assembled configuration; with `angie-debug` it is `angie-debug` that is
   tested. The whole argument list is tested, not the binary alone: without
   `-p` and `-c` from `CMD` it would test the shipped skeleton instead of the
   copy about to be served. Its failure is `ngx_err "assembled configuration
   failed '$1 -t', aborting startup"`, the test output on stderr and exit
   code 1.
6. `exec "$@"`.

`docker-entrypoint-common.sh` is sourced (`.`) by every script and provides
logging (`ngx_err`, `ngx_warning`, `ngx_notice`, `ngx_info`, all subject to
`ANGIE_ENTRYPOINT_QUIET_LOGS`), the `ngx_ctl` wrapper over `angie-ctl`, the
live-tree paths (`ANGIE_DATA_DIR`, `ANGIE_CONF_DIR`, `ANGIE_TMP_DIR` and the
exported `ANGIE_ETC` that `angie-ctl` takes its root from), `ANGIE_HTTP_PORT`
(80, or 8080 with `ANGIE_UNPRIVILEGED`), `is_root`, the declarative reset
helpers `reset_httpconf` and `reset_module`, and the log selection helpers
`enable_log_format` and `enable_log`. Logging goes to file descriptor 3, which
maps to stderr, or to `/dev/null` when quiet mode is on.

### Why there is one check and why it matters

`angie-ctl` runs a config test after each batch unless told otherwise, and
`ngx_ctl` always calls it with `--no-test`, so the entrypoint's toggles only set
and remove symlinks. The check is deferred to the end on purpose, which removes
an ordering trap.

On every `angie -t` angie checks the variables of **every** declared
`log_format`. While one toggle enables its snippet, an orphan from another
feature not yet reset in this run would poison an intermediate check. For
example, the geoip2 log format refers to `$_stock_geoip2_country_code`, which
exists only with geoip2 enabled, and the format is enabled by an earlier toggle
and survives until the one that removes it. With a check after every step, the
start would fail in an unrelated, earlier script than the one that removes the
orphan.

So an intermediate inconsistency is harmless: only the final state is tested.

### Declarative toggles

Each activation `NN-*.sh` first **resets** the snippets and modules it owns and
only then enables what the environment asks for. There are two reasons, both
within one run. Some snippets are enabled in the shipped tree already (the log
format pair, see the Dockerfile), and without disabling them a format choice
would add a second `access_log` directive instead of replacing it. And a later
toggle must override an earlier one cleanly (`50-geoip2` over `40-log`), not
stack on top of it.

Rebuilding the tree on every start solves the same problem from the other side:
the state of a previous run never reaches the toggles. The two mechanisms are
independent on purpose - breaking either one does not let a stale
`set_real_ip_from` list survive into serving requests, and that orphan is more
dangerous than the rest: it lets a client forge `$remote_addr`, and the core
realip directives never fail `angie -t`.

### Toggle convention

```sh
#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_SOME_FEATURE:=no}"

reset_httpconf NNN-snippet.conf

case "${ANGIE_SOME_FEATURE}" in
yes | on | 1 | true | enable | enabled)
  ngx_ctl httpconf en "NNN-snippet.conf"
  ;;
esac
```

The three lines before `case` are mandatory. Sourcing gives the loggers,
`ngx_ctl`, the live-tree paths and the resets; `reset_httpconf` turns off
everything the script owns before enabling by environment. The script calls
the `ngx_ctl` wrapper, not `angie-ctl` directly: every config change from the
entrypoint goes through it, so the call style is defined in one place. The
wrapper itself does not log: the caller does that on a separate line after
`&&`, as `enable_log_format` in `docker-entrypoint-common.sh` does. The
wrapper sends `angie-ctl`'s own stdout (`Enabled http-conf: ...`) to
`/dev/null`: it is plain text amid JSON in `docker logs`, and the caller
reports every change anyway. An `angie-ctl` failure goes to stderr, bypassing
descriptor 3, and quiet mode does not hide it.

The set of truthy values is exactly this one, for any new toggle. Extended
variants (`_STATIC` and the like) call the base helper first and then enable
their extra snippet: see `40-brotli.sh` and `40-gzip.sh`.

Two variables do not follow the set and are switched on by any non-empty value,
including `no`: `ANGIE_ENTRYPOINT_QUIET_LOGS` (`docker-entrypoint-common.sh`)
and `ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE`
(`30-tune-worker-processes.sh`). Both are tested for being non-empty, not
against the set. New toggles are not written that way.

### Three exceptions to the activation model

Three scripts edit the live `angie.conf` in place instead of through symlinks,
because the directive lives in the main context, which a snippet from
`http-conf.d` cannot reach:

- `30-tune-worker-processes.sh` - `worker_processes` (CPU quota detection from
  cgroup v1 and v2);
- `31-error-log-json.sh` - the `error_log` line, both ways;
- `32-worker-shutdown-timeout.sh` - the `worker_shutdown_timeout` line from
  `ANGIE_WORKER_SHUTDOWN_TIMEOUT`. Here the in-place edit is also the only
  way: a second declaration of a main-context directive is refused with
  `is duplicate`, so `custom/conf.d` cannot override it.

One more in-place edit is not in `angie.conf` but in the built-in virtual
host: after the copy, `10-conf-overlay.sh` deletes the
`listen [::]:<ANGIE_HTTP_PORT>;` line from `/data/conf/http.d/default.conf` when
`/proc/net/if_inet6` is missing (a kernel without IPv6). Otherwise the start
would fail with `socket() [::]:80 failed (97: Address family not supported
...)`. Consumer lines on the custom mount are not touched.

### Template rendering

Six scripts render configuration from a `.template` by placeholder
substitution, on every start; five templates are in `http-conf-available.d/`,
the sixth in `snippets/`:

- `35-real-ip.sh` - `015-real-ip.conf` (`%%REAL_IP_FROM_DIRECTIVES%%`,
  `%%REAL_IP_HEADER%%`, `%%REAL_IP_RECURSIVE%%`);
- `50-geoip2.sh` - `025-geoip2.conf` (`%%GEOIP2_DB_COUNTRY%%`);
- `40-status-api.sh` - `070-status-api.conf` (`%%STATUS_API_HOST%%`,
  `%%STATUS_API_PORT%%`);
- `40-acme.sh` - `080-acme.conf` (`%%ACME_HTTP_PORT%%`, `%%ACME_CLIENT%%`);
- `45-hsts.sh` - `056-hsts.conf` (`%%HSTS_VALUE%%`);
- `40-console.sh` - `snippets/console.conf` (`%%CONSOLE_PATH%%`,
  `%%CONSOLE_AUTH_BASIC%%`, `%%CONSOLE_AUTH_FILE%%`).

## Entrypoint script numbering

The two-digit prefix in `/docker-entrypoint.d/` sets the run order:

| Prefix | Scripts |
| --- | --- |
| `10-` | `10-conf-overlay.sh`: rebuilds `/data/conf`; must run first, every other script edits its result |
| `30-`, `31-`, `32-` | in-place edits of `angie.conf`: `worker_processes`, `error_log`, `worker_shutdown_timeout` |
| `35-` | real-ip |
| `40-` | features: acme, brotli, charset, console, expires, gzip, log, modsecurity, open-file-cache, status-api, subs, zstd |
| `45-`, `46-` | hsts, security headers, CORS for static assets |
| `50-` | geoip2: after `40-log.sh`, because it overrides the log chosen there with its geoip2 variant |
| `60-` | websocket map |
| `90-` | `CACHE_DIR` and htpasswd ownership fixes; act only in the regular image under a root master, exit early otherwise |

A custom script mounted into `/docker-entrypoint.d/` takes its number by what
it needs ready: after `10-` the `/data/conf` tree is assembled, after `60-`
every shipped toggle has run, and a number from `61-` to `89-` runs before the
`90-` ownership fixes. A non-zero exit code of a custom script aborts the start
the same way a shipped one does.

## Snippet numbering

The numeric prefix sets the include order inside the `http {}` context:

| Prefix | What it is |
| --- | --- |
| `010-`, `011-`, `015-`, `020-`, `021-`, `023-`, `024-`, `025-` | common settings, charset, real-ip, compression, expires, open_file_cache, geoip2 |
| `030-log-format-*` | log format definitions |
| `040-log-*` | active log selection (`access_log`) |
| `050-`, `055-`, `056-`, `057-`, `060-`, `070-`, `080-` | ssl, security headers, hsts, CORS for static assets, websocket map, status API, acme |

The split between `030-` and `040-` matters: exactly one `access_log` may be
active, because angie applies every directive it parses, and two enabled
`040-log-*` snippets write each request twice. So `enable_log` first disables
the whole `040-log-*` group by name pattern, not by a hand-kept list: a new
format joins the group by itself.

## Names of variables the image declares

Variables of the shipped tree carry the `$_stock_` prefix: stock is what the
image provides, custom is what the consumer adds in `/etc/angie/custom`.

The prefix exists because a name collision here is silent. `map`, `geo` and
`geoip2` register their variable as redefinable, `custom/http-conf.d` is
included after the image tree, so the consumer's declaration wins and
`angie -t` succeeds. A consumer who takes `$connection_upgrade` from the usual
documentation recipe would break the image's map without a single log line.

Not every declaration is silent:

| Declaration | Duplicate from `custom` |
| --- | --- |
| `map`, `geo`, `geoip2 { }` | silent, the last one wins |
| `time_format`, `log_format` | `[emerg]`, the start fails |

All declarations carry the prefix, `time_format` included: an exception for one
name would have to be remembered by every later reader and check, and in a year
nobody would know why it is there. Log format names are a separate namespace
with the `angie_` prefix (`angie_json`, `angie_logfmt`), and there is no
reason to change it: a duplicate name fails the start, so it is found at once.

For variables the `angie_` namespace is taken by upstream - `$angie_version`
exists. Angie has no namespaces, no scopes and no diagnostics for a repeated
declaration, so only the naming convention is available. It lowers the chance
of a collision but does not rule it out: a consumer who declares
`$_stock_loopback` still wins silently.

## Configuration tree

`angie.conf` contains only top-level directives and includes. Image includes
are relative to the `/data/conf` prefix; every include has an absolute
`/etc/angie/custom/...` pair, so the user layers configuration through the
`/etc/angie/custom` mount without touching the shipped files.

Inside `http {}` the pairing is broken on purpose: both consumer points
(`custom/http-conf.d` and `custom/http.d`) are included after the built-in
`http.d/*.conf`, not each right after its image directory. The order is
load-bearing. The default server for an address is the first `server`
declared on it, the built-in catch-all does not carry the `default_server`
flag, and a `server {}` block is legal in the `http {}` context - that is, in
`custom/http-conf.d`. With the paired order such a block would take the default
silently: no flag, no warning and no `444` for an unknown `Host`.

`http.d/default.conf` is the only active vhost: a catch-all `server` answering
`444` on port 80 (8080 in the unprivileged overlay,
`rootfs-unprivileged/etc/angie/http.d/default.conf`), and the `/healthz`
endpoint, reachable from loopback only. Loopback is decided by
`$_stock_loopback` from `$realip_remote_addr`, that is, from the real TCP
peer: with real_ip enabled `$remote_addr` becomes the header value, and
`X-Forwarded-For: 127.0.0.1` would open the endpoint. Real vhosts come through
the mount, and their own `listen 80 default_server` (`8080` in the
unprivileged image) is allowed. The name `healthz-catchall.invalid` of the
built-in host has two roles: it keeps requests **without** a `Host` header (a
server without `server_name` gets the empty name, and that takes such requests
from the default server), and it is the address for `HEALTHCHECK`, which needs
its own endpoint whoever owns the default.

## Two variants: root master and unprivileged

Common to both:

- there is no pid file: `conf.d/10-pid.conf` sets `pid off`. The package
  default (`/run/angie.pid`) is root-owned, and any shared writable place turns
  into a trap - an `angie.pid` left by a previous owner cannot be opened for
  writing under another uid, and the start fails with `open() ... angie.pid
  failed (13: Permission denied)`. The price is that `angie -s <signal>` does
  not work: it finds the master by the pid file and fails with
  `no PID file configured` and code 1. Reload is done from outside,
  `docker kill -s HUP <container>`, and tini forwards the signal to the master;
  `angie-ctl --reload` does the same from inside, its `ANGIE_RELOAD_CMD` is
  `kill -HUP 1`;
- stop goes the same way: the image `STOPSIGNAL` is `SIGQUIT`, a graceful stop
  that finishes open requests, not `SIGTERM`, a fast stop at which angie closes
  connections without waiting (angie documentation on control signals). Long
  connections are capped by `worker_shutdown_timeout 8s` in `angie.conf`,
  below docker's default `stop_grace_period` (10 s): otherwise a websocket or a
  slow download would drive the container to `SIGKILL` and code 137. The value
  is set by `ANGIE_WORKER_SHUTDOWN_TIMEOUT`, see "Three exceptions to the
  activation model" above; a fast stop is available from outside,
  `docker kill -s TERM <container>`;
- temporary directories (`client_temp`, `proxy_temp` and the rest) are moved to
  `/data/tmp` from the root-owned `/var/cache/angie`; the directives are in
  `010-common.conf`.

Regular image, root master:

- port 80; `conf.d/05-worker-user.conf` holds `user angie;`, so the workers
  drop to the `angie` user;
- `/data` and `/data/tmp` are `0755 root:root` from the build, and
  `10-conf-overlay.sh` empties `/data/tmp` and makes it `root:root 0755` again
  on every start. The root master chowns each temp path to the worker on every
  start and reload, following links; a worker-writable parent would let a
  compromised worker replace a temp directory with a link to a root file;
- files the workers read at request time are checked as the `angie` user
  (`su -s /bin/sh angie -c "test -r ..."`): `/data/conf/angie.conf` and the
  Console Light htpasswd. A root `-r` passes for files the workers cannot
  open, and the first request would get 500;
- the `90-` scripts chown `CACHE_DIR` and `*htpasswd*` files under
  `/etc/angie/custom` to `angie`, never through a symlink;
- `ANGIE_ACME_HTTP_PORT` below 1024 is allowed.

Unprivileged image:

- port 8080: the image does not rely on privileged ports, their availability
  to a non-root uid depends on the runtime;
- `USER` is numeric, `65532:65532` by default (`APP_UID`, `APP_GID` build
  arguments), not a name: kubelet with `runAsNonRoot` cannot check a name
  without the image's `/etc/passwd` and refuses (`image has non-numeric
  user`);
- `rootfs-unprivileged/etc/angie/conf.d/05-worker-user.conf` replaces the
  `user` directive with a comment: the master cannot execute it and would log
  `[warn]` on every start. `test/smoke-unprivileged.sh` checks that the warning
  is absent;
- `/data` and `/data/tmp` are `1777`, like a regular shared directory: master
  and workers share one uid, so a world-writable sticky `/data` adds no
  escalation, and any `docker run --user <uid>` builds its own tree instead of
  degrading to the build-time configuration;
- `ANGIE_ACME_HTTP_PORT` below 1024 is refused as image policy; publish port 80
  by port mapping instead.

The `/etc/angie` tree stays root-owned and is never edited. Write access is
needed in exactly one place - `/data`.

## The only writable location

`/data` is everything that changes at run time:

| Path | Contents |
|---|---|
| `/data/conf` | live configuration tree, a copy of `/etc/angie` |
| `/data/tmp` | the five angie temp paths |
| `/data/acme` | ACME account keys and certificates, when `ANGIE_ACME_ENABLED` is on |

`10-conf-overlay.sh` makes the copy, first among the entrypoint scripts, and
makes it again on every start. The user directory `/etc/angie/custom` is not
copied: its includes are absolute, it stays a mount point.

Three properties follow:

- configuration is writable even with a read-only root, so hardening comes down
  to one line (`--tmpfs /data`) instead of a list of directories;
- the state of a previous run does not survive a restart, even on a persistent
  volume (except `/data/acme`, which ACME needs to persist);
- an image update reaches the live configuration without re-creating the
  volume (a named docker volume is filled from the image only once, while it is
  empty - a volume on `/etc/angie` would freeze the tree at the version of the
  first run).

The price is a gap between the compiled-in prefix and the live one.
`angie -V` prints `--prefix=/etc/angie`, while `/data/conf` is served, so
angie inside the container is called with the flags, or through the
`angie-runtime` wrapper that adds them:

```sh
docker exec <container> angie -p /data/conf -c angie.conf -T
docker exec <container> angie-runtime -T
```

Without the flags the command reads the shipped skeleton, that is, it shows a
configuration nobody serves.

The startup checks of `10-conf-overlay.sh`, in order:

| Check | Why |
| --- | --- |
| a file created with `mktemp` in `/data` | a real write catches a read-only mount that mode bits do not show; `mktemp`, not a pid-based name, because a co-tenant of a shared `/data` could pre-plant a predictable probe path as a link |
| `/data/conf` and `/data/tmp` are not symbolic links | the cleanup loop would walk the contents of the directory the link points to |
| a non-empty `/data/conf` holds a regular `.angie-conf-overlay` file with the signature `angie-managed-conf-v1` | a volume mounted at `/data/conf` instead of `/data` would otherwise lose its contents silently; `-e` would pass for a link and `touch` would write through it; the name does not end in `.conf`, so include masks never pick it up |
| `/data/conf` belongs to the uid of the run (`stat -c %u`, POSIX `test` has no `-O`) | a directory of another uid on a shared volume could carry a planted marker and files that the copy cannot remove |
| regular image only: `angie.conf` in the copy is readable by `angie` | a bind-mounted `/data` with unsearchable parents would otherwise fail at the first request |

Each failure is exit code 1 with a message naming the fix, for example
`/data/conf belongs to uid <N>, not to uid <M> this container runs as: ...`.
`40-acme.sh` likewise refuses a symlinked `/data/acme`, so keys are never
written outside the data mount.

Under `read_only` without a writable `/data` the only thing that stops working
is the start itself: `10-conf-overlay.sh` exits with code 1 and names the fix.
This is deliberate, instead of a quiet fallback to the build-time
configuration, which would look like "the toggles do not work" with no reason
given.

## Editing rituals

**Both distributions stay in sync.** The module set, package pins, labels,
the runtime `ENV`, `STOPSIGNAL` and `HEALTHCHECK` and the layer order match in
`alpine/Dockerfile` and `debian/Dockerfile`, in every stage (`runtime`,
`unprivileged`, `standard`). The release workflow checks `ARG ANGIE_VERSION`
against the tag; any other drift is checked by eye, `make lint` does not see
it.

**Metadata arguments are declared at the last `LABEL` of each final target,
below every `RUN`.** Changing an
`ARG` value invalidates the cache of every `RUN` after the declaration, even
one that does not mention it, and a per-commit `VCS_REF` would rebuild the
package installation. A new label argument goes to the same place.

**A new entrypoint script must be committed executable.** Skipping that gives
no build error but a silently disabled feature: `docker-entrypoint.sh` only
prints a warning for a non-executable `*.sh` and goes on. For
`45-security-headers.sh` that means, for example, no `X-Frame-Options` with a
green health check and exit code 0.

**All scripts are POSIX sh** (`#!/bin/sh`) and are checked with
`shellcheck -s sh`. That covers the entrypoint and the tests alike: the suites
must run on hosts without bash.

---

[Security](security.md) |
[Configuration](configuration.md) |
[Back to README](../README.md)

Russian: [architecture.ru.md](architecture.ru.md).
