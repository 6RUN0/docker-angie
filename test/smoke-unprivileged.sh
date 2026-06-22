#!/usr/bin/env bash
# Smoke tests for the rootless (unprivileged) image. Asserts it runs under
# arbitrary `--user <uid>` with no added capabilities, serving on port 8080.
#
# Usage: IMAGE=angie-alpine-unprivileged ./test/smoke-unprivileged.sh
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE=<image:tag>}"
PORT=8080

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

start() { # extra docker run args...
  local cid
  cid=$(docker run -d "$@" "$IMAGE")
  cids+=("$cid")
  printf '%s' "$cid"
}

wait_healthy() { # cid
  local cid=$1 _
  for _ in $(seq 1 40); do
    if docker exec "$cid" wget -q -O /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

printf 'Smoke testing %s (rootless, port %s)\n' "$IMAGE" "$PORT"

# --- Runs under arbitrary uids, no added capabilities ----------------------
for u in 10000:10000 4242:0 1000:1000; do
  cid=$(start --user "$u")
  if wait_healthy "$cid"; then
    pass "runs under --user $u with no capabilities (/healthz 200 on $PORT)"
  else
    fail "runs under --user $u with no capabilities"
    docker logs "$cid" 2>&1 | grep -i emerg | head -1 || true
  fi
  docker rm -f "$cid" >/dev/null
done

# --- /healthz loopback-only; unknown host 444 ------------------------------
cid=$(start --user 10000:10000)
wait_healthy "$cid" || fail "container healthy for endpoint checks"
if docker exec "$cid" wget -q -O /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
  fail "default server denies unknown host (expected 444/closed)"
else
  pass "default server denies unknown host (444)"
fi
cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null || true)
if [ -n "$cip" ]; then
  if docker run --rm "$IMAGE" wget -q -O /dev/null "http://$cip:$PORT/healthz" 2>/dev/null; then
    fail "/healthz reachable from another container ($cip) — must be denied"
  else
    pass "/healthz denied from external client ($cip)"
  fi
fi
docker rm -f "$cid" >/dev/null

printf '\n%d test(s), %d failure(s)\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
