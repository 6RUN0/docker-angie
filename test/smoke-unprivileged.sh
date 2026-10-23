#!/bin/sh
# Smoke tests for the rootless (unprivileged) image. Asserts it runs under
# arbitrary `--user <uid>` with no added capabilities (serving on port 8080) and
# that any such uid applies ANGIE_* toggles in its own /data/conf live tree.
# POSIX sh on purpose: the suite must run on hosts without bash (alpine CI
# runners).
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
vols=""
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

start() { # extra docker run args...
  docker run -d --label "$SMOKE_RUN_LABEL" "$@" "$IMAGE"
}

wait_healthy() { # cid
  __wh_cid=$1
  for _ in $(seq 1 40); do
    if docker exec "$__wh_cid" wget -q --tries=1 -T 2 -O /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
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
# rootfs-unprivileged/ replaces conf.d/05-worker-user.conf with a comment-only
# file: a non-root master cannot honor `user angie;` and Angie would log a [warn]
# every start. Matched on the message tail, which survives the JSON error log
# (that format escapes the quotes around "user"). Guards the overlay regressing.
cid=$(start --user 10000:10000)
wait_healthy "$cid" || fail "container healthy for warn check"
logs=$(docker logs "$cid" 2>&1)
case "$logs" in
*'directive makes sense only if the master process runs'*) fail "rootless start logs an inert 'user' directive warning" ;;
*) pass "rootless start has no inert 'user' directive warning" ;;
esac
docker rm -f "$cid" >/dev/null

# --- Default user owns config dirs: runtime ANGIE_* toggles apply ----------
cid=$(start -e ANGIE_BROTLI_ENABLED=yes)
if wait_healthy "$cid" &&
  docker exec "$cid" sh -c 'ls /data/conf/modules.d/http_brotli_filter.conf' >/dev/null 2>&1; then
  pass "default user applies ANGIE_* toggle at runtime (brotli enabled)"
else
  fail "default user applies ANGIE_* toggle at runtime"
  docker logs "$cid" 2>&1 | grep -iE 'emerg|not writable' | head -2 || true
fi
docker rm -f "$cid" >/dev/null

# --- /data is world-writable sticky so any --user can build its tree ---------
# The base image keeps /data root-owned 0755 for its root master; this variant
# must reopen it, or every foreign uid below fails the writability probe.
mode=$(docker run --rm --label "$SMOKE_RUN_LABEL" --entrypoint stat "$IMAGE" -c '%a' /data /data/tmp | tr '\n' ' ')
if [ "$mode" = "1777 1777 " ]; then
  pass "/data and /data/tmp are 1777 in the unprivileged image"
else
  fail "/data and /data/tmp are 1777 in the unprivileged image (got '$mode')"
fi

# --- A foreign uid owns its live copy and can apply runtime toggles ----------
cid=$(start --user 4343:4343 -e ANGIE_BROTLI_ENABLED=yes)
if wait_healthy "$cid" &&
  docker exec "$cid" sh -c 'ls /data/conf/modules.d/http_brotli_filter.conf' >/dev/null 2>&1; then
  pass "foreign --user applies runtime toggles to its live copy"
else
  fail "foreign --user applies runtime toggles to its live copy"
fi
docker rm -f "$cid" >/dev/null

# --- /healthz loopback-only; unknown host 444 ------------------------------
cid=$(start --user 10000:10000)
wait_healthy "$cid" || fail "container healthy for endpoint checks"
body=$(docker exec "$cid" wget -q --tries=1 -T 2 -O - "http://127.0.0.1:$PORT/healthz" 2>/dev/null || true)
if [ "$body" = "ok" ]; then
  pass "/healthz body is exactly 'ok'"
else
  fail "/healthz body is exactly 'ok' (got '$body')"
fi
if docker exec "$cid" wget -q --tries=1 -T 5 -O /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
  fail "default server denies unknown host (expected 444/closed)"
