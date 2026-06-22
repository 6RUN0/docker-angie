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
    [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1 || true
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
