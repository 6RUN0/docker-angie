#!/bin/sh
# Smoke tests for a built Angie image. Drives the container with various ANGIE_*
# toggles and asserts the effective configuration / runtime behavior. POSIX sh
# on purpose: the suite must run on hosts without bash (alpine CI runners).
#
# Usage: IMAGE=angie-alpine ./test/smoke.sh
set -eu
# pipefail is not POSIX (before POSIX.1-2024); busybox ash and dash >= 0.5.12
# support it, older dash does not -- hence the subshell probe instead of an
# unconditional set. The assertions do not depend on it -- a failing left side
# of a pipe yields empty output, which the asserts catch.
# shellcheck disable=SC3040 # probed in a subshell first; harmless when absent
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

IMAGE="${IMAGE:?set IMAGE=<image:tag>}"

tests=0
fails=0
vols=""
# Fixture dirs from mktemp -d, swept by the EXIT trap: the per-section rm -rf
# only runs on the happy path; a set -e abort or Ctrl-C mid-section would leak
# them into /tmp otherwise. Registered right after each mktemp (at top level,
# not inside $(...), so the accumulation survives -- unlike start()'s cids).
tmpdirs=""

# Containers are swept by label, not by an accumulated id list: start() runs
# inside command substitutions, so an id appended to a variable there dies with
# the subshell -- an aborted run would leak its containers.
SMOKE_RUN_LABEL="angie-smoke-run=$$"

cleanup() {
  # No `xargs -r` (a GNU/busybox extension): with an empty id list docker rm
  # errors on missing arguments, which the redirect + `|| true` absorb.
  docker ps -aq --filter "label=$SMOKE_RUN_LABEL" | xargs docker rm -f >/dev/null 2>&1 || true
  for __cleanup_vol in $vols; do
    docker volume rm -f "$__cleanup_vol" >/dev/null 2>&1 || true
  done
  for __cleanup_tmp in $tmpdirs; do
    rm -rf "$__cleanup_tmp"
  done
}
trap cleanup EXIT

pass() {
  tests=$((tests + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  tests=$((tests + 1))
  fails=$((fails + 1))
  printf '  FAIL %s\n' "$1"
}
assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}
assert_contains() { # haystack needle label
  case "$1" in
  *"$2"*) pass "$3" ;;
  *) fail "$3 (missing '$2')" ;;
  esac
}
# Negative of assert_contains: fail if the needle IS present. Lists one or more
# active dirs inside $cid and asserts the combined output lacks needle -- used to
# confirm a snippet/module symlink is gone after a declarative reset.
# Distinct __ad_ prefix: POSIX sh has no `local`, so these leak into the caller;
# the prefix avoids clobbering the caller's variables (same convention as
# docker-entrypoint-common.sh).
assert_disabled() { # cid label needle activedir...
  __ad_cid=$1
  __ad_label=$2
  __ad_needle=$3
  shift 3
  __ad_listing=$(docker exec "$__ad_cid" sh -c "ls $* 2>/dev/null" || true)
  case "$__ad_listing" in
  *"$__ad_needle"*) fail "$__ad_label (still enabled: '$__ad_needle')" ;;
  *) pass "$__ad_label" ;;
  esac
}
# Symlink an available snippet/module into its active dir inside $cid, simulating
# an orphan a prior run left active. `src` is relative to the active dir (the
# `../*-available.d/...` form angie-ctl uses); `dst` is the active path.
link_active() { # cid src dst
  docker exec "$1" ln -sf "$2" "$3"
}

# Start a detached container tagged for the label-based cleanup; echoes the id.
start() { # extra docker run args...
  docker run -d --label "$SMOKE_RUN_LABEL" "$@" "$IMAGE"
}

# Poll the in-container /healthz endpoint until it answers or we give up.
wait_healthy() { # cid
  __wh_cid=$1
  for _ in $(seq 1 40); do
    if docker exec "$__wh_cid" wget -q -O /dev/null http://127.0.0.1/healthz 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Poll `docker logs` (stdout stream) until it contains the needle or we give
# up, then print the collected logs either way so the caller's assert reports
# the real final state. Replaces a fixed sleep: an access-log line traverses
# angie -> tini -> the json-file driver asynchronously, and a loaded CI host
# can take longer than any fixed delay.
wait_logs() { # cid needle
  __wl_cid=$1
  __wl_needle=$2
  __wl_out=""
  for _ in $(seq 1 20); do
    __wl_out=$(docker logs "$__wl_cid" 2>/dev/null)
    case "$__wl_out" in *"$__wl_needle"*) break ;; esac
    sleep 0.5
  done
  printf '%s' "$__wl_out"
}

# Dump the effective, fully-resolved configuration.
dump_conf() { docker exec "$1" angie -T 2>/dev/null; }

printf 'Smoke testing %s\n' "$IMAGE"

# --- 1. Base launch: healthz up, unknown host gets 444 ----------------------
cid=$(start)
if wait_healthy "$cid"; then
  pass "container becomes healthy (/healthz 200)"
else
  fail "container becomes healthy (/healthz 200)"
fi
# The classifier must return the body, not just a reachable status: wget -O- so a
# regression that answers 200 with the wrong payload is caught.
body=$(docker exec "$cid" wget -q -O - http://127.0.0.1/healthz 2>/dev/null || true)
assert_eq "$body" "ok" "/healthz body is exactly 'ok'"
if docker exec "$cid" wget -q -O /dev/null http://127.0.0.1/ 2>/dev/null; then
  fail "default server denies unknown host (expected 444/closed)"
else
  pass "default server denies unknown host (444)"
fi
# /healthz is loopback-only: a request from ANOTHER container (real external
# source IP) must be denied. Querying from inside $cid would keep the source in
# the loopback range, so spawn a separate container to probe the target IP.
cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null || true)
if [ -n "$cip" ]; then
  if docker run --rm --label "$SMOKE_RUN_LABEL" "$IMAGE" wget -q -O /dev/null "http://$cip/healthz" 2>/dev/null; then
    fail "/healthz reachable from another container ($cip) — must be denied"
  else
    pass "/healthz denied from external client ($cip)"
  fi