else
  pass "default server denies unknown host (444)"
fi
cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null || true)
if [ -n "$cip" ]; then
  if docker run --rm --label "$SMOKE_RUN_LABEL" "$IMAGE" wget -q --tries=1 -T 5 -O /dev/null "http://$cip:$PORT/healthz" 2>/dev/null; then
    fail "/healthz reachable from another container ($cip) - must be denied"
  else
    pass "/healthz denied from external client ($cip)"
  fi
else
  fail "could not determine container IP to probe /healthz externally"
fi
docker rm -f "$cid" >/dev/null

# --- Image USER is a numeric uid:gid ---------------------------------------
# Kubernetes with runAsNonRoot accepts only a numeric uid: it cannot verify a
# user name and refuses to start the pod (`image has non-numeric user`).
image_user=$(docker inspect -f '{{.Config.User}}' "$IMAGE")
case "$image_user" in
*[!0-9:]* | '' | :* | *: | *:*:*) fail "image USER is numeric uid:gid (got '$image_user')" ;;
*:*) pass "image USER is numeric uid:gid ($image_user)" ;;
*) fail "image USER is numeric uid:gid (got '$image_user')" ;;
esac

# --- ACME state dir: 0700 and owned by the running uid ---------------------
# Private keys live there, so the /data/tmp-style 1777 trick does not apply;
# pinned against a "fix" for foreign uids that widens the mode. A foreign uid on
# a fresh volume gets its own 0700 dir through the sticky 1777 /data.
for u in "" 1234:1234; do
  vol="angie-smoke-unpriv-acme-$$-${u%%:*}"
  docker volume create "$vol" >/dev/null
  vols="$vols $vol"
  if [ -n "$u" ]; then
    cid=$(start --user "$u" -v "$vol:/data" -e ANGIE_ACME_ENABLED=1 \
      -e ANGIE_ACME_DIRECTORY=https://127.0.0.1:19999/directory)
    want="700 ${u%%:*}"
  else
    cid=$(start -v "$vol:/data" -e ANGIE_ACME_ENABLED=1 \
      -e ANGIE_ACME_DIRECTORY=https://127.0.0.1:19999/directory)
    want="700 $(docker inspect -f '{{.Config.User}}' "$IMAGE" | cut -d: -f1)"
  fi
  wait_healthy "$cid" || fail "ACME state-dir container healthy (user '${u:-default}')"
  got=""
  for _ in $(seq 1 20); do
    got=$(docker exec "$cid" stat -c '%a %u' /data/acme 2>/dev/null || true)
    [ -n "$got" ] && break
    sleep 0.5
  done
  if [ "$got" = "$want" ]; then
    pass "ACME state dir is $want (user '${u:-default}')"
  else
    fail "ACME state dir is $want (user '${u:-default}', got '$got')"
  fi
  docker rm -f "$cid" >/dev/null
done

# --- ACME: a privileged challenge port is refused without root -------------
# A non-root master cannot bind below 1024; the toggle refuses by name instead
# of leaving an opaque bind() failure to angie.
logs=$(timeout 30 docker run --rm --label "$SMOKE_RUN_LABEL" -e ANGIE_ACME_ENABLED=1 \
  -e ANGIE_ACME_HTTP_PORT=80 "$IMAGE" 2>&1 || true)
case "$logs" in
*"ANGIE_ACME_HTTP_PORT must be 1024 or above"*) pass "ACME refuses a privileged ANGIE_ACME_HTTP_PORT" ;;
*) fail "ACME refuses a privileged ANGIE_ACME_HTTP_PORT" ;;
esac

