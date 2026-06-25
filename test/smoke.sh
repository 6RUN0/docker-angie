#!/usr/bin/env bash
# Smoke tests for a built Angie image. Drives the container with various ANGIE_*
# toggles and asserts the effective configuration / runtime behavior.
#
# Usage: IMAGE=angie-alpine ./test/smoke.sh
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE=<image:tag>}"

tests=0
fails=0
cids=()

cleanup() {
  local c
  for c in "${cids[@]:-}"; do
    if [ -n "$c" ]; then docker rm -f "$c" >/dev/null 2>&1 || true; fi
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
assert_disabled() { # cid label needle activedir...
  local cid=$1 label=$2 needle=$3
  shift 3
  local listing
  listing=$(docker exec "$cid" sh -c "ls $* 2>/dev/null" || true)
  case "$listing" in
  *"$needle"*) fail "$label (still enabled: '$needle')" ;;
  *) pass "$label" ;;
  esac
}
# Symlink an available snippet/module into its active dir inside $cid, simulating
# an orphan a prior run left active. `src` is relative to the active dir (the
# `../*-available.d/...` form angie-ctl uses); `dst` is the active path.
link_active() { # cid src dst
  docker exec "$1" ln -sf "$2" "$3"
}

# Start a detached container; echoes the container id and registers it for cleanup.
start() { # extra docker run args...
  local cid
  cid=$(docker run -d "$@" "$IMAGE")
  cids+=("$cid")
  printf '%s' "$cid"
}

# Poll the in-container /healthz endpoint until it answers or we give up.
wait_healthy() { # cid
  local cid=$1 _
  for _ in $(seq 1 40); do
    if docker exec "$cid" wget -q -O /dev/null http://127.0.0.1/healthz 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
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
  if docker run --rm "$IMAGE" wget -q -O /dev/null "http://$cip/healthz" 2>/dev/null; then
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
: >"$tmp/db evil.mmdb"
chmod a+r "$tmp/db evil.mmdb"
set +e
timeout 30 docker run --rm -v "$tmp:/geo:ro" \
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
timeout 30 docker run --rm -e 'ANGIE_REAL_IP_FROM=10.0.0.0/8;evil' "$IMAGE" >/dev/null 2>&1
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
# Toggles now mutate with --no-test and the entrypoint validates once at the end
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
printf '#!/bin/sh\nexit 7\n' >"$tmp/99-zz-fail.sh"
chmod +x "$tmp/99-zz-fail.sh"
set +e
timeout 30 docker run --rm -v "$tmp/99-zz-fail.sh:/docker-entrypoint.d/99-zz-fail.sh:ro" "$IMAGE" >/dev/null 2>&1
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
logs=$(docker run --rm --user 1000:1000 "$IMAGE" 2>&1)
rc=$?
set -e
assert_contains "$logs" "requires root" \
  "non-root: entrypoint fails fast with a clear 'requires root' message"
if [ "$rc" -ne 0 ]; then
  pass "non-root: default image refuses to start (exit $rc)"
else
  fail "non-root: default image refuses to start (got exit 0)"
fi

printf '\n%d test(s), %d failure(s)\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