else
  fail "could not determine container IP to probe /healthz externally"
fi
# Exactly one active access_log to /dev/stdout (regression: double access_log).
n=$(dump_conf "$cid" | grep -c 'access_log /dev/stdout' || true)
assert_eq "$n" "1" "exactly one access_log directive (default logfmt)"
docker rm -f "$cid" >/dev/null

# --- 2. gzip toggle ---------------------------------------------------------
cid=$(start -e ANGIE_GZIP_ENABLED=1)
wait_healthy "$cid" || fail "gzip container healthy"
assert_contains "$(dump_conf "$cid")" "gzip on" "ANGIE_GZIP_ENABLED enables gzip"
docker rm -f "$cid" >/dev/null

# --- 3. brotli toggle (module + config) ------------------------------------
cid=$(start -e ANGIE_BROTLI_ENABLED=1)
wait_healthy "$cid" || fail "brotli container healthy"
assert_contains "$(dump_conf "$cid")" "brotli on" "ANGIE_BROTLI_ENABLED enables brotli"
mods=$(docker exec "$cid" ls /etc/angie/modules.d/ 2>/dev/null || true)
assert_contains "$mods" "http_brotli_filter.conf" "brotli filter module enabled"
docker rm -f "$cid" >/dev/null

# --- 4. GeoIP2 graceful skip when DB path is missing ------------------------
cid=$(start -e GEOIP2_DB_COUNTRY=/nonexistent/Country.mmdb)
if wait_healthy "$cid"; then
  pass "missing GeoIP DB does not break startup"
else
  fail "missing GeoIP DB does not break startup"
fi
docker rm -f "$cid" >/dev/null

# --- 4b. GeoIP2 path charset validation: a *readable* DB whose path holds an
#     unsafe character (here a space) must be rejected, aborting startup, not
#     silently substituted into the config (injection guard in 50-geoip2.sh).
#     The readability check in that script runs first, so the probe file must
#     exist for the charset branch to be exercised.
tmp=$(mktemp -d)
tmpdirs="$tmpdirs $tmp"
: >"$tmp/db evil.mmdb"
chmod a+r "$tmp/db evil.mmdb"
set +e
timeout 30 docker run --rm --label "$SMOKE_RUN_LABEL" -v "$tmp:/geo:ro" \
  -e GEOIP2_DB_COUNTRY='/geo/db evil.mmdb' "$IMAGE" >/dev/null 2>&1
rc=$?
set -e
rm -rf "$tmp"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
  pass "GeoIP2 rejects an unsafe DB path charset (exit $rc)"
else
  fail "GeoIP2 rejects an unsafe DB path charset (got exit $rc; 124=timeout means it started anyway)"
fi

# --- 4c. Static precompression variants -------------------------------------
cid=$(start -e ANGIE_GZIP_STATIC_ENABLED=1)
wait_healthy "$cid" || fail "gzip_static container healthy"
assert_contains "$(dump_conf "$cid")" "gzip_static on" "ANGIE_GZIP_STATIC_ENABLED enables gzip_static"
docker rm -f "$cid" >/dev/null

cid=$(start -e ANGIE_BROTLI_STATIC_ENABLED=1)
wait_healthy "$cid" || fail "brotli_static container healthy"
conf=$(dump_conf "$cid")
assert_contains "$conf" "brotli_static on" "ANGIE_BROTLI_STATIC_ENABLED enables brotli_static"
assert_contains "$conf" "brotli on" "brotli_static also pulls in base brotli"
docker rm -f "$cid" >/dev/null

# --- 4d. Independent module/map toggles loaded together ---------------------
# ModSecurity and subs are bare load_module; the websocket map is an http snippet.
# They compose without conflict, so one container exercises all three with
# independent assertions.
cid=$(start -e ANGIE_MODSECURITY_ENABLED=1 -e ANGIE_SUBS_ENABLED=1 -e ANGIE_MAP_WEBSOCKET_ENABLED=1)
if wait_healthy "$cid"; then
  pass "WAF + subs + websocket: container starts with all three enabled"
else
  fail "WAF + subs + websocket: container starts with all three enabled"
  docker logs "$cid" 2>&1 | grep -iE 'emerg|\[error\]' | head -3 || true
fi
mods=$(docker exec "$cid" ls /etc/angie/modules.d/ 2>/dev/null || true)
assert_contains "$mods" "http_modsecurity.conf" "ANGIE_MODSECURITY_ENABLED loads the WAF module"
assert_contains "$mods" "http_subs_filter.conf" "ANGIE_SUBS_ENABLED loads the subs module"
assert_contains "$(dump_conf "$cid")" "connection_upgrade" "ANGIE_MAP_WEBSOCKET_ENABLED adds the websocket map"
docker rm -f "$cid" >/dev/null

# --- 4e. Access-log format switch keeps exactly one access_log --------------
# Regression guard for double access_log when a non-default format is selected.
# logfmt is the default and is matched before main in 40-log.sh, so it must be
# turned off explicitly for main to win.
cid=$(start -e ANGIE_LOG_LOGFMT=no -e ANGIE_LOG_MAIN=1)
wait_healthy "$cid" || fail "log-main container healthy"
conf=$(dump_conf "$cid")
n=$(printf '%s\n' "$conf" | grep -c 'access_log /dev/stdout' || true)
assert_eq "$n" "1" "switching to main format keeps exactly one access_log"
assert_contains "$conf" "access_log /dev/stdout main" "ANGIE_LOG_MAIN selects the main format"
docker rm -f "$cid" >/dev/null