# --- Console Light under a foreign --user reads a 0644 htpasswd ------------
# The entrypoint checks readability as the uid the workers run as, so a file
# that passes is one angie can open: pinned on an arbitrary uid end to end.
htmp=$(mktemp -d)
tmpdirs="$tmpdirs $htmp"
chmod 755 "$htmp"
console_path=smokeconsole0123456789abcdef
# shellcheck disable=SC2016 # dollar signs are separators in the crypt hash
printf 'console:%s\n' '$6$smoketest$MQ5ecdoqtztOulLz4nKl8dcH9VqIjqRFCj3iF7141j5QsEGlkRCx9255SnVyLUyIZGMpJx43MZIQ0VrKf8h.R1' \
  >"$htmp/console.htpasswd"
chmod 644 "$htmp/console.htpasswd"
cid=$(start --user 10000:10000 -e ANGIE_CONSOLE_ENABLED=1 -e "ANGIE_CONSOLE_PATH=$console_path" \
  -v "$htmp:/etc/angie/custom:ro")
if wait_healthy "$cid"; then
  pass "console under --user 10000:10000 with a 0644 htpasswd starts"
else
  fail "console under --user 10000:10000 with a 0644 htpasswd starts"
fi
status=$(docker exec "$cid" wget -S --tries=1 -T 3 -O /dev/null \
  '--header=Authorization: Basic Y29uc29sZTpjb25zb2xl' "http://127.0.0.1:$PORT/$console_path/" 2>&1 |
  sed -n 's|^ *HTTP/1.1 \([0-9]*\).*|\1|p' | head -1 || true)
if [ "$status" = "200" ]; then
  pass "console under --user 10000:10000: credentials get 200"
else
  fail "console under --user 10000:10000: credentials get 200 (got '$status')"
fi
docker rm -f "$cid" >/dev/null
rm -rf "$htmp"

# --- The foreign-owner refusal recipe hands over all of /data --------------
# The previous uid creates /data/tmp/*_temp 0700, so a recipe that chowned only
# /data/conf would leave a healthy start whose request buffering fails. The
# recipe is taken from the refusal verbatim; only the volume and image change.
vol="angie-smoke-unpriv-owner-$$"
docker volume create "$vol" >/dev/null
vols="$vols $vol"
cid=$(start --user 1000:1000 -v "$vol:/data")
wait_healthy "$cid" || fail "owner recipe: the first run as uid 1000 is healthy"
docker rm -f "$cid" >/dev/null
logs=$(timeout 30 docker run --rm --label "$SMOKE_RUN_LABEL" --user 2000:2000 -v "$vol:/data" "$IMAGE" 2>&1 || true)
recipe=$(printf '%s\n' "$logs" |
  grep -o 'docker run --rm -u 0 -v <volume>:/data --entrypoint chown <image> -R [0-9]*:[0-9]* [^" ]*' |
  head -1 || true)
if [ "$recipe" = "docker run --rm -u 0 -v <volume>:/data --entrypoint chown <image> -R 2000:2000 /data" ]; then
  pass "owner recipe: the refusal hands all of /data to the new uid"
else
  fail "owner recipe: the refusal hands all of /data to the new uid (got '$recipe')"
fi
if [ -n "$recipe" ]; then
  recipe=$(printf '%s' "$recipe" | sed "s|<volume>|$vol|; s|<image>|$IMAGE|")
  # Word splitting is the point: the recipe runs as a command and holds neither
  # quotes nor glob characters.
  # shellcheck disable=SC2086
  timeout 60 $recipe >/dev/null 2>&1 || fail "owner recipe: the chown command from the refusal runs"
fi
cid=$(start --user 2000:2000 -v "$vol:/data")
if wait_healthy "$cid"; then
  pass "owner recipe: the start as uid 2000 is healthy after the recipe"
else
  fail "owner recipe: the start as uid 2000 is healthy after the recipe"
fi
foreign=$(docker exec "$cid" find /data ! -user 2000 2>&1 || true)
if [ -z "$foreign" ]; then
  pass "owner recipe: nothing under /data is left to another uid"
else
  fail "owner recipe: nothing under /data is left to another uid (got '$foreign')"
fi
docker rm -f "$cid" >/dev/null

printf '\n%d test(s), %d failure(s)\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
