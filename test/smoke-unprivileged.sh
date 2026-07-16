#!/bin/sh
# Smoke tests for the rootless (unprivileged) image. Asserts it runs under
# arbitrary `--user <uid>` with no added capabilities (serving on port 8080),
# that the default user can apply ANGIE_* toggles at runtime, and that a foreign
# uid safely skips toggling with a warning instead of crashing. POSIX sh on
# purpose: the suite must run on hosts without bash (alpine CI runners).
#
# Usage: IMAGE=angie-alpine-unprivileged ./test/smoke-unprivileged.sh
set -eu
# pipefail is not POSIX (before POSIX.1-2024); busybox ash and dash >= 0.5.12
# support it, older dash does not -- hence the subshell probe instead of an
# unconditional set. The assertions do not depend on it.
# shellcheck disable=SC3040 # probed in a subshell first; harmless when absent
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

IMAGE="${IMAGE:?set IMAGE=<image:tag>}"
PORT=8080

tests=0
fails=0

# Containers are swept by label, not by an accumulated id list: start() runs
# inside command substitutions, so an id appended to a variable there dies with
# the subshell -- an aborted run would leak its containers.
SMOKE_RUN_LABEL="angie-smoke-run=$$"

cleanup() {
  # No `xargs -r` (a GNU/busybox extension): with an empty id list docker rm
  # errors on missing arguments, which the redirect + `|| true` absorb.
  docker ps -aq --filter "label=$SMOKE_RUN_LABEL" | xargs docker rm -f >/dev/null 2>&1 || true
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
  docker run -d --label "$SMOKE_RUN_LABEL" "$@" "$IMAGE"
}

wait_healthy() { # cid
  __wh_cid=$1
  for _ in $(seq 1 40); do
    if docker exec "$__wh_cid" wget -q -O /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
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

# --- Clean rootless startup: no inert `user` directive warning -------------
# The rootless Dockerfile strips `user angie;` from angie.conf because a non-root
# master cannot honor it and Angie would log a [warn] every start. Guard against
# the directive (or the override step) regressing back in.
cid=$(start --user 10000:10000)
wait_healthy "$cid" || fail "container healthy for warn check"
logs=$(docker logs "$cid" 2>&1)
case "$logs" in
*'"user" directive'*) fail "rootless start logs an inert 'user' directive warning" ;;
*) pass "rootless start has no inert 'user' directive warning" ;;
esac
docker rm -f "$cid" >/dev/null

# --- Default user owns config dirs: runtime ANGIE_* toggles apply ----------
cid=$(start -e ANGIE_BROTLI_ENABLED=yes)
if wait_healthy "$cid" &&
  docker exec "$cid" sh -c 'ls /etc/angie/modules.d/http_brotli_filter.conf' >/dev/null 2>&1; then
  pass "default user applies ANGIE_* toggle at runtime (brotli enabled)"
else
  fail "default user applies ANGIE_* toggle at runtime"
  docker logs "$cid" 2>&1 | grep -iE 'emerg|not writable' | head -2 || true
fi
docker rm -f "$cid" >/dev/null

# --- Foreign uid cannot write config: toggle skipped, still serves ---------
cid=$(start --user 4343:4343 -e ANGIE_BROTLI_ENABLED=yes)
if wait_healthy "$cid" &&
  docker logs "$cid" 2>&1 | grep -qi 'runtime toggling unavailable' &&
  ! docker exec "$cid" sh -c 'ls /etc/angie/modules.d/http_brotli_filter.conf' >/dev/null 2>&1; then
  pass "foreign --user skips toggling with a warning, serves baked config"
else
  fail "foreign --user skips toggling with a warning"
fi
docker rm -f "$cid" >/dev/null

# --- /healthz loopback-only; unknown host 444 ------------------------------
cid=$(start --user 10000:10000)
wait_healthy "$cid" || fail "container healthy for endpoint checks"
body=$(docker exec "$cid" wget -q -O - "http://127.0.0.1:$PORT/healthz" 2>/dev/null || true)
if [ "$body" = "ok" ]; then
  pass "/healthz body is exactly 'ok'"
else
  fail "/healthz body is exactly 'ok' (got '$body')"
fi
if docker exec "$cid" wget -q -O /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
  fail "default server denies unknown host (expected 444/closed)"
else
  pass "default server denies unknown host (444)"
fi
cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null || true)
if [ -n "$cip" ]; then
  if docker run --rm --label "$SMOKE_RUN_LABEL" "$IMAGE" wget -q -O /dev/null "http://$cip:$PORT/healthz" 2>/dev/null; then
    fail "/healthz reachable from another container ($cip) — must be denied"
  else
    pass "/healthz denied from external client ($cip)"
  fi
else
  fail "could not determine container IP to probe /healthz externally"
fi
docker rm -f "$cid" >/dev/null

printf '\n%d test(s), %d failure(s)\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