# --- 4f. worker_processes autotune rewrites `auto` to a concrete count -------
cid=$(start -e ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE=1)
wait_healthy "$cid" || fail "autotune container healthy"
wp=$(docker exec "$cid" grep -E '^worker_processes [0-9]+;' /etc/angie/angie.conf 2>/dev/null || true)
if [ -n "$wp" ]; then
  pass "autotune rewrites worker_processes to a number ($wp)"
else
  fail "autotune rewrites worker_processes to a concrete count"
fi
docker rm -f "$cid" >/dev/null

# --- 4g. Custom volume: a user vhost mounted under /etc/angie/custom applies -
# Exercises the parallel custom/ include convention (angie.conf includes both the
# baked tree and /etc/angie/custom/...). A mounted server must reach angie -T.
ctmp=$(mktemp -d)
tmpdirs="$tmpdirs $ctmp"
cat >"$ctmp/zz-custom.conf" <<'CONF'
server {
  listen 80;
  server_name custom.smoke.test;
  location = /_custom_marker { return 200 "marker\n"; }
}
CONF
cid=$(start -v "$ctmp:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "custom-volume container healthy"
assert_contains "$(dump_conf "$cid")" "custom.smoke.test" \
  "custom volume vhost is included in the effective config"
docker rm -f "$cid" >/dev/null
rm -rf "$ctmp"

# --- 4h. zstd toggle (module + config) -------------------------------------
cid=$(start -e ANGIE_ZSTD_ENABLED=1)
wait_healthy "$cid" || fail "zstd container healthy"
assert_contains "$(dump_conf "$cid")" "zstd on" "ANGIE_ZSTD_ENABLED enables zstd"
mods=$(docker exec "$cid" ls /etc/angie/modules.d/ 2>/dev/null || true)
assert_contains "$mods" "http_zstd_filter.conf" "zstd filter module enabled"
docker rm -f "$cid" >/dev/null

cid=$(start -e ANGIE_ZSTD_STATIC_ENABLED=1)
wait_healthy "$cid" || fail "zstd_static container healthy"
conf=$(dump_conf "$cid")
assert_contains "$conf" "zstd_static on" "ANGIE_ZSTD_STATIC_ENABLED enables zstd_static"
assert_contains "$conf" "zstd on" "zstd_static also pulls in base zstd"
mods=$(docker exec "$cid" ls /etc/angie/modules.d/ 2>/dev/null || true)
assert_contains "$mods" "http_zstd_static.conf" "zstd static module enabled"
docker rm -f "$cid" >/dev/null

# --- 4i. Real-IP: trusted proxy renders set_real_ip_from, healthz still up --
cid=$(start -e ANGIE_REAL_IP_FROM=10.0.0.0/8)
wait_healthy "$cid" || fail "real-ip container healthy"
conf=$(dump_conf "$cid")
assert_contains "$conf" "set_real_ip_from 10.0.0.0/8" "ANGIE_REAL_IP_FROM renders the trusted proxy"
assert_contains "$conf" "real_ip_header X-Forwarded-For" "real_ip_header defaults to X-Forwarded-For"
assert_contains "$conf" "real_ip_recursive on" "real_ip_recursive defaults to on"
# /healthz must keep answering: the HEALTHCHECK hits 127.0.0.1 with no XFF, so
# real-IP performs no rewrite and the loopback gate still passes.
body=$(docker exec "$cid" wget -q -O - http://127.0.0.1/healthz 2>/dev/null || true)
assert_eq "$body" "ok" "real-ip enabled: /healthz still returns 'ok'"
docker rm -f "$cid" >/dev/null

# --- 4i'. Real-IP charset guard: an unsafe entry aborts startup -------------
# Mirrors the GeoIP2 injection guard: a value with a character outside the
# IP/CIDR charset must be rejected, not substituted into the config.
set +e
timeout 30 docker run --rm --label "$SMOKE_RUN_LABEL" -e 'ANGIE_REAL_IP_FROM=10.0.0.0/8;evil' "$IMAGE" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
  pass "real-ip rejects an unsafe ANGIE_REAL_IP_FROM entry (exit $rc)"
else
  fail "real-ip rejects an unsafe ANGIE_REAL_IP_FROM entry (got exit $rc; 124=timeout means it started anyway)"
fi

# --- 4j. Security headers toggle -------------------------------------------
cid=$(start -e ANGIE_SECURITY_HEADERS_ENABLED=1)
wait_healthy "$cid" || fail "security-headers container healthy"
conf=$(dump_conf "$cid")
assert_contains "$conf" 'add_header X-Content-Type-Options "nosniff" always' \
  "ANGIE_SECURITY_HEADERS_ENABLED adds the nosniff header"
assert_contains "$conf" "Referrer-Policy" "security headers include Referrer-Policy"
assert_contains "$conf" "X-Frame-Options" "security headers include X-Frame-Options"
assert_contains "$conf" "Permissions-Policy" "security headers include Permissions-Policy"
docker rm -f "$cid" >/dev/null

# --- 4k. geoip2 log-format orphan self-heals when geoip2 is off -------------
# A geoip2 log format left active by a prior run (persistent /etc/angie volume)
# references $geoip2_country_code, which only exists with geoip2 up. angie
# validates every log_format, so the orphan breaks `angie -t` for the whole
# config. 40-log must clear it before selecting a log. Inject the real orphan
# `enable_log` would leave -- the PAIR (030 format + 040 access_log) -- re-run
# 40-log.sh (simulating the next start), and confirm the config is valid again
# and BOTH symlinks are gone (a dangling 040 access_log on a removed format
# would itself break startup).
cid=$(start)
wait_healthy "$cid" || fail "orphan-heal container healthy"
link_active "$cid" ../http-conf-available.d/030-log-format-logfmt-with-geoip2.conf \
  /etc/angie/http-conf.d/030-log-format-logfmt-with-geoip2.conf
link_active "$cid" ../http-conf-available.d/040-log-logfmt-with-geoip2.conf \
  /etc/angie/http-conf.d/040-log-logfmt-with-geoip2.conf
if docker exec "$cid" angie -t >/dev/null 2>&1; then
  fail "sanity: orphaned geoip2 log format should break angie -t"
else
  pass "sanity: orphaned geoip2 log format breaks angie -t"
fi
docker exec "$cid" sh /docker-entrypoint.d/40-log.sh >/dev/null 2>&1 || true
if docker exec "$cid" angie -t >/dev/null 2>&1; then
  pass "40-log.sh disables the geoip2 orphan, angie -t valid again"
else
  fail "40-log.sh did not heal the geoip2 orphan"
fi
assert_disabled "$cid" "geoip2 log-format + access_log orphans removed" \
  logfmt-with-geoip2.conf /etc/angie/http-conf.d/
docker rm -f "$cid" >/dev/null

# --- 4l. geoip2 map/module orphan self-heals when geoip2 is off -------------
# Sibling of 4k: the geoip2 map (025) + load_module left active by a prior run
# also survive on a persistent volume. The map bakes in the DB path and angie
# opens the mmdb at config load, so an orphaned map pointing at a now-gone DB
# fails `angie -t`. 50-geoip2.sh must clear map+module before its early exits.
cid=$(start)
wait_healthy "$cid" || fail "geoip2 map orphan-heal container healthy"
docker exec "$cid" sh -c '
  printf "geoip2 /nonexistent/GeoLite2-Country.mmdb {\n  auto_reload 1h;\n  \$geoip2_country_code default=ZZ source=\$remote_addr country iso_code;\n}\n" \
    > /etc/angie/http-conf-available.d/025-geoip2.conf
  ln -sf ../http-conf-available.d/025-geoip2.conf /etc/angie/http-conf.d/025-geoip2.conf
  ln -sf ../modules-available.d/http_geoip2.conf /etc/angie/modules.d/http_geoip2.conf
'
if docker exec "$cid" angie -t >/dev/null 2>&1; then
  fail "sanity: orphaned geoip2 map (gone DB) should break angie -t"
else
  pass "sanity: orphaned geoip2 map breaks angie -t"
fi
# No GEOIP2_DB_COUNTRY in env: 50-geoip2.sh must clear the orphan, then early-exit.
docker exec "$cid" sh /docker-entrypoint.d/50-geoip2.sh >/dev/null 2>&1 || true
if docker exec "$cid" angie -t >/dev/null 2>&1; then
  pass "50-geoip2.sh disables the map/module orphan, angie -t valid again"
else
  fail "50-geoip2.sh did not heal the geoip2 map orphan"
fi
assert_disabled "$cid" "geoip2 map orphan removed" \
  025-geoip2.conf /etc/angie/http-conf.d/
assert_disabled "$cid" "geoip2 module orphan removed" \
  http_geoip2.conf /etc/angie/modules.d/
docker rm -f "$cid" >/dev/null

# --- 4m. real-ip orphan is cleared when ANGIE_REAL_IP_FROM is removed --------
# A 015-real-ip.conf left active by a prior run keeps trusting a stale
# set_real_ip_from list on a persistent volume. Core realip directives never
# break `angie -t`, so assert on the symlink, not on the config test: starting
# without ANGIE_REAL_IP_FROM must leave the orphan disabled.
cid=$(start)
wait_healthy "$cid" || fail "real-ip orphan-heal container healthy"
docker exec "$cid" sh -c '
  printf "real_ip_header X-Forwarded-For;\nset_real_ip_from 203.0.113.0/24;\n" \
    > /etc/angie/http-conf-available.d/015-real-ip.conf
  ln -sf ../http-conf-available.d/015-real-ip.conf /etc/angie/http-conf.d/015-real-ip.conf
'
docker exec "$cid" sh /docker-entrypoint.d/35-real-ip.sh >/dev/null 2>&1 || true
assert_disabled "$cid" "35-real-ip.sh clears the stale trusted-proxy orphan" \
  015-real-ip.conf /etc/angie/http-conf.d/
docker rm -f "$cid" >/dev/null

# --- 4n. declarative reset: brotli config + module orphan cleared when off ---
# Representative of the conf+module reset path. A brotli config + module left
# active by a prior run must be cleared when ANGIE_BROTLI_* is no longer set, so
# the feature does not stay stuck on across restarts. Inject the pair, run
# 40-brotli.sh with no env, confirm both symlinks are gone and angie -t valid.
cid=$(start)
wait_healthy "$cid" || fail "brotli reset container healthy"
link_active "$cid" ../http-conf-available.d/020-brotli.conf \
  /etc/angie/http-conf.d/020-brotli.conf
link_active "$cid" ../modules-available.d/http_brotli_filter.conf \
  /etc/angie/modules.d/http_brotli_filter.conf
docker exec "$cid" sh /docker-entrypoint.d/40-brotli.sh >/dev/null 2>&1 || true
assert_disabled "$cid" "40-brotli.sh resets the brotli config orphan" \
  020-brotli.conf /etc/angie/http-conf.d/
assert_disabled "$cid" "40-brotli.sh resets the brotli module orphan" \
  http_brotli_filter.conf /etc/angie/modules.d/
if docker exec "$cid" angie -t >/dev/null 2>&1; then
  pass "config valid after brotli reset"
else
  fail "config invalid after brotli reset"
fi
docker rm -f "$cid" >/dev/null

# --- 4o. full startup tolerates a geoip2 orphan with an earlier toggle on -----
# Regression guard for the real ordering. The geoip2 orphan cleanup lives in
# 40-log/50-geoip2, but EARLIER toggles (40-brotli, 40-gzip) enable their own
# snippets first. While angie-ctl validated per enable, 40-gzip ran `angie -t`
# with the orphan still active and aborted startup before 40-log could clear it
# -- so 4k/4l (which heal in isolation) passed while real startup still broke.
# Toggles now mutate without a per-call config test and the entrypoint validates once at the end
# (see docker-entrypoint.sh), making the transient orphan harmless. Inject the
# orphan, replay the WHOLE entrypoint config phase with gzip on, and confirm no
# script aborts and the assembled config is valid.
cid=$(start -e ANGIE_GZIP_ENABLED=1)
wait_healthy "$cid" || fail "full-startup orphan container healthy"
link_active "$cid" ../http-conf-available.d/030-log-format-logfmt-with-geoip2.conf \
  /etc/angie/http-conf.d/030-log-format-logfmt-with-geoip2.conf
link_active "$cid" ../http-conf-available.d/040-log-logfmt-with-geoip2.conf \
  /etc/angie/http-conf.d/040-log-logfmt-with-geoip2.conf
if docker exec "$cid" angie -t >/dev/null 2>&1; then
  fail "sanity: injected geoip2 orphan should break angie -t"
else
  pass "sanity: injected geoip2 orphan breaks angie -t"
fi
# Replay every NN-*.sh in glob (== numeric) order, as a restart on a persistent
# /etc/angie volume would, with ANGIE_GZIP_ENABLED still set. `set -e` makes an
# aborting toggle (the old 40-gzip failure) fail this step.
if docker exec "$cid" sh -c 'set -e; for f in /docker-entrypoint.d/*.sh; do [ -x "$f" ] || continue; "$f" >/dev/null; done'; then
  pass "full entrypoint replay completes with gzip on (no early toggle trips on the orphan)"
else
  fail "full entrypoint replay aborted (an early toggle tripped over the geoip2 orphan)"
fi
if docker exec "$cid" angie -t >/dev/null 2>&1; then
  pass "assembled config valid after full replay; orphan cleared, gzip on"
else
  fail "assembled config invalid after full replay"
fi
assert_contains "$(dump_conf "$cid")" "gzip on" "gzip still enabled after full replay"
assert_disabled "$cid" "geoip2 orphan removed by full replay" \
  logfmt-with-geoip2.conf /etc/angie/http-conf.d/
docker rm -f "$cid" >/dev/null

# --- 4p. declarative reset: brotli stays on when its variable is set ---------
# The reset must not break the happy path: with ANGIE_BROTLI_ENABLED set,
# 40-brotli.sh re-enables config + module after the initial reset.
cid=$(start -e ANGIE_BROTLI_ENABLED=1)
wait_healthy "$cid" || fail "brotli enabled container healthy"
en=$(docker exec "$cid" sh -c 'ls /etc/angie/http-conf.d/ /etc/angie/modules.d/ 2>/dev/null' || true)
assert_contains "$en" 020-brotli.conf \
  "40-brotli.sh re-enables brotli when ANGIE_BROTLI_ENABLED is set"
docker rm -f "$cid" >/dev/null

# --- 5. Entrypoint fail-fast: a failing config script stops the container ---
tmp=$(mktemp -d)
tmpdirs="$tmpdirs $tmp"
printf '#!/bin/sh\nexit 7\n' >"$tmp/99-zz-fail.sh"
chmod +x "$tmp/99-zz-fail.sh"
set +e
timeout 30 docker run --rm --label "$SMOKE_RUN_LABEL" \
  -v "$tmp/99-zz-fail.sh:/docker-entrypoint.d/99-zz-fail.sh:ro" "$IMAGE" >/dev/null 2>&1
rc=$?
set -e
rm -rf "$tmp"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
  pass "failing entrypoint script aborts startup (exit $rc)"
else
  fail "failing entrypoint script aborts startup (got exit $rc; 124=timeout means it started anyway)"
fi

# --- 6. Non-root: the default image refuses to start (requires root) --------
# The default image binds :80 and uses root-owned pid/temp paths, so it cannot
# run under --user. The entrypoint must fail fast with a clear message instead of
# letting angie crash later with an opaque EACCES. (Rootless = unprivileged image.)
set +e
logs=$(docker run --rm --label "$SMOKE_RUN_LABEL" --user 1000:1000 "$IMAGE" 2>&1)
rc=$?
set -e
assert_contains "$logs" "requires root" \
  "non-root: entrypoint fails fast with a clear 'requires root' message"
if [ "$rc" -ne 0 ]; then
  pass "non-root: default image refuses to start (exit $rc)"
else
  fail "non-root: default image refuses to start (got exit 0)"
fi

# --- 7. Runtime Angie version matches the Dockerfile pin ---------------------
# The image pins ANGIE_VERSION as a Dockerfile ARG, but the package actually
# installed comes from the upstream repository at build time. Assert the binary
# agrees with the pin (and that both variants pin the same version), so a
# drifted pin -- or a repository serving something other than the pin -- fails
# loudly here instead of surfacing as a subtle behavior change.
repo_root=$(cd "$(dirname "$0")/.." && pwd)
pin_alpine=$(sed -n 's/^ARG ANGIE_VERSION=//p' "$repo_root/alpine/Dockerfile")
pin_debian=$(sed -n 's/^ARG ANGIE_VERSION=//p' "$repo_root/debian/Dockerfile")
assert_eq "$pin_debian" "$pin_alpine" "alpine and debian Dockerfiles pin the same ANGIE_VERSION"
runtime_ver=$(docker run --rm --label "$SMOKE_RUN_LABEL" "$IMAGE" angie -v 2>&1 || true)
assert_contains "$runtime_ver" "Angie/$pin_alpine" \
  "runtime angie version matches the Dockerfile pin ($pin_alpine)"

# --- 8. angie-ctl CLI contract: en/dis roundtrip ------------------------------
# angie-ctl is external code pinned by commit, and its upstream history has been
# rewritten before, silently changing the CLI (the --no-test removal broke every
# toggle). Exercise the exact subcommands the entrypoint relies on, so a
# contract change fails with a precise message instead of a wall of unrelated
# "container not healthy" failures.
cid=$(start)
wait_healthy "$cid" || fail "angie-ctl contract container healthy"
if docker exec "$cid" angie-ctl httpconf en 060-map-websocket.conf >/dev/null 2>&1 &&
  docker exec "$cid" test -e /etc/angie/http-conf.d/060-map-websocket.conf; then
  pass "angie-ctl httpconf en creates the active symlink"
else
  fail "angie-ctl httpconf en creates the active symlink"
fi
if docker exec "$cid" angie-ctl httpconf dis 060-map-websocket.conf >/dev/null 2>&1 &&
  ! docker exec "$cid" test -e /etc/angie/http-conf.d/060-map-websocket.conf; then
  pass "angie-ctl httpconf dis removes the active symlink"
else
  fail "angie-ctl httpconf dis removes the active symlink"
fi
if docker exec "$cid" angie-ctl mod en http_subs_filter.conf >/dev/null 2>&1 &&
  docker exec "$cid" test -e /etc/angie/modules.d/http_subs_filter.conf; then
  pass "angie-ctl mod en creates the module symlink"
else
  fail "angie-ctl mod en creates the module symlink"
fi
if docker exec "$cid" angie-ctl mod dis http_subs_filter.conf >/dev/null 2>&1 &&
  ! docker exec "$cid" test -e /etc/angie/modules.d/http_subs_filter.conf; then
  pass "angie-ctl mod dis removes the module symlink"
else
  fail "angie-ctl mod dis removes the module symlink"
fi
assert_contains "$(docker exec "$cid" angie-ctl httpconf ls-available 2>/dev/null || true)" \
  "020-gzip.conf" "angie-ctl httpconf ls-available lists shipped snippets"
docker rm -f "$cid" >/dev/null

# --- 9. Compression is applied on the wire, not just configured --------------
# "gzip on" in `angie -T` proves the directive, not the behavior -- a dynamic
# module can load and still never compress. Serve a 4 KiB text/plain body (well
# above every *_min_length 128) from a custom vhost on :8080 and assert on the
# actual response bytes. busybox wget cannot show response headers, so the
# assertions use content magic (gzip/zstd) and size (brotli has no magic).
ctmp=$(mktemp -d)
tmpdirs="$tmpdirs $ctmp"
head -c 4096 /dev/zero | tr '\0' 'a' >"$ctmp/big.txt"
cat >"$ctmp/vhost.conf" <<'CONF'
server {
  listen 8080;
  root /etc/angie/custom/http.d;
}
CONF
# mktemp -d creates the dir 0700; the angie workers (user angie) must traverse
# it to serve the static file, unlike 4g where only the root-run master reads
# the mounted conf.
chmod 755 "$ctmp"
cid=$(start -e ANGIE_GZIP_ENABLED=1 -e ANGIE_BROTLI_ENABLED=1 -e ANGIE_ZSTD_ENABLED=1 \
  -v "$ctmp:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "compression container healthy"
plain=$(docker exec "$cid" sh -c \
  'wget -q -O /tmp/plain http://127.0.0.1:8080/big.txt && wc -c </tmp/plain' || true)
assert_eq "$((plain))" "4096" "control fetch without Accept-Encoding is uncompressed (4096 bytes)"
magic=$(docker exec "$cid" sh -c \
  'wget -q -O /tmp/gz --header "Accept-Encoding: gzip" http://127.0.0.1:8080/big.txt \
    && od -An -tx1 -N2 /tmp/gz' | tr -d ' \n' || true)
assert_eq "$magic" "1f8b" "Accept-Encoding: gzip gets a gzip body (magic 1f8b)"
magic=$(docker exec "$cid" sh -c \
  'wget -q -O /tmp/zst --header "Accept-Encoding: zstd" http://127.0.0.1:8080/big.txt \
    && od -An -tx1 -N4 /tmp/zst' | tr -d ' \n' || true)
assert_eq "$magic" "28b52ffd" "Accept-Encoding: zstd gets a zstd body (magic 28b52ffd)"
brsize=$(docker exec "$cid" sh -c \
  'wget -q -O /tmp/br --header "Accept-Encoding: br" http://127.0.0.1:8080/big.txt \
    && wc -c </tmp/br' || true)
if [ -n "$brsize" ] && [ "$((brsize))" -gt 0 ] && [ "$((brsize))" -lt 4096 ]; then
  pass "Accept-Encoding: br gets a compressed body ($((brsize)) < 4096 bytes)"
else
  fail "Accept-Encoding: br gets a compressed body (got '${brsize:-empty}' bytes)"
fi
docker rm -f "$cid" >/dev/null
rm -rf "$ctmp"

# --- 10. ModSecurity actually blocks a matching request ----------------------
# 4d only proves the module loads. Engage it: an inline rule denies
# ?probe=attack with 403. The rule runs in phase 1 and the target is a static
# file on purpose -- a `return` in the vhost would answer from the rewrite
# phase, BEFORE ModSecurity runs, and silently bypass the WAF.
wtmp=$(mktemp -d)
tmpdirs="$tmpdirs $wtmp"
printf 'waf-ok\n' >"$wtmp/probe.txt"
cat >"$wtmp/vhost.conf" <<'CONF'
server {
  listen 8081;
  root /etc/angie/custom/http.d;
  modsecurity on;
  modsecurity_rules 'SecRuleEngine On';
  modsecurity_rules 'SecRule ARGS:probe "@streq attack" "id:900100,phase:1,deny,status:403"';
}
CONF
chmod 755 "$wtmp" # see section 9: workers must traverse the mounted docroot
cid=$(start -e ANGIE_MODSECURITY_ENABLED=1 -v "$wtmp:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "modsecurity container healthy"
body=$(docker exec "$cid" wget -q -O - http://127.0.0.1:8081/probe.txt 2>/dev/null || true)
assert_eq "$body" "waf-ok" "benign request passes through ModSecurity"
if docker exec "$cid" wget -q -O /dev/null 'http://127.0.0.1:8081/probe.txt?probe=attack' 2>/dev/null; then
  fail "ModSecurity denies the matching request (expected 403)"
else
  pass "ModSecurity denies the matching request (403)"
fi
docker rm -f "$cid" >/dev/null
rm -rf "$wtmp"

# --- 11. Security headers are emitted on real responses ----------------------
# 4j asserts the add_header directives exist in the config text; whether they
# reach the client is a separate question (add_header is inheritance-fragile:
# any add_header in a vhost replaces the whole inherited set). busybox wget
# cannot show response headers, so capture them via $sent_http_* in a custom
# log format -- which also exercises the custom/http-conf.d include layer.
htmp=$(mktemp -d)
hconf=$(mktemp -d)
tmpdirs="$tmpdirs $htmp $hconf"
printf 'hdr-ok\n' >"$htmp/probe.txt"
cat >"$htmp/vhost.conf" <<'CONF'
server {
  listen 8082;
  root /etc/angie/custom/http.d;
  access_log /dev/stdout hdrprobe;
}
CONF
cat >"$hconf/00-hdrprobe.conf" <<'CONF'
log_format hdrprobe 'hdrprobe'
  ' xcto=$sent_http_x_content_type_options'
  ' xfo=$sent_http_x_frame_options'
  ' rp=$sent_http_referrer_policy'
  ' pp="$sent_http_permissions_policy"';
CONF
chmod 755 "$htmp" "$hconf" # see section 9: workers must traverse the docroot
cid=$(start -e ANGIE_SECURITY_HEADERS_ENABLED=1 \
  -v "$htmp:/etc/angie/custom/http.d:ro" -v "$hconf:/etc/angie/custom/http-conf.d:ro")
wait_healthy "$cid" || fail "security-headers wire container healthy"
docker exec "$cid" wget -q -O /dev/null http://127.0.0.1:8082/probe.txt 2>/dev/null || true
hdrline=$(wait_logs "$cid" "hdrprobe " | grep '^hdrprobe ' | tail -1 || true)
assert_contains "$hdrline" "xcto=nosniff" "wire: X-Content-Type-Options reaches the client"
assert_contains "$hdrline" "xfo=SAMEORIGIN" "wire: X-Frame-Options reaches the client"
assert_contains "$hdrline" "rp=strict-origin-when-cross-origin" "wire: Referrer-Policy reaches the client"
assert_contains "$hdrline" 'pp="camera=(), microphone=(), geolocation=()"' \
  "wire: Permissions-Policy reaches the client"
docker rm -f "$cid" >/dev/null
rm -rf "$htmp" "$hconf"

# --- 12. Access log reaches `docker logs` ------------------------------------
# The whole logging chain: access_log /dev/stdout -> angie -> tini -> container
# stdout. /healthz has access_log off, so probe / (444; the closed connection is
# still logged) and expect a logfmt line on stdout.
cid=$(start)
wait_healthy "$cid" || fail "access-log container healthy"
docker exec "$cid" wget -q -O /dev/null http://127.0.0.1/ 2>/dev/null || true
stdout_logs=$(wait_logs "$cid" "status=444")
assert_contains "$stdout_logs" "status=444" "access log line for the denied request reaches docker logs"
assert_contains "$stdout_logs" "remote_addr=127.0.0.1" "access log line carries remote_addr in logfmt"
docker rm -f "$cid" >/dev/null

# --- 13. Real-IP rewrites $remote_addr from a trusted proxy ------------------
# 4i checks the rendered directives; this checks the effect. The client
# container's bridge IP falls in the trusted RFC1918 ranges, so its
# X-Forwarded-For must become $remote_addr in the access log. TEST-NET-3
# (203.0.113.0/24) can never appear as a real peer address, so seeing it logged
# proves the rewrite happened.
cid=$(start -e ANGIE_REAL_IP_FROM=172.16.0.0/12,192.168.0.0/16,10.0.0.0/8)
wait_healthy "$cid" || fail "real-ip wire container healthy"
cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null || true)
if [ -n "$cip" ]; then
  timeout 30 docker run --rm --label "$SMOKE_RUN_LABEL" "$IMAGE" wget -q -O /dev/null \
    --header 'X-Forwarded-For: 203.0.113.7' "http://$cip/" 2>/dev/null || true
  assert_contains "$(wait_logs "$cid" "remote_addr=203.0.113.7")" "remote_addr=203.0.113.7" \
    "trusted proxy's X-Forwarded-For rewrites the logged remote_addr"
else
  fail "could not determine container IP for the real-ip wire test"
fi
docker rm -f "$cid" >/dev/null

# --- 14. Persistent /etc/angie volume: feature off after recreate ------------
# End-to-end version of the 4k-4n orphan drills: a NAMED volume is populated
# from the image on first use and then outlives the container. Enable brotli in
# run one; recreate without the variable and the declarative reset must turn it
# back off -- the volume equivalent of "removing the env var disables the
# feature".
vol="angie-smoke-$$"
docker volume create "$vol" >/dev/null
vols="$vols $vol"
cid=$(start -v "$vol:/etc/angie" -e ANGIE_BROTLI_ENABLED=1)
wait_healthy "$cid" || fail "persistent-volume first run healthy"
assert_contains "$(dump_conf "$cid")" "brotli on" "persistent volume: first run enables brotli"
docker rm -f "$cid" >/dev/null
cid=$(start -v "$vol:/etc/angie")
if wait_healthy "$cid"; then
  pass "persistent volume: recreate without the variable stays healthy"
else
  fail "persistent volume: recreate without the variable stays healthy"
fi
assert_disabled "$cid" "persistent volume: brotli is off again after recreate" \
  020-brotli.conf /etc/angie/http-conf.d/
docker rm -f "$cid" >/dev/null
docker volume rm "$vol" >/dev/null 2>&1 || true

# --- 15. Graceful shutdown: docker stop is fast and exits 0 ------------------
# tini must forward SIGTERM to the angie master (fast shutdown, exit 0). A
# broken signal path surfaces as the 10s docker kill timeout and exit 137.
cid=$(start)
wait_healthy "$cid" || fail "graceful-stop container healthy"
stop_start=$(date +%s)
docker stop -t 10 "$cid" >/dev/null
stop_elapsed=$(($(date +%s) - stop_start))
stop_rc=$(docker inspect -f '{{.State.ExitCode}}' "$cid")
if [ "$stop_rc" = "0" ] && [ "$stop_elapsed" -le 5 ]; then
  pass "docker stop: SIGTERM shuts angie down cleanly (exit 0 in ${stop_elapsed}s)"
else
  fail "docker stop: expected exit 0 within 5s, got exit $stop_rc in ${stop_elapsed}s"
fi
docker rm -f "$cid" >/dev/null

# --- 16. angie -s reload keeps the server serving ----------------------------
cid=$(start)
wait_healthy "$cid" || fail "reload container healthy"
if docker exec "$cid" angie -s reload 2>/dev/null; then
  pass "angie -s reload accepted"
else
  fail "angie -s reload accepted"
fi
sleep 1
body=$(docker exec "$cid" wget -q -O - http://127.0.0.1/healthz 2>/dev/null || true)
assert_eq "$body" "ok" "/healthz still answers after reload"
docker rm -f "$cid" >/dev/null

# --- 17. The image HEALTHCHECK itself reports healthy ------------------------
# wait_healthy probes /healthz directly; this exercises Docker's own health
# machinery (the HEALTHCHECK wget CMD baked into the image). The 30s default
# interval would stall the suite, so tighten it at run time.
cid=$(start --health-interval=1s --health-start-period=2s)
hc_status=starting
for _ in $(seq 1 40); do
  hc_status=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || true)
  [ "$hc_status" = "healthy" ] && break
  sleep 0.5
done
assert_eq "$hc_status" "healthy" "docker HEALTHCHECK reports healthy"
docker rm -f "$cid" >/dev/null

# --- 18. ANGIE_ENTRYPOINT_QUIET_LOGS silences the entrypoint ------------------
cid=$(start -e ANGIE_ENTRYPOINT_QUIET_LOGS=1)
wait_healthy "$cid" || fail "quiet-logs container healthy"
n=$(docker logs "$cid" 2>&1 | grep -c 'entrypoint:' || true)
assert_eq "$n" "0" "no entrypoint log lines with ANGIE_ENTRYPOINT_QUIET_LOGS=1"
docker rm -f "$cid" >/dev/null

# --- 19. Non-executable .sh in /docker-entrypoint.d is skipped with a warning -
# The dropped file would exit 7 IF executed (and the section-5 fail-fast would
# then abort startup), so a healthy container proves it was skipped, not run.
ntmp=$(mktemp -d)
tmpdirs="$tmpdirs $ntmp"
printf '#!/bin/sh\nexit 7\n' >"$ntmp/99-zz-noexec.sh"
chmod 644 "$ntmp/99-zz-noexec.sh"
cid=$(start -v "$ntmp/99-zz-noexec.sh:/docker-entrypoint.d/99-zz-noexec.sh:ro")
if wait_healthy "$cid"; then
  pass "container starts despite a non-executable config script"
else
  fail "container starts despite a non-executable config script"
fi
assert_contains "$(docker logs "$cid" 2>&1)" "not executable" \
  "non-executable script is reported with a warning"
docker rm -f "$cid" >/dev/null
rm -rf "$ntmp"

# --- 20. A non-angie command skips the config phase ---------------------------
# docker-entrypoint.sh gates the whole toggle/validate phase on $1 being
# angie/angie-debug; any other command must exec straight through, quietly.
# `sh -c`, not bare `echo`: the entrypoint's executability check resolves $1
# with `command -v`, and for a shell BUILTIN that returns the bare name, which
# fails the -x test -- sh resolves to a real path.
out=$(docker run --rm --label "$SMOKE_RUN_LABEL" "$IMAGE" sh -c 'echo config-phase-skipped' 2>&1 || true)
assert_eq "$out" "config-phase-skipped" "non-angie CMD execs directly with no entrypoint output"

# --- 21. Autotune derives the worker count from the cgroup CPU quota ---------
# 4f proves "auto becomes a number"; this pins the number to the quota:
# --cpus=1.5 must round up to 2 workers. The script takes the minimum of quota
# and online CPUs, so this needs a host with >=2 cores -- skip below that
# rather than fail. nproc, not getconf: busybox ships the former only.
if [ "$(nproc)" -ge 2 ]; then
  cid=$(start --cpus=1.5 -e ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE=1)
  wait_healthy "$cid" || fail "autotune quota container healthy"
  wp=$(docker exec "$cid" grep -E '^worker_processes' /etc/angie/angie.conf 2>/dev/null || true)
  assert_eq "$wp" "worker_processes 2;" "--cpus=1.5 rounds up to worker_processes 2"
  docker rm -f "$cid" >/dev/null
else
  printf '  skip autotune quota assertion (single-CPU host)\n'
fi

printf '\n%d test(s), %d failure(s)\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
