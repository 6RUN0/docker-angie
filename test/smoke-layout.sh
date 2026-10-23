#!/bin/sh
# Runtime-layout and feature smoke tests shared by root and unprivileged images.
#
# Usage: IMAGE=angie-alpine PORT=80 ./test/smoke-layout.sh
set -eu
# shellcheck disable=SC3040 # pipefail support is probed before enabling it
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

IMAGE="${IMAGE:?set IMAGE=<image:tag>}"
PORT="${PORT:-80}"
tests=0
fails=0
vols=""
tmpdirs=""
SMOKE_RUN_LABEL="angie-layout-smoke=$$"

cleanup() {
  docker ps -aq --filter "label=$SMOKE_RUN_LABEL" | xargs docker rm -f >/dev/null 2>&1 || true
  for vol in $vols; do docker volume rm -f "$vol" >/dev/null 2>&1 || true; done
  for dir in $tmpdirs; do rm -rf "$dir"; done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

pass() { tests=$((tests + 1)); printf '  ok   %s\n' "$1"; }
fail() { tests=$((tests + 1)); fails=$((fails + 1)); printf '  FAIL %s\n' "$1"; }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}
assert_contains() {
  case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2')" ;; esac
}
assert_lacks() {
  case "$1" in *"$2"*) fail "$3 (found '$2')" ;; *) pass "$3" ;; esac
}

start() { docker run -d --label "$SMOKE_RUN_LABEL" "$@" "$IMAGE"; }
wait_healthy() {
  for _ in $(seq 1 60); do
    if docker exec "$1" wget -q --tries=1 -T 2 -O /dev/null \
      "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  return 1
}
dump_conf() { docker exec "$1" angie -p /data/conf -c angie.conf -T 2>/dev/null; }
# Worker pids from /proc: debian-slim ships no pgrep. Sorted for comparison.
worker_pids() {
  docker exec "$1" sh -c 'for d in /proc/[0-9]*; do
    case "$(tr "\\0" " " 2>/dev/null <"$d/cmdline")" in
    "angie: worker process"*) echo "${d#/proc/}" ;;
    esac
  done' | sort
}
run_to_exit() {
  exit_log=""
  exit_rc=run-failed
  cid=$(docker run -d --label "$SMOKE_RUN_LABEL" "$@") || return 0
  wait_rc=0
  exit_rc=$(timeout 30 docker wait "$cid" 2>/dev/null) || wait_rc=$?
  [ "$wait_rc" -eq 0 ] || exit_rc="wait-$wait_rc"
  exit_log=$(docker logs "$cid" 2>&1 || true)
  docker rm -f "$cid" >/dev/null 2>&1 || true
}
assert_exit_one() {
  assert_eq "$exit_rc" "1" "$1 exits with status 1"
  [ -z "${2:-}" ] || assert_contains "$exit_log" "$2" "$1 explains the refusal"
}
http_status() {
  __hs_cid=$1
  __hs_port=$2
  __hs_path=$3
  shift 3
  docker exec "$__hs_cid" wget -S --tries=1 -T 3 -O /dev/null "$@" \
    "http://127.0.0.1:$__hs_port$__hs_path" 2>&1 |
    sed -n 's|^ *HTTP/1.1 \([0-9]*\).*|\1|p' | head -1 || true
}
conf_test() { docker exec "$1" angie -p /data/conf -c angie.conf -t; }
container_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null || true
}
# Status code of a request from a SIBLING container, i.e. with a real external
# source address; extra args go to wget. Empty on 444 or a closed port.
sibling_status() { # url [extra wget args...]
  __ss_url=$1
  shift
  timeout 30 docker run --rm --label "$SMOKE_RUN_LABEL" "$IMAGE" \
    wget -S --tries=1 -T 5 -O /dev/null "$@" "$__ss_url" 2>&1 |
    sed -n 's|^ *HTTP/1.1 \([0-9]*\).*|\1|p' | head -1 || true
}
# Response headers of a SUCCESSFUL response only: on 4xx/5xx busybox wget prints
# the status line alone while GNU wget prints everything, so a header assertion
# on an error response would pass on debian and fail on alpine.
resp_headers() { # cid url [extra wget args...]
  __rh_cid=$1
  __rh_url=$2
  shift 2
  docker exec "$__rh_cid" wget -S --tries=1 -T 3 -q -O /dev/null "$@" "$__rh_url" 2>&1 || true
}
# HTTP/1.0 request WITHOUT a Host header from inside the container. Neither wget
# can omit Host, and an empty `Host:` is answered 400, while an ABSENT one is
# matched against the empty server_name - the case under test. alpine ships only
# busybox nc, debian only bash with /dev/tcp.
raw_hostless_get() { # cid port path
  docker exec "$1" sh -c '
port=$1
path=$2
if command -v nc >/dev/null 2>&1; then
  printf "GET %s HTTP/1.0\r\n\r\n" "$path" | nc 127.0.0.1 "$port"
elif [ -x /bin/bash ]; then
  /bin/bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; printf \"GET $path HTTP/1.0\\r\\n\\r\\n\" >&3; cat <&3"
else
  printf "no raw HTTP client in the image\n" >&2
  exit 127
fi
' sh "$2" "$3" 2>/dev/null || true
}
# TCP listeners on a port inside the container, from /proc/net/tcp{,6}: debian
# ships no netstat, and a silent 0 there would pass a presence assertion.
listeners_on() { # cid port
  __lo_hex=$(printf '%04X' "$2")
  docker exec "$1" sh -c '
total=0
seen=0
for f in /proc/net/tcp /proc/net/tcp6; do
  [ -r "$f" ] || continue
  seen=1
  n=$(grep -cE "^ *[0-9]+: [0-9A-F]+:$1 [0-9A-F]+:[0-9A-F]+ 0A " "$f" || true)
  total=$((total + n))
done
[ "$seen" -eq 1 ] || exit 1
echo "$total"
' sh "$__lo_hex"
}
# Escape string for `printf %b` from decimal byte values: `\0` plus exactly three
# octal digits, so the next data character is never read as part of the escape.
mmdb_bytes() { # decimal byte values...
  __mb_out=""
  for __mb_v in "$@"; do
    __mb_out="${__mb_out}\\0$(printf '%03o' "$__mb_v")"
  done
  printf '%s' "$__mb_out"
}
# Minimal MaxMind DB (format spec 2.0) built on the fly, so no binary fixture
# goes stale in git and no mmdb writer is needed on the runner. It maps
# 203.0.113.0/24 (TEST-NET-3, never a real docker peer) to country iso_code XX;
# every other address misses and falls back to default=ZZ of 025-geoip2.conf.
make_mmdb() { # outfile
  __mm_bits=110010110000000001110001
  __mm_nodes=24
  # A record above node_count points into the data section at
  # (value - node_count - 16), here offset 0.
  __mm_ptr=$((__mm_nodes + 16))
  __mm_esc=""
  __mm_i=0
  __mm_rest=$__mm_bits
  # One node per network bit, 24-bit records (6 bytes per node): the matching
  # branch leads to the next node or, at the last one, to the data; the other
  # equals node_count, i.e. "not found".
  while [ -n "$__mm_rest" ]; do
    __mm_bit=${__mm_rest%"${__mm_rest#?}"}
    __mm_rest=${__mm_rest#?}
    __mm_i=$((__mm_i + 1))
    if [ "$__mm_i" -lt "$__mm_nodes" ]; then
      __mm_hit=$__mm_i
    else
      __mm_hit=$__mm_ptr
    fi
    if [ "$__mm_bit" = 0 ]; then
      __mm_esc="${__mm_esc}$(mmdb_bytes 0 0 "$__mm_hit" 0 0 "$__mm_nodes")"
    else
      __mm_esc="${__mm_esc}$(mmdb_bytes 0 0 "$__mm_nodes" 0 0 "$__mm_hit")"
    fi
  done
  __mm_esc="${__mm_esc}$(mmdb_bytes 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)"
  # Data: map{country: map{iso_code: "XX"}}; 0xE1 is a one-pair map, 0x40|len
  # a utf8 string.
  __mm_esc="${__mm_esc}$(mmdb_bytes 225 71)country$(mmdb_bytes 225 72)iso_code$(mmdb_bytes 66)XX"
  # Metadata marker and all nine mandatory keys; libmaxminddb rejects the
  # database if any is missing.
  __mm_esc="${__mm_esc}$(mmdb_bytes 171 205 239)MaxMind.com$(mmdb_bytes 233)"
  __mm_esc="${__mm_esc}$(mmdb_bytes 91)binary_format_major_version$(mmdb_bytes 161 2)"
  __mm_esc="${__mm_esc}$(mmdb_bytes 91)binary_format_minor_version$(mmdb_bytes 160)"
  __mm_esc="${__mm_esc}$(mmdb_bytes 75)build_epoch$(mmdb_bytes 4 2 104 0 0 0)"
  __mm_esc="${__mm_esc}$(mmdb_bytes 77)database_type$(mmdb_bytes 80)angie-smoke-test"
  __mm_esc="${__mm_esc}$(mmdb_bytes 75)description$(mmdb_bytes 225 66)en$(mmdb_bytes 83)smoke test database"
  __mm_esc="${__mm_esc}$(mmdb_bytes 74)ip_version$(mmdb_bytes 161 4)"
  __mm_esc="${__mm_esc}$(mmdb_bytes 73)languages$(mmdb_bytes 1 4 66)en"
  __mm_esc="${__mm_esc}$(mmdb_bytes 74)node_count$(mmdb_bytes 193 24)"
  __mm_esc="${__mm_esc}$(mmdb_bytes 75)record_size$(mmdb_bytes 161 24)"
  printf '%b' "$__mm_esc" >"$1"
}
# wait_logs: poll the stdout stream until the needle shows up (30 s budget),
# then print it either way, so the caller asserts on the real final state.
wait_logs() { # cid needle
  __wl_out=""
  for _ in $(seq 1 60); do
    __wl_out=$(docker logs "$1" 2>/dev/null)
    case "$__wl_out" in *"$2"*) break ;; esac
    sleep 0.5
  done
  printf '%s' "$__wl_out"
}

printf 'Layout and feature smoke testing %s (port %s)\n' "$IMAGE" "$PORT"

# The shipped tree is a read-only source; the live tree is a marked fresh copy.
cid=$(start)
wait_healthy "$cid" || fail "base container becomes healthy"
assert_eq "$(docker exec "$cid" cat /data/conf/.angie-conf-overlay 2>/dev/null || true)" \
  "angie-managed-conf-v1" "live configuration carries the ownership marker"
if docker exec "$cid" test -f /data/conf/.angie-conf-overlay &&
  ! docker exec "$cid" test -L /data/conf/.angie-conf-overlay; then
  pass "the ownership marker is a regular file"
else
  fail "the ownership marker is a regular file"
fi
assert_contains "$(dump_conf "$cid")" "pid off" "the runtime configuration disables pid files"
assert_contains "$(dump_conf "$cid")" "access_log /dev/stdout angie_json" \
  "JSON is the default access log"
assert_contains "$(docker exec "$cid" grep '^error_log' /data/conf/angie.conf 2>/dev/null || true)" \
  "format=json" "JSON is the default error log"
assert_contains "$(docker inspect -f '{{json .Config.Cmd}}' "$IMAGE")" '"-p","/data/conf","-c","angie.conf"' \
  "the image command selects the live configuration explicitly"
for path in client_body proxy fastcgi uwsgi scgi; do
  assert_contains "$(dump_conf "$cid")" "${path}_temp_path /data/tmp/" \
    "$path temporary files stay under /data"
done
docker exec "$cid" wget -q --tries=1 -T 2 -O /dev/null \
  "http://127.0.0.1:$PORT/" 2>/dev/null || true
if command -v python3 >/dev/null 2>&1; then
  sleep 1
  json_lines=$(docker logs "$cid" 2>&1 | grep '^{' || true)
  if [ -n "$json_lines" ] && printf '%s\n' "$json_lines" |
    python3 -c 'import json,sys; [json.loads(line) for line in sys.stdin]'; then
    pass "every default structured log line is valid JSON"
  else
    fail "every default structured log line is valid JSON"
  fi
else
  printf '  skip JSON parser probe (python3 is unavailable on the host)\n'
fi
docker rm -f "$cid" >/dev/null

# A single writable /data mount is sufficient with a read-only root filesystem.
cid=$(start --read-only --tmpfs /data:rw,noexec,nosuid,nodev,mode=1777 \
  -e ANGIE_BROTLI_ENABLED=1)
if wait_healthy "$cid"; then pass "read-only rootfs starts with one /data tmpfs";
else fail "read-only rootfs starts with one /data tmpfs"; fi
assert_contains "$(dump_conf "$cid")" "brotli on" \
  "runtime toggles work with a read-only rootfs"
assert_eq "$(docker exec "$cid" stat -c '%a' /data 2>/dev/null || true)" "1777" \
  "the shared /data tmpfs uses sticky mode 1777"
if docker exec "$cid" sh -c 'echo forbidden >/etc/angie/.write-probe' 2>/dev/null; then
  fail "the shipped configuration remains read-only"
else
  pass "the shipped configuration remains read-only"
fi
docker rm -f "$cid" >/dev/null

run_to_exit --read-only "$IMAGE"
assert_exit_one "read-only rootfs without writable /data" "/data is not writable"
assert_contains "$exit_log" "--tmpfs /data" "the refusal gives the writable-mount recipe"

# A persistent /data volume is rebuilt declaratively on every start.
vol="angie-layout-reset-$$"
docker volume create "$vol" >/dev/null
vols="$vols $vol"
cid=$(start -v "$vol:/data" -e ANGIE_BROTLI_ENABLED=1)
wait_healthy "$cid" || fail "persistent /data first start is healthy"
assert_contains "$(dump_conf "$cid")" "brotli on" "the first persistent run enables brotli"
docker exec "$cid" sh -c ': >/data/conf/stale-from-previous-run'
docker rm -f "$cid" >/dev/null
cid=$(start -v "$vol:/data")
wait_healthy "$cid" || fail "persistent /data restart is healthy"
if docker exec "$cid" test ! -e /data/conf/http-conf.d/020-brotli.conf; then
  pass "persistent restart resets a removed feature"
else
  fail "persistent restart resets a removed feature"
fi
if docker exec "$cid" test ! -e /data/conf/stale-from-previous-run; then
  pass "persistent restart removes stale live-tree files"
else
  fail "persistent restart removes stale live-tree files"
fi
docker rm -f "$cid" >/dev/null

# Foreign and suspicious live trees are refused without mutation.
foreign=$(mktemp -d); tmpdirs="$tmpdirs $foreign"; chmod 755 "$foreign"
printf 'precious\n' >"$foreign/precious.conf"; chmod 644 "$foreign/precious.conf"
run_to_exit -v "$foreign:/data/conf" "$IMAGE"
assert_exit_one "an unmarked foreign live tree" "has no valid .angie-conf-overlay"
assert_eq "$(cat "$foreign/precious.conf")" "precious" "the foreign tree is preserved"

forged_marker=$(mktemp -d); tmpdirs="$tmpdirs $forged_marker"; chmod 755 "$forged_marker"
printf 'not-the-managed-version\n' >"$forged_marker/.angie-conf-overlay"
printf 'precious\n' >"$forged_marker/precious.conf"; chmod 644 "$forged_marker"/*
run_to_exit -v "$forged_marker:/data/conf" "$IMAGE"
assert_exit_one "a live tree with a forged marker"
assert_eq "$(cat "$forged_marker/precious.conf")" "precious" \
  "a tree with an invalid marker is preserved"

linked=$(mktemp -d); tmpdirs="$tmpdirs $linked"; chmod 755 "$linked"
printf 'angie-managed-conf-v1\n' >"$linked/marker-target"
ln -s marker-target "$linked/.angie-conf-overlay"
printf 'precious\n' >"$linked/precious.conf"; chmod 644 "$linked"/*
run_to_exit -v "$linked:/data/conf" "$IMAGE"
assert_exit_one "a symlinked ownership marker"
assert_eq "$(cat "$linked/precious.conf")" "precious" \
  "a tree with a symlinked marker is preserved"

# 1777 so the rootless uid passes the writability probe and reaches the link check.
forged=$(mktemp -d); tmpdirs="$tmpdirs $forged"; chmod 1777 "$forged"
mkdir "$forged/outside"; printf 'precious\n' >"$forged/outside/precious.conf"
ln -s outside "$forged/conf"
run_to_exit -v "$forged:/data" "$IMAGE"
assert_exit_one "a symlinked /data/conf tree" "/data/conf is a symbolic link"
assert_eq "$(cat "$forged/outside/precious.conf")" "precious" \
  "a symlinked live tree cannot redirect overlay writes"

readonly_data=$(mktemp -d); tmpdirs="$tmpdirs $readonly_data"; chmod 755 "$readonly_data"
run_to_exit -v "$readonly_data:/data:ro" "$IMAGE"
assert_exit_one "a read-only /data mount" "/data is not writable"

linked_tmp=$(mktemp -d); tmpdirs="$tmpdirs $linked_tmp"; chmod 1777 "$linked_tmp"
mkdir "$linked_tmp/outside"; printf 'precious\n' >"$linked_tmp/outside/precious"
ln -s outside "$linked_tmp/tmp"
run_to_exit -v "$linked_tmp:/data" "$IMAGE"
assert_exit_one "a symlinked /data/tmp" "/data/tmp is a symbolic link"
assert_eq "$(cat "$linked_tmp/outside/precious")" "precious" \
  "a temporary-directory symlink cannot redirect writes"

# Custom bind mounts stay live and can be reloaded with a container signal.
custom=$(mktemp -d); tmpdirs="$tmpdirs $custom"; chmod 755 "$custom"
cat >"$custom/site.conf" <<'EOF'
server { listen 8090; server_name custom.reload; location = / { return 200 "one\n"; } }
EOF
chmod 644 "$custom/site.conf"
cid=$(start -v "$custom:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "custom-mount container is healthy"
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 2 -O - --header='Host: custom.reload' \
  http://127.0.0.1:8090/ 2>/dev/null || true)" "one" "the initial custom mount is served"
cat >"$custom/site.conf" <<'EOF'
server { listen 8090; server_name custom.reload; location = / { return 200 "two\n"; } }
EOF
docker kill --signal HUP "$cid" >/dev/null
# Reload is asynchronous: old workers answer until new ones take over.
for _ in $(seq 1 30); do
  reloaded=$(docker exec "$cid" wget -q --tries=1 -T 2 -O - --header='Host: custom.reload' \
    http://127.0.0.1:8090/ 2>/dev/null || true)
  [ "$reloaded" = "two" ] && break
  sleep 0.5
done
assert_eq "$reloaded" "two" "SIGHUP applies changes from the custom mount"
docker rm -f "$cid" >/dev/null

# angie-ctl operates on the live tree, creates relative links, and auto-tests it.
cid=$(start)
wait_healthy "$cid" || fail "angie-ctl container is healthy"
docker exec "$cid" angie-ctl httpconf en 060-map-websocket.conf >/dev/null
assert_eq "$(docker exec "$cid" readlink /data/conf/http-conf.d/060-map-websocket.conf)" \
  "../http-conf-available.d/060-map-websocket.conf" "angie-ctl creates a relative live-tree symlink"
docker exec "$cid" sh -c 'printf "this_is_invalid on;\n" >/data/conf/http.d/zz-invalid.conf'
if docker exec "$cid" angie-ctl mod en http_subs_filter.conf >/dev/null 2>&1; then
  fail "angie-ctl auto-test rejects an invalid live tree"
else
  pass "angie-ctl auto-test rejects an invalid live tree"
fi
docker rm -f "$cid" >/dev/null

# Force a request body to disk and proxy it through a real worker process.
post=$(mktemp -d); tmpdirs="$tmpdirs $post"; chmod 755 "$post"
cat >"$post/site.conf" <<'EOF'
server {
  listen 8091;
  client_body_buffer_size 1;
  client_body_in_file_only clean;
  location / { proxy_pass http://127.0.0.1:8092; }
}
server { listen 8092; location / { return 204; } }
EOF
chmod 644 "$post/site.conf"
cid=$(start --read-only --tmpfs /data:rw,noexec,nosuid,nodev,mode=1777 \
  -v "$post:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "POST-buffering container is healthy"
payload=$(awk 'BEGIN { for (i=0; i<70000; i++) printf "x" }')
status=$(docker exec "$cid" wget -S --tries=1 -T 5 -O /dev/null --post-data="$payload" \
  http://127.0.0.1:8091/ 2>&1 | sed -n 's|^ *HTTP/1.1 \([0-9]*\).*|\1|p' | head -1 || true)
assert_eq "$status" "204" "workers buffer and proxy a real POST under /data/tmp"
assert_lacks "$(docker logs "$cid" 2>&1)" "Permission denied" \
  "POST buffering produces no permission failure"
docker rm -f "$cid" >/dev/null

# New stock toggles compose and affect real HTTP responses selectively.
features=$(mktemp -d); tmpdirs="$tmpdirs $features"; chmod 755 "$features"
cat >"$features/site.conf" <<'EOF'
server {
  listen 8093;
  server_name features.probe;
  include snippets/expires-by-type.conf;
  location = /font { default_type font/woff2; return 200 "fontbytes"; }
  location = /doc { default_type text/html; return 200 "<p>x</p>"; }
}
EOF
chmod 644 "$features/site.conf"
has_tls_fixture=no
if command -v openssl >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=features.probe \
    -keyout "$features/key.pem" -out "$features/cert.pem" >/dev/null 2>&1
  chmod 644 "$features/key.pem" "$features/cert.pem"
  cat >>"$features/site.conf" <<'EOF'
server {
  listen 8443 ssl;
  server_name features.probe;
  ssl_certificate /etc/angie/custom/http.d/cert.pem;
  ssl_certificate_key /etc/angie/custom/http.d/key.pem;
  location = /doc { default_type text/html; return 200 "<p>x</p>"; }
}
EOF
  has_tls_fixture=yes
fi
cid=$(start -e ANGIE_CHARSET_UTF8_ENABLED=1 -e ANGIE_EXPIRES_ENABLED=1 \
  -e ANGIE_OPEN_FILE_CACHE_ENABLED=1 -e ANGIE_CORS_ASSETS_ENABLED=1 \
  -e ANGIE_HSTS_ENABLED=1 -e ANGIE_HSTS_MAX_AGE=31536000 \
  -v "$features:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "new-feature toggle container is healthy"
conf=$(dump_conf "$cid")
assert_contains "$conf" "charset utf-8" "the charset toggle renders its configuration"
assert_contains "$conf" "open_file_cache max=" "the open-file-cache toggle renders its configuration"
assert_contains "$conf" "max-age=31536000" "the HSTS toggle renders its configured age"
font_headers=$(docker exec "$cid" wget -q --tries=1 -T 3 -S -O /dev/null \
  --header='Host: features.probe' http://127.0.0.1:8093/font 2>&1 || true)
doc_headers=$(docker exec "$cid" wget -q --tries=1 -T 3 -S -O /dev/null \
  --header='Host: features.probe' --header='X-Forwarded-Proto: https' \
  http://127.0.0.1:8093/doc 2>&1 || true)
assert_contains "$font_headers" "Access-Control-Allow-Origin: *" \
  "asset CORS is emitted for a font"
assert_lacks "$doc_headers" "Access-Control-Allow-Origin" \
  "asset CORS is not emitted for an HTML document"
assert_contains "$font_headers" "Cache-Control: max-age=31536000" \
  "expires gives a font the far-future policy"
assert_contains "$doc_headers" "Cache-Control: no-cache" \
  "expires gives HTML the epoch policy"
assert_contains "$doc_headers" "text/html; charset=utf-8" \
  "charset is emitted on an HTML response"
assert_lacks "$doc_headers" "Strict-Transport-Security" \
  "HSTS is absent on HTTP even when X-Forwarded-Proto claims HTTPS"
if [ "$has_tls_fixture" = yes ]; then
  tls_headers=$(docker exec "$cid" wget -q --tries=1 -T 3 --no-check-certificate -S \
    -O /dev/null --header='Host: features.probe' https://127.0.0.1:8443/doc 2>&1 || true)
  assert_contains "$tls_headers" "Strict-Transport-Security: max-age=31536000" \
    "HSTS is emitted on a real HTTPS response"
else
  printf '  skip HSTS HTTPS probe (openssl is unavailable on the host)\n'
fi
docker rm -f "$cid" >/dev/null

run_to_exit -e ANGIE_HSTS_ENABLED=1 -e ANGIE_HSTS_MAX_AGE=forever "$IMAGE"
assert_exit_one "HSTS with a non-numeric max age" "ANGIE_HSTS_MAX_AGE"

# ACME is configured against an unreachable local CA; no issuance is attempted.
cid=$(start -e ANGIE_ACME_ENABLED=1 \
  -e ANGIE_ACME_DIRECTORY=https://127.0.0.1:19999/directory)
wait_healthy "$cid" || fail "ACME configuration does not require a reachable CA at startup"
conf=$(dump_conf "$cid")
assert_contains "$conf" "acme_client_path /data/acme" "ACME state is stored under /data"
assert_contains "$conf" "acme_http_port $PORT" "ACME defaults to the image HTTP port"
if docker exec "$cid" test -e /data/conf/http-conf.d/080-acme.conf; then
  pass "the ACME configuration is enabled"
else
  fail "the ACME configuration is enabled"
fi
docker rm -f "$cid" >/dev/null

run_to_exit -e ANGIE_ACME_ENABLED=1 -e ANGIE_ACME_CHALLENGE=invalid "$IMAGE"
assert_exit_one "ACME with an invalid challenge" "ANGIE_ACME_CHALLENGE"
run_to_exit -e ANGIE_ACME_ENABLED=1 -e ANGIE_ACME_HTTP_PORT=70000 "$IMAGE"
assert_exit_one "ACME with an out-of-range port" "ANGIE_ACME_HTTP_PORT"
run_to_exit -e ANGIE_ACME_ENABLED=1 -e "ANGIE_ACME_DIRECTORY=#https://acme.invalid/dir" "$IMAGE"
assert_exit_one "ACME with a non-https directory" "must be an https:// URL"

# A link planted on a shared /data would redirect account keys off the mount.
# A named volume, not a bind dir: the overlay writes into it as root on the
# root image, which the host user could not clean up afterwards.
acme_vol="angie-layout-acme-$$"
docker volume create "$acme_vol" >/dev/null
vols="$vols $acme_vol"
docker run --rm --label "$SMOKE_RUN_LABEL" -u 0 -v "$acme_vol:/data" --entrypoint sh "$IMAGE" \
  -c "chmod 1777 /data && mkdir /data/outside && ln -s outside /data/acme"
run_to_exit -e ANGIE_ACME_ENABLED=1 -v "$acme_vol:/data" "$IMAGE"
assert_exit_one "a symlinked /data/acme" "/data/acme is a symbolic link"

# Console Light requires a strong path and valid authentication by default.
console=$(mktemp -d); tmpdirs="$tmpdirs $console"; chmod 755 "$console"
console_path=smokeconsole0123456789abcdef
# shellcheck disable=SC2016 # dollar signs are separators in the crypt hash
console_hash='$6$smoketest$MQ5ecdoqtztOulLz4nKl8dcH9VqIjqRFCj3iF7141j5QsEGlkRCx9255SnVyLUyIZGMpJx43MZIQ0VrKf8h.R1'
printf 'console:%s\n' "$console_hash" >"$console/console.htpasswd"; chmod 644 "$console/console.htpasswd"
cid=$(start -e ANGIE_CONSOLE_ENABLED=1 -e "ANGIE_CONSOLE_PATH=$console_path" \
  -v "$console:/etc/angie/custom:ro")
wait_healthy "$cid" || fail "authenticated Console Light starts"
assert_eq "$(http_status "$cid" "$PORT" "/$console_path/")" "401" \
  "Console Light rejects a request without credentials"
auth='--header=Authorization: Basic Y29uc29sZTpjb25zb2xl'
assert_eq "$(http_status "$cid" "$PORT" "/$console_path/" "$auth")" "200" \
  "Console Light accepts the configured credentials"
console_api=$(docker exec "$cid" wget -q --tries=1 -T 3 -O - "$auth" \
  "http://127.0.0.1:$PORT/$console_path/api/angie/" 2>/dev/null || true)
assert_contains "$console_api" '"version"' "the authenticated Console API returns status data"
assert_lacks "$console_api" 'config_files' "the Console API does not expose configuration files"
docker rm -f "$cid" >/dev/null

cid=$(start)
wait_healthy "$cid" || fail "Console-disabled control container is healthy"
assert_lacks "$(dump_conf "$cid" | grep -v '^ *#' || true)" "angie-console-light" \
  "Console Light is absent by default"
docker rm -f "$cid" >/dev/null

run_to_exit -e ANGIE_CONSOLE_ENABLED=1 -e ANGIE_CONSOLE_PATH=short \
  -v "$console:/etc/angie/custom:ro" "$IMAGE"
assert_exit_one "Console Light with a short path" "ANGIE_CONSOLE_PATH"
run_to_exit -e ANGIE_CONSOLE_ENABLED=1 -e "ANGIE_CONSOLE_PATH=$console_path" "$IMAGE"
assert_exit_one "Console Light without an htpasswd file" "ANGIE_CONSOLE_HTPASSWD_FILE"

# Rootless images keep the same contract under a foreign uid and detect owner drift.
if [ "$PORT" = 8080 ]; then
  cid=$(start --user 4343:4343 --read-only \
    --tmpfs /data:rw,noexec,nosuid,nodev,mode=1777 -e ANGIE_BROTLI_ENABLED=1)
  wait_healthy "$cid" || fail "foreign uid rootless read-only container is healthy"
  assert_contains "$(dump_conf "$cid")" "brotli on" \
    "a foreign uid applies toggles with a read-only rootfs"
  docker rm -f "$cid" >/dev/null

  owner_vol="angie-layout-owner-$$"
  docker volume create "$owner_vol" >/dev/null
  vols="$vols $owner_vol"
  cid=$(start --user 1000:1000 -v "$owner_vol:/data")
  wait_healthy "$cid" || fail "owner-mismatch fixture first run is healthy"
  docker exec "$cid" sh -c ': >/data/conf/stale-from-previous-run'
  docker rm -f "$cid" >/dev/null
  run_to_exit --user 2000:2000 -v "$owner_vol:/data" "$IMAGE"
  assert_exit_one "a live tree owned by another uid" "belongs to uid 1000"
fi

# angie-ctl --reload must work in the image: with `pid off` its upstream default
# (`angie -s reload`) has no pid file, so the image sets ANGIE_RELOAD_CMD to
# signal tini (PID 1), which forwards SIGHUP to the master.
cid=$(start)
wait_healthy "$cid" || fail "angie-ctl --reload container is healthy"
# A zero exit alone proves nothing: `kill` succeeds even if the signal is
# swallowed. A reload replaces the workers, so their pids must change.
workers_before=$(worker_pids "$cid")
if docker exec "$cid" angie-ctl --reload httpconf en 020-gzip.conf >/dev/null 2>&1; then
  pass "angie-ctl --reload exits 0 in the image"
else
  fail "angie-ctl --reload exits 0 in the image"
fi
reloaded=
for _ in $(seq 1 20); do
  workers_after=$(worker_pids "$cid")
  if [ -n "$workers_after" ] && [ "$workers_after" != "$workers_before" ]; then
    reloaded=yes
    break
  fi
  sleep 0.5
done
if [ -n "$reloaded" ]; then
  pass "angie-ctl --reload makes the master start new workers"
else
  fail "angie-ctl --reload makes the master start new workers"
fi
wait_healthy "$cid" || fail "server keeps serving after angie-ctl --reload"
docker rm -f "$cid" >/dev/null

# SIGQUIT reaches the master and completes a graceful shutdown.
cid=$(start)
wait_healthy "$cid" || fail "SIGQUIT container is healthy"
docker kill --signal QUIT "$cid" >/dev/null
quit_rc=$(timeout 15 docker wait "$cid" 2>/dev/null || true)
assert_eq "$quit_rc" "0" "SIGQUIT shuts the container down gracefully"
docker rm -f "$cid" >/dev/null

# --- Image metadata: one EXPOSE, OCI labels ---
# EXPOSE accumulates across FROM and cannot be dropped, so one declared in the
# shared runtime stage would reach both targets; nothing else reads the image
# metadata, and a stale port survives every behaviour check above.
exposed=$(docker inspect -f '{{range $p, $_ := .Config.ExposedPorts}}{{$p}} {{end}}' "$IMAGE" 2>/dev/null |
  tr -s ' ' | sed 's/ $//' || true)
assert_eq "$exposed" "$PORT/tcp" "the image exposes only $PORT/tcp"
labels=$(docker inspect -f '{{json .Config.Labels}}' "$IMAGE")
for label in title description source licenses version revision; do
  assert_contains "$labels" "\"org.opencontainers.image.$label\":" \
    "the image carries org.opencontainers.image.$label"
done
# base.name names the distro image the Dockerfile pins, never an Angie image:
# the distro comes from the image's own os-release, the pin from the default of
# ARG <DISTRO>_BASE_IMAGE. A build with an overridden base fails this check.
distro=$(docker run --rm --label "$SMOKE_RUN_LABEL" --entrypoint sh "$IMAGE" \
  -c '. /etc/os-release && printf %s "$ID"')
base_arg=$(printf '%s' "$distro" | tr '[:lower:]' '[:upper:]')_BASE_IMAGE
pinned_base=$(sed -n "s/^ARG ${base_arg}=//p" "$(dirname "$0")/../$distro/Dockerfile" 2>/dev/null | head -n 1)
assert_eq "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.base.name"}}' "$IMAGE")" \
  "${pinned_base:-<no ARG $base_arg in $distro/Dockerfile>}" \
  "org.opencontainers.image.base.name is the pinned $distro base"
assert_contains "$labels" "\"software.angie.version\":\"$(docker run --rm --label "$SMOKE_RUN_LABEL" \
  --entrypoint sh "$IMAGE" -c 'angie -v 2>&1 | sed -n "s|.*Angie/||p"')\"" \
  "software.angie.version matches the installed binary"

# --- HEALTHCHECK ignores http_proxy from the environment ---
# A proxy in the container environment would route the 127.0.0.1 probe through
# it and mark a healthy server unhealthy. The command is taken from the image
# itself; the control (plain wget with the same variables) must fail, or the
# proxy had no effect and the probe proved nothing. wait_healthy is unusable
# here: its own wget would go through the proxy.
hc_cmd=$(docker inspect -f '{{index .Config.Healthcheck.Test 1}}' "$IMAGE")
cid=$(start -e http_proxy=http://192.0.2.1:9 -e HTTP_PROXY=http://192.0.2.1:9)
hc_ok=no
for _ in $(seq 1 60); do
  if docker exec "$cid" sh -c "$hc_cmd" >/dev/null 2>&1; then hc_ok=yes; break; fi
  sleep 0.5
done
assert_eq "$hc_ok" "yes" "the HEALTHCHECK command passes with http_proxy and HTTP_PROXY set to a dead proxy"
if docker exec "$cid" wget -q --tries=1 -T 3 --header='Host: healthz-catchall.invalid' \
  -O /dev/null "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
  fail "control: a plain wget with the proxy variables set fails (the proxy is not in effect)"
else
  pass "control: a plain wget with the proxy variables set fails"
fi
docker rm -f "$cid" >/dev/null

# --- CA store survives the build; https upstreams verify ---
# Proxying to https:// with proxy_ssl_verify needs the root store at config
# parse time (`[emerg] cannot load certificate ... BIO_new_file() failed`).
# On debian it hangs on ca-certificates surviving `apt-mark auto` plus
# --auto-remove. 100 roots is a floor against a degenerate file, not a
# measurement.
ca_bundle=/etc/ssl/certs/ca-certificates.crt
roots=$(docker run --rm --label "$SMOKE_RUN_LABEL" --entrypoint sh "$IMAGE" \
  -c "grep -c 'BEGIN CERTIFICATE' $ca_bundle 2>/dev/null || true" 2>/dev/null)
case "$roots" in '' | *[!0-9]*) roots=0 ;; esac
if [ "$roots" -ge 100 ]; then
  pass "the image carries a CA store ($roots roots in $ca_bundle)"
else
  fail "the image carries a CA store (found $roots roots in $ca_bundle)"
fi
catmp=$(mktemp -d); tmpdirs="$tmpdirs $catmp"; chmod 755 "$catmp"
cat >"$catmp/tls-upstream.conf" <<EOF
server {
  listen 8098;
  location / {
    proxy_pass https://127.0.0.1:8443;
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate $ca_bundle;
  }
}
EOF
chmod 644 "$catmp/tls-upstream.conf"
cid=$(start --read-only --tmpfs /data:rw,noexec,nosuid,nodev,mode=1777 \
  -v "$catmp:/etc/angie/custom/http.d:ro")
if wait_healthy "$cid"; then
  pass "a vhost verifying an https upstream against the CA store starts"
else
  fail "a vhost verifying an https upstream against the CA store starts"
  docker logs "$cid" 2>&1 | grep -i emerg | head -2 || true
fi
docker rm -f "$cid" >/dev/null

# --- Status API refuses the public port; answers on its own ---
# Two servers on one socket would expose the API both ways: a Host-less request
# reaches the empty-name server, `Host: status_api` matches by exact name past
# the catch-all `return 444`. The snippet has no access control of its own, so
# the toggle must refuse, and the message is matched so an unrelated failure
# (template typo, failed angie -t) does not count as the refusal.
run_to_exit -e ANGIE_STATUS_API_ENABLED=1 -e "ANGIE_STATUS_API_PORT=$PORT" "$IMAGE"
assert_exit_one "Status API on the public port $PORT" "ANGIE_STATUS_API_PORT must not be $PORT"
# The other half: the refusal must not be "fixed" by breaking Host-less
# scrapers on the dedicated port.
cid=$(start -e ANGIE_STATUS_API_ENABLED=1)
wait_healthy "$cid" || fail "Status API dedicated-port container is healthy"
assert_contains "$(raw_hostless_get "$cid" 8181 /status/)" '"angie"' \
  "dedicated port: a Host-less GET /status/ serves the JSON"
assert_contains "$(raw_hostless_get "$cid" 8181 /metrics)" "angie_connections_accepted" \
  "dedicated port: a Host-less GET /metrics serves Prometheus"
status_angie=$(docker exec "$cid" wget -q --tries=1 -T 3 -O - http://127.0.0.1:8181/status/angie/ 2>/dev/null || true)
assert_contains "$status_angie" '"version"' "dedicated port: /status/angie/ answers with a Host header"
assert_lacks "$status_angie" "config_files" "the Status API keeps api_config_files off"
docker rm -f "$cid" >/dev/null
# A port wider than a machine word must be cut by length before `[ -lt ]`,
# which would print its own error and let the value through.
long_port=99999999999999999999
run_to_exit -e ANGIE_STATUS_API_ENABLED=1 -e "ANGIE_STATUS_API_PORT=$long_port" "$IMAGE"
assert_exit_one "a 20-digit ANGIE_STATUS_API_PORT" "ANGIE_STATUS_API_PORT out of range 1-65535: $long_port"
assert_lacks "$exit_log" "$long_port: out of range" "the 20-digit status port never reaches busybox arithmetic"
assert_lacks "$exit_log" "Illegal number" "the 20-digit status port never reaches dash arithmetic"
# The package's `prometheus_all.conf` template may be declared once; the toggle
# includes it, so a second include from custom must fail loudly (documented
# limitation). The documented alternative - an own listener including only
# status-api-locations.conf - must work next to the toggle. The quotes are
# escaped: the angie -t output is a field of a JSON log record.
promtmp=$(mktemp -d); tmpdirs="$tmpdirs $promtmp"
mkdir -p "$promtmp/http-conf.d" "$promtmp/http.d"
printf 'include prometheus_all.conf;\n' >"$promtmp/http-conf.d/99-prom.conf"
chmod -R 755 "$promtmp"; chmod 644 "$promtmp/http-conf.d/99-prom.conf"
run_to_exit -e ANGIE_STATUS_API_ENABLED=1 -v "$promtmp:/etc/angie/custom:ro" "$IMAGE"
assert_exit_one "the Status API toggle plus a custom include prometheus_all.conf" \
  'duplicate Prometheus template \"all\"'
rm -f "$promtmp/http-conf.d/99-prom.conf"
printf 'server {\n  listen 8097;\n  include snippets/status-api-locations.conf;\n}\n' >"$promtmp/http.d/stats.conf"
chmod 644 "$promtmp/http.d/stats.conf"
cid=$(start -e ANGIE_STATUS_API_ENABLED=1 -v "$promtmp:/etc/angie/custom:ro")
wait_healthy "$cid" || fail "the toggle plus an own status listener starts"
assert_contains "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - http://127.0.0.1:8097/metrics 2>/dev/null || true)" \
  "angie_connections_accepted" "an own listener serves /metrics from the toggle's template"
docker rm -f "$cid" >/dev/null

# --- Snippets work from a consumer vhost ---
# snippets/ is the interface for includes inside server {} and location {},
# which a toggle cannot provide. The relative include path resolves from the
# prefix (/data/conf), not from the including file, so the same line works from
# /etc/angie/custom; were that to break, the start fails here.
sntmp=$(mktemp -d); tmpdirs="$tmpdirs $sntmp"; chmod 755 "$sntmp"
cat >"$sntmp/consumer.conf" <<'EOF'
include prometheus_all.conf;

server {
  listen 8095;
  status_zone consumer_probe;

  include snippets/healthz.conf;
  include snippets/deny-dotfiles.conf;
  include snippets/robots-disallow-all.conf;

  # The trap deny-dotfiles is written as a server-level `if` for: with ^~ on the
  # longest prefix, regex locations are skipped and a location-based variant
  # would serve /static/.git/config from here.
  location ^~ /static/ {
    default_type text/plain;
    return 200 "static\n";
  }

  # A handler under the snippet's exception; without it the /.well-known/
  # probe would test a missing location (404 either way), not the exception.
  location ^~ /.well-known/ {
    default_type text/plain;
    return 200 "acme\n";
  }

  location = /hdr {
    include snippets/proxy-headers.conf;
    proxy_pass http://127.0.0.1:8096;
  }
}

server {
  listen 8096;
  location / {
    return 200 "proto=$http_x_forwarded_proto xff=$http_x_forwarded_for rid=$http_x_request_id\n";
  }
}

server {
  listen 8097;
  include snippets/status-api-locations.conf;
}
EOF
chmod 644 "$sntmp/consumer.conf"
cid=$(start -v "$sntmp:/etc/angie/custom/http.d:ro")
if wait_healthy "$cid"; then
  pass "a consumer vhost including the shipped snippets starts"
else
  fail "a consumer vhost including the shipped snippets starts"
  docker logs "$cid" 2>&1 | grep -i emerg | head -2 || true
fi
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - http://127.0.0.1:8095/healthz 2>/dev/null || true)" \
  "ok" "snippets/healthz.conf answers on the consumer listener"
hdr=$(docker exec "$cid" wget -q --tries=1 -T 3 -O - --header 'X-Forwarded-For: 203.0.113.9' \
  --header 'X-Request-ID: client-supplied' http://127.0.0.1:8095/hdr 2>/dev/null || true)
assert_contains "$hdr" "proto=http" "snippets/proxy-headers.conf sets X-Forwarded-Proto"
assert_contains "$hdr" "xff=127.0.0.1" "snippets/proxy-headers.conf replaces X-Forwarded-For"
assert_lacks "$hdr" "203.0.113.9" "the client-supplied X-Forwarded-For does not survive the snippet"
assert_lacks "$hdr" "client-supplied" "the client-supplied X-Request-ID is replaced by \$request_id"
consumer_status=$(docker exec "$cid" wget -q --tries=1 -T 3 -O - http://127.0.0.1:8097/status/angie/ 2>/dev/null || true)
assert_contains "$consumer_status" '"version"' \
  "snippets/status-api-locations.conf serves /status/ on the consumer listener"
assert_lacks "$consumer_status" "config_files" "the consumer status listener keeps api_config_files off"
assert_contains "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - http://127.0.0.1:8097/metrics 2>/dev/null || true)" \
  "angie_" "snippets/status-api-locations.conf serves /metrics"
# /static/.git/config pins the form (condition, not location), /.env the reach
# (no name list covers it), /.well-known/ the one exception ACME needs.
assert_eq "$(http_status "$cid" 8095 /.git/config)" "404" \
  "snippets/deny-dotfiles.conf closes a top-level dotfile directory"
assert_eq "$(http_status "$cid" 8095 /static/.git/config)" "404" \
  "snippets/deny-dotfiles.conf holds behind a consumer's ^~ prefix location"
assert_eq "$(http_status "$cid" 8095 /.env)" "404" \
  "snippets/deny-dotfiles.conf closes a dotfile no name list would cover"
assert_eq "$(http_status "$cid" 8095 /static/.GIT/config)" "404" \
  "snippets/deny-dotfiles.conf closes an upper-case variant too"
assert_eq "$(http_status "$cid" 8095 /.WELL-KNOWN/tok)" "404" \
  "the exception is literal: an upper-case .WELL-KNOWN is not an escape"
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - http://127.0.0.1:8095/.well-known/acme-challenge/tok 2>/dev/null || true)" \
  "acme" "the ACME path reaches its location, so certificates keep being issued"
assert_eq "$(http_status "$cid" 8095 /static/x)" "200" \
  "snippets/deny-dotfiles.conf leaves legitimate static paths alone"
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - http://127.0.0.1:8095/robots.txt 2>/dev/null || true)" \
  "$(printf 'User-agent: *\nDisallow: /')" "snippets/robots-disallow-all.conf serves the full disallow body"
assert_contains "$(resp_headers "$cid" http://127.0.0.1:8095/robots.txt)" "Content-Type: text/plain" \
  "snippets/robots-disallow-all.conf overrides the octet-stream default"
docker rm -f "$cid" >/dev/null

# --- $_stock_loopback survives removing the shipped vhost ---
# healthz.conf needs $_stock_loopback, declared by the http-context
# 010-common.conf, not by http.d/default.conf. Declared inside the vhost, the
# same probe gives `[emerg] unknown "_stock_loopback" variable`.
lbtmp=$(mktemp -d); tmpdirs="$tmpdirs $lbtmp"; chmod 755 "$lbtmp"
printf 'server {\n  listen 8098;\n  include snippets/healthz.conf;\n}\n' >"$lbtmp/consumer.conf"
chmod 644 "$lbtmp/consumer.conf"
cid=$(start -v "$lbtmp:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "loopback-decoupling container is healthy"
docker exec "$cid" rm -f /data/conf/http.d/default.conf
if conf_test "$cid" >/dev/null 2>&1; then
  pass "the configuration stays valid without the shipped vhost"
else
  fail "removing the shipped vhost breaks angie -t (the declaration is tied to it)"
fi
docker rm -f "$cid" >/dev/null

# --- A consumer takes default_server; the HEALTHCHECK keeps its host ---
# The shipped vhost carries no default_server. Without a Host header /healthz
# must reach the CONSUMER body (the default did move); with
# `Host: healthz-catchall.invalid` it must stay `ok`, the exact name beating the
# default - drop that name and the HEALTHCHECK goes green on the consumer body.
# The fixture is named `_` like a typical catch-all: a shipped vhost named `_`
# would log `conflicting server name "_"` on every such start.
dstmp=$(mktemp -d); tmpdirs="$tmpdirs $dstmp"; chmod 755 "$dstmp"
cat >"$dstmp/site.conf" <<EOF
server {
  listen $PORT default_server;
  server_name _;
  location / { return 200 "consumer-catchall\n"; }
}
EOF
chmod 644 "$dstmp/site.conf"
cid=$(start -v "$dstmp:/etc/angie/custom/http.d:ro")
if wait_healthy "$cid"; then
  pass "a consumer vhost may declare its own default_server"
else
  fail "a consumer default_server breaks startup (duplicate default server?)"
fi
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - "http://127.0.0.1:$PORT/healthz" 2>/dev/null || true)" \
  "consumer-catchall" "without the host header /healthz reaches the consumer, so the default did move"
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 3 --header='Host: healthz-catchall.invalid' \
  -O - "http://127.0.0.1:$PORT/healthz" 2>/dev/null || true)" "ok" \
  "the image keeps its healthz by server name, whoever owns default_server"
assert_contains "$(raw_hostless_get "$cid" "$PORT" /)" "consumer-catchall" \
  "a Host-less request reaches the consumer, not the shipped catch-all"
assert_lacks "$(docker logs "$cid" 2>&1)" "conflicting server name" \
  "the shipped vhost is not named _, so a typical consumer catch-all warns nothing"
docker rm -f "$cid" >/dev/null

# --- A server in custom/http-conf.d does not steal the default ---
# The first server declared on an address is its default, so the include order
# in angie.conf carries the guarantee: with custom/http-conf.d above http.d this
# probe gets the consumer body instead of 444, with no warning logged.
hctmp=$(mktemp -d); tmpdirs="$tmpdirs $hctmp"
mkdir -p "$hctmp/http-conf.d"
cat >"$hctmp/http-conf.d/900-site.conf" <<EOF
server {
  listen $PORT;
  server_name app.example;
  location / { return 200 "consumer-in-httpconf\n"; }
}
EOF
chmod -R 755 "$hctmp"; chmod 644 "$hctmp/http-conf.d/900-site.conf"
cid=$(start -v "$hctmp:/etc/angie/custom:ro")
wait_healthy "$cid" || fail "http-conf.d ordering container is healthy"
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - --header='Host: unknown.invalid' \
  "http://127.0.0.1:$PORT/" 2>/dev/null || true)" "" \
  "the shipped catch-all still answers 444 for an unknown host"
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - --header='Host: app.example' \
  "http://127.0.0.1:$PORT/" 2>/dev/null || true)" "consumer-in-httpconf" \
  "the consumer vhost in http-conf.d serves its own server_name"
docker rm -f "$cid" >/dev/null

# --- $_stock_loopback does not trust X-Forwarded-For ---
# With real_ip, $remote_addr becomes the header value, so the loopback gate keys
# on $realip_remote_addr. The control (a log line with remote_addr 127.0.0.1)
# proves real_ip accepted the neighbour's header; without it a 404 would also
# mean "real_ip did nothing". /healthz itself has access_log off.
cid=$(start -e ANGIE_REAL_IP_FROM=172.16.0.0/12,192.168.0.0/16,10.0.0.0/8)
wait_healthy "$cid" || fail "loopback-vs-real-ip container is healthy"
cip=$(container_ip "$cid")
if [ -n "$cip" ]; then
  sibling_status "http://$cip:$PORT/" --header 'X-Forwarded-For: 127.0.0.1' >/dev/null
  assert_contains "$(wait_logs "$cid" '"remote_addr":"127.0.0.1"')" '"remote_addr":"127.0.0.1"' \
    "control: real_ip takes X-Forwarded-For: 127.0.0.1 from the trusted neighbour"
  assert_eq "$(sibling_status "http://$cip:$PORT/healthz" --header 'X-Forwarded-For: 127.0.0.1' \
    --header 'Host: healthz-catchall.invalid')" "404" \
    "a forged X-Forwarded-For: 127.0.0.1 does not pass the loopback gate of /healthz"
else
  fail "could not determine the container IP for the loopback-vs-real-ip test"
fi
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 3 --header='Host: healthz-catchall.invalid' \
  -O - "http://127.0.0.1:$PORT/healthz" 2>/dev/null || true)" "ok" \
  "with real_ip on, /healthz from inside the container still answers ok"
docker rm -f "$cid" >/dev/null

# --- Every image variable carries the $_stock_ prefix ---
# map/geo/geoip2 variables are overridable and custom/http-conf.d is included
# after the image tree, so a name clash with a consumer recipe is silent. The
# check runs on the rendered config (templates, entrypoint substitutions); the
# name is matched with its dollar, since `time_ms` is a substring of
# `$_stock_time_ms`.
cid=$(start -e ANGIE_MAP_WEBSOCKET_ENABLED=1)
wait_healthy "$cid" || fail "prefix audit container is healthy"
conf=$(dump_conf "$cid")
assert_contains "$conf" "\$_stock_connection_upgrade" "the websocket map declares the prefixed variable"
assert_contains "$conf" "\$_stock_time_ms" "the json log format uses the prefixed timestamp"
for var in connection_upgrade loopback time_ms geoip2_country_code; do
  assert_lacks "$conf" "\$$var" "no unprefixed \$$var survives"
done
docker rm -f "$cid" >/dev/null

# --- TLS policy: AEAD only, no session tickets ---
# 050-ssl.conf is active by default and applies to every consumer TLS listener.
# The wire probes need openssl in the image (debian only). The control listener
# overrides the policy and must negotiate CBC and issue a ticket, or a refusal
# would mean "the client cannot" as much as "the policy works".
cid=$(start)
wait_healthy "$cid" || fail "TLS policy container is healthy"
conf=$(dump_conf "$cid")
assert_contains "$conf" "ssl_session_tickets off;" "050-ssl.conf turns session tickets off"
ssl_ciphers=$(printf '%s\n' "$conf" | sed -n 's/^ssl_ciphers \(.*\);$/\1/p' | head -1)
non_aead=""
for c in $(printf '%s' "$ssl_ciphers" | tr ':' ' '); do
  case "$c" in *-GCM-* | *-CHACHA20-POLY1305) ;; *) non_aead="$non_aead $c" ;; esac
done
if [ -n "$ssl_ciphers" ] && [ -z "$non_aead" ]; then
  pass "ssl_ciphers lists AEAD suites only"
else
  fail "ssl_ciphers lists AEAD suites only (got '$ssl_ciphers', non-AEAD:$non_aead)"
fi
has_openssl=$(docker exec "$cid" sh -c 'command -v openssl' 2>/dev/null || true)
docker rm -f "$cid" >/dev/null
if [ -n "$has_openssl" ]; then
  tltmp=$(mktemp -d); tmpdirs="$tmpdirs $tltmp"
  mkdir -p "$tltmp/tls" "$tltmp/http.d"
  # The image's openssl writes under its own uid: 0777 while writing, then 0755.
  chmod 777 "$tltmp/tls"
  docker run --rm --label "$SMOKE_RUN_LABEL" --entrypoint openssl -v "$tltmp/tls:/out" "$IMAGE" \
    req -x509 -newkey rsa:2048 -nodes -keyout /out/key.pem -out /out/cert.pem \
    -days 1 -subj /CN=tls.probe >/dev/null 2>&1 || true
  chmod 755 "$tltmp" "$tltmp/tls" "$tltmp/http.d"
  cat >"$tltmp/http.d/tls.conf" <<'EOF'
server {
  listen 8443 ssl;
  ssl_certificate /etc/angie/custom/tls/cert.pem;
  ssl_certificate_key /etc/angie/custom/tls/key.pem;
  return 200 "tls-stock\n";
}
server {
  listen 8444 ssl;
  ssl_certificate /etc/angie/custom/tls/cert.pem;
  ssl_certificate_key /etc/angie/custom/tls/key.pem;
  ssl_ciphers HIGH:!aNULL;
  ssl_session_tickets on;
  return 200 "tls-control\n";
}
EOF
  chmod 644 "$tltmp/http.d/tls.conf"
  cid=$(start -v "$tltmp/tls:/etc/angie/custom/tls:ro" -v "$tltmp/http.d:/etc/angie/custom/http.d:ro")
  wait_healthy "$cid" || fail "a consumer TLS listener with a generated certificate starts"
  # stdin of docker exec without -i is closed, so s_client exits after the handshake.
  tls_probe() { # cid port [s_client args...]
    __tp_cid=$1
    __tp_port=$2
    shift 2
    timeout 30 docker exec "$__tp_cid" openssl s_client -connect "127.0.0.1:$__tp_port" -tls1_2 "$@" 2>&1 || true
  }
  assert_contains "$(tls_probe "$cid" 8444 -cipher ECDHE-RSA-AES256-SHA)" "Cipher is ECDHE-RSA-AES256-SHA" \
    "TLS control: the client negotiates a CBC suite where the policy allows it"
  assert_contains "$(tls_probe "$cid" 8443 -cipher ECDHE-RSA-AES256-SHA)" "Cipher is (NONE)" \
    "TLS: the stock policy refuses the same CBC suite"
  tls_stock=$(tls_probe "$cid" 8443)
  case "$tls_stock" in
  *"Cipher is ECDHE-"*-GCM-* | *"Cipher is ECDHE-"*-CHACHA20-POLY1305*)
    pass "TLS: an unrestricted client gets an AEAD suite from the stock policy" ;;
  *) fail "TLS: an unrestricted client gets an AEAD suite (got: $(printf '%s\n' "$tls_stock" | grep 'Cipher is' | head -1))" ;;
  esac
  assert_contains "$(tls_probe "$cid" 8444)" "TLS session ticket" \
    "TLS control: a listener with tickets on issues one"
  assert_lacks "$tls_stock" "TLS session ticket" "TLS: the stock policy issues no session ticket"
  docker rm -f "$cid" >/dev/null
else
  printf '  skip TLS wire probes (no openssl in %s)\n' "$IMAGE"
fi

# --- Real-IP: guards and read-only rendering ---
# The toggle renders through a temp file in the live tree, not bare mktemp in
# /tmp, which is read-only under --read-only (`mktemp: : Read-only file
# system`). The leftover check lists with -a: the temp name starts with a dot.
cid=$(start --read-only --tmpfs /data:rw,noexec,nosuid,nodev,mode=1777 -e ANGIE_REAL_IP_FROM=10.0.0.0/8)
if wait_healthy "$cid"; then
  pass "read-only rootfs: the real-ip toggle renders its snippet"
else
  fail "read-only rootfs: the real-ip toggle renders its snippet"
fi
assert_contains "$(dump_conf "$cid")" "set_real_ip_from 10.0.0.0/8" \
  "read-only rootfs: the trusted proxy reaches the effective config"
assert_lacks "$(docker exec "$cid" ls -a /data/conf/http-conf-available.d/ 2>/dev/null || true)" \
  ".real-ip-directives." "read-only rootfs: no rendering temp file is left behind"
docker rm -f "$cid" >/dev/null
# The list is split unquoted, which also globs against the entrypoint cwd (/):
# without `set -f` a `*` entry would be reported as `bin`.
run_to_exit -e 'ANGIE_REAL_IP_FROM=*' "$IMAGE"
assert_exit_one "a glob ANGIE_REAL_IP_FROM entry" \
  "unsupported characters (allowed: 0-9 a-f A-F : . /): *"
run_to_exit -e ANGIE_REAL_IP_FROM=10.0.0.0/8 -e 'ANGIE_REAL_IP_HEADER=X-Forwarded-For;evil' "$IMAGE"
assert_exit_one "an unsafe ANGIE_REAL_IP_HEADER" "ANGIE_REAL_IP_HEADER has unsupported characters"
run_to_exit -e ANGIE_REAL_IP_FROM=10.0.0.0/8 -e ANGIE_REAL_IP_RECURSIVE=maybe "$IMAGE"
assert_exit_one "ANGIE_REAL_IP_RECURSIVE outside on/off" "ANGIE_REAL_IP_RECURSIVE must be 'on' or 'off', got: maybe"
# Trusting every address lets any client forge its own; the second entry
# checks the guard reads every entry, a /1 pair covers the space like /0, and
# leading zeros do not lengthen a mask.
run_to_exit -e ANGIE_REAL_IP_FROM=0.0.0.0/0 "$IMAGE"
assert_exit_one "real-ip with 0.0.0.0/0" "ANGIE_REAL_IP_FROM entry 0.0.0.0/0 trusts every address"
run_to_exit -e ANGIE_REAL_IP_FROM=10.0.0.0/8,::/0 "$IMAGE"
assert_exit_one "real-ip with ::/0 as the second entry" "ANGIE_REAL_IP_FROM entry ::/0 trusts every address"
run_to_exit -e ANGIE_REAL_IP_FROM=0.0.0.0/1,128.0.0.0/1 "$IMAGE"
assert_exit_one "real-ip with a pair of /1 masks" "ANGIE_REAL_IP_FROM entry 0.0.0.0/1 has a prefix shorter than /8"
run_to_exit -e ANGIE_REAL_IP_FROM=10.0.0.0/0007 "$IMAGE"
assert_exit_one "real-ip with /0007" "ANGIE_REAL_IP_FROM entry 10.0.0.0/0007 has a prefix shorter than /8"
run_to_exit -e ANGIE_REAL_IP_FROM=10.0.0.0/8,8000::/15 "$IMAGE"
assert_exit_one "real-ip with an IPv6 prefix shorter than /16" \
  "ANGIE_REAL_IP_FROM entry 8000::/15 has a prefix shorter than /16"
cid=$(start -e ANGIE_REAL_IP_FROM=10.0.0.0/8,fd00::/16)
if wait_healthy "$cid"; then pass "real-ip accepts the boundary prefixes /8 and /16";
else fail "real-ip accepts the boundary prefixes /8 and /16"; fi
docker rm -f "$cid" >/dev/null

# --- GeoIP2 end to end with a real database ---
# The orphan and refusal sections never load a database. Here the map renders,
# the module loads, the access log switches to the geoip2 format and the
# variable resolves on the wire; the address comes through real-ip, so the
# expected country does not depend on the docker subnet.
gtmp=$(mktemp -d); tmpdirs="$tmpdirs $gtmp"
make_mmdb "$gtmp/Country.mmdb"
chmod 755 "$gtmp"; chmod 644 "$gtmp/Country.mmdb"
cid=$(start -v "$gtmp:/geo:ro" -e GEOIP2_DB_COUNTRY=/geo/Country.mmdb \
  -e ANGIE_LOG_FORMAT_LOGFMT_GEOIP2=1 -e ANGIE_LOG_LOGFMT_GEOIP2=1 \
  -e ANGIE_REAL_IP_FROM=172.16.0.0/12,192.168.0.0/16,10.0.0.0/8)
if wait_healthy "$cid"; then
  pass "geoip2: the container starts with a real mmdb database"
else
  fail "geoip2: the container starts with a real mmdb database"
  docker logs "$cid" 2>&1 | grep -iE 'emerg|"level":"error"' | head -2 || true
fi
conf=$(dump_conf "$cid")
assert_contains "$conf" "geoip2 /geo/Country.mmdb" "GEOIP2_DB_COUNTRY renders the geoip2 map"
assert_contains "$conf" "\$_stock_geoip2_country_code default=ZZ" "the rendered map declares the country variable"
assert_contains "$(docker exec "$cid" ls /data/conf/modules.d/ 2>/dev/null || true)" "http_geoip2.conf" \
  "the geoip2 module is loaded"
assert_contains "$conf" "access_log /dev/stdout angie_logfmt_with_geoip" \
  "ANGIE_LOG_LOGFMT_GEOIP2 switches the access log to the geoip2 format"
assert_eq "$(printf '%s\n' "$conf" | grep -c 'access_log /dev/stdout' || true)" "1" \
  "the geoip2 access log keeps exactly one access_log"
cip=$(container_ip "$cid")
if [ -n "$cip" ]; then
  sibling_status "http://$cip:$PORT/" --header 'X-Forwarded-For: 203.0.113.7' >/dev/null
  assert_contains "$(wait_logs "$cid" 'country="XX"')" 'country="XX"' \
    "geoip2 wire: an address inside the fixture network resolves to its country"
else
  fail "could not determine the container IP for the geoip2 wire test"
fi
docker exec "$cid" wget -q --tries=1 -T 3 -O /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null || true
assert_contains "$(wait_logs "$cid" 'country="ZZ"')" 'country="ZZ"' \
  "geoip2 wire: an address outside the database falls back to default=ZZ"
docker rm -f "$cid" >/dev/null
# The json variant has its own snippet and variable pair.
cid=$(start -v "$gtmp:/geo:ro" -e GEOIP2_DB_COUNTRY=/geo/Country.mmdb -e ANGIE_LOG_JSON_GEOIP2=1)
wait_healthy "$cid" || fail "json-with-geoip2 container is healthy"
assert_contains "$(dump_conf "$cid")" "access_log /dev/stdout angie_json_with_geoip" \
  "ANGIE_LOG_JSON_GEOIP2 switches the access log to the geoip2 json format"
docker exec "$cid" wget -q --tries=1 -T 3 -O /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null || true
assert_contains "$(wait_logs "$cid" '"country":')" '"country":"ZZ"' \
  "geoip2 json wire: the record carries the country field"
docker rm -f "$cid" >/dev/null
cid=$(start -v "$gtmp:/geo:ro" -e GEOIP2_DB_COUNTRY=/geo/Country.mmdb -e ANGIE_LOG_FORMAT_JSON_GEOIP2=1)
wait_healthy "$cid" || fail "json-with-geoip2 format-only container is healthy"
conf=$(dump_conf "$cid")
assert_contains "$conf" "log_format angie_json_with_geoip" \
  "ANGIE_LOG_FORMAT_JSON_GEOIP2 registers the geoip2 json format"
assert_contains "$conf" "access_log /dev/stdout angie_json;" \
  "ANGIE_LOG_FORMAT_JSON_GEOIP2 leaves the default access log alone"
docker rm -f "$cid" >/dev/null
# Under `set -e` a failing left side of `&&` does not stop the script, so the
# start would go on without the module until an opaque final angie -t. The
# planted angie-ctl precedes the real one in PATH and fails on the geoip2
# module only (ngx_ctl prepends --no-test, hence the suffix match).
printf '#!/bin/sh\ncase "$*" in\n*"mod en http_geoip2.conf")\n  echo "fake angie-ctl failure" >&2\n  exit 1\n  ;;\nesac\nexec /usr/local/bin/angie-ctl "$@"\n' \
  >"$gtmp/angie-ctl"
chmod 755 "$gtmp/angie-ctl"
run_to_exit -v "$gtmp/angie-ctl:/usr/local/sbin/angie-ctl:ro" -v "$gtmp:/geo:ro" \
  -e GEOIP2_DB_COUNTRY=/geo/Country.mmdb "$IMAGE"
assert_exit_one "a failing angie-ctl in 50-geoip2.sh" \
  "/docker-entrypoint.d/50-geoip2.sh failed with exit 1, aborting startup"
assert_contains "$exit_log" "fake angie-ctl failure" "sanity: the planted angie-ctl is the one the toggle called"
assert_lacks "$exit_log" "assembled configuration failed" \
  "the toggle stops at the failure instead of leaving it to the final angie -t"

# --- Access-log formats: selection, declaration, priority, quoting ---
# A typo in a 030-log-format-*/040-log-* snippet would surface at the user:
# angie parses every declared log_format, so declaring all at once and staying
# healthy proves the final angie -t accepted them.
for pair in extended:EXTENDED matomo:MATOMO logfmt:LOGFMT; do
  fmt=${pair%%:*}
  var=${pair#*:}
  cid=$(start -e "ANGIE_LOG_$var=1")
  wait_healthy "$cid" || fail "ANGIE_LOG_$var container is healthy"
  conf=$(dump_conf "$cid")
  assert_contains "$conf" "access_log /dev/stdout angie_$fmt;" "ANGIE_LOG_$var selects the $fmt format"
  assert_eq "$(printf '%s\n' "$conf" | grep -c 'access_log /dev/stdout' || true)" "1" \
    "switching to $fmt keeps exactly one access_log"
  docker rm -f "$cid" >/dev/null
done
cid=$(start -e ANGIE_LOG_FORMAT_EXTENDED=1 -e ANGIE_LOG_FORMAT_LOGFMT=1 \
  -e ANGIE_LOG_FORMAT_MAIN=1 -e ANGIE_LOG_FORMAT_MATOMO=1)
wait_healthy "$cid" || fail "all four log formats can be declared at once"
conf=$(dump_conf "$cid")
for fmt in extended logfmt main matomo; do
  assert_contains "$conf" "log_format angie_$fmt " "ANGIE_LOG_FORMAT_* declares angie_$fmt"
done
assert_contains "$conf" "access_log /dev/stdout angie_json;" "declaring formats leaves the default log selected"
docker rm -f "$cid" >/dev/null
# 40-log.sh takes the first match of EXTENDED, JSON, LOGFMT, MAIN, MATOMO; the
# later variable is set first, since the env order must not matter.
cid=$(start -e ANGIE_LOG_JSON=1 -e ANGIE_LOG_EXTENDED=1)
wait_healthy "$cid" || fail "log priority container is healthy"
conf=$(dump_conf "$cid")
assert_contains "$conf" "access_log /dev/stdout angie_extended;" "ANGIE_LOG_EXTENDED wins over ANGIE_LOG_JSON"
assert_eq "$(printf '%s\n' "$conf" | grep -c 'access_log /dev/stdout' || true)" "1" \
  "two ANGIE_LOG_* at once still give exactly one access_log"
docker rm -f "$cid" >/dev/null
cid=$(start -e ANGIE_LOG_MAIN=1 -e ANGIE_LOG_LOGFMT=1)
wait_healthy "$cid" || fail "log priority logfmt-over-main container is healthy"
assert_contains "$(dump_conf "$cid")" "access_log /dev/stdout angie_logfmt;" "ANGIE_LOG_LOGFMT wins over ANGIE_LOG_MAIN"
docker rm -f "$cid" >/dev/null
# Unquoted client-controlled fields would let a Referer append forged
# `status=200 host=...` pairs. After cutting every quoted value exactly one
# `status=` must remain. The Authorization header is base64 of `a status=200:p`.
cid=$(start -e ANGIE_LOG_LOGFMT=1)
wait_healthy "$cid" || fail "logfmt quoting container is healthy"
docker exec "$cid" wget -q --tries=1 -T 3 -O /dev/null \
  --header 'Referer: x" status=200 host=bank.example' \
  --header 'Authorization: Basic YSBzdGF0dXM9MjAwOnA=' \
  "http://127.0.0.1:$PORT/p?x=1%20status=201" 2>/dev/null || true
logfmt_line=$(wait_logs "$cid" 'referrer="x' | grep 'referrer="x' | tail -1 || true)
assert_contains "$logfmt_line" 'referrer="x\x22 status=200 host=bank.example"' \
  "logfmt: the Referer stays inside its quotes, the inner quote escaped"
assert_contains "$logfmt_line" 'remote_user="a status=200"' "logfmt: the Basic user name stays inside its quotes"
assert_contains "$logfmt_line" 'path="/p?x=1%20status=201"' "logfmt: the request path stays inside its quotes"
logfmt_bare=$(printf '%s\n' "$logfmt_line" | sed 's/"[^"]*"//g')
assert_eq "$(printf '%s\n' "$logfmt_bare" | awk -F' status=' '{ print NF - 1 }')" "1" \
  "logfmt: outside the quotes there is exactly one status="
assert_lacks "$logfmt_bare" "bank.example" "logfmt: the forged host= never leaves the quotes"
docker rm -f "$cid" >/dev/null
# Shipped format names carry the angie_ prefix, because a duplicate log_format
# name is fatal: a consumer `log_format json` must coexist with the image.
lftmp=$(mktemp -d); tmpdirs="$tmpdirs $lftmp"; chmod 755 "$lftmp"
printf '%s\n' "log_format json escape=json '{\"consumer\":\"\$status\"}';" >"$lftmp/010-logs.conf"
chmod 644 "$lftmp/010-logs.conf"
cid=$(start -v "$lftmp:/etc/angie/custom/http-conf.d:ro")
if wait_healthy "$cid"; then
  pass "a consumer log_format named json coexists with the shipped formats"
else
  fail "a consumer log_format named json coexists with the shipped formats"
fi
assert_contains "$(dump_conf "$cid")" 'log_format json escape=json' "the consumer format reaches the effective config"
docker rm -f "$cid" >/dev/null

# --- Substitutions and the websocket map on the wire ---
# The module toggles only prove a load_module line; subs_filter must rewrite a
# body, and the map must send `upgrade` with a client Upgrade and `close`
# without one (or keepalive to the upstream breaks on every request).
wstmp=$(mktemp -d); wsconf=$(mktemp -d); tmpdirs="$tmpdirs $wstmp $wsconf"
printf 'SUBS_MARKER_IN\n' >"$wstmp/subs.txt"
cat >"$wstmp/vhost.conf" <<'EOF'
server {
  listen 8085;
  root /etc/angie/custom/http.d;
  subs_filter_types text/plain;
  subs_filter SUBS_MARKER_IN SUBS_MARKER_OUT;
}
server {
  listen 8086;
  location / {
    proxy_pass http://127.0.0.1:8087;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $_stock_connection_upgrade;
  }
}
server {
  listen 8087;
  access_log /dev/stdout wsprobe;
  location / { return 200 "ws-ok\n"; }
}
EOF
printf '%s\n' "log_format wsprobe 'wsprobe up=\$http_upgrade conn=\$http_connection';" >"$wsconf/00-wsprobe.conf"
chmod 755 "$wstmp" "$wsconf"; chmod 644 "$wstmp"/* "$wsconf"/*
cid=$(start -e ANGIE_SUBS_ENABLED=1 -e ANGIE_MAP_WEBSOCKET_ENABLED=1 \
  -v "$wstmp:/etc/angie/custom/http.d:ro" -v "$wsconf:/etc/angie/custom/http-conf.d:ro")
wait_healthy "$cid" || fail "subs and websocket wire container is healthy"
assert_eq "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - http://127.0.0.1:8085/subs.txt 2>/dev/null || true)" \
  "SUBS_MARKER_OUT" "subs_filter rewrites the response body on the wire"
docker exec "$cid" wget -q --tries=1 -T 3 -O /dev/null --header 'Upgrade: websocket' http://127.0.0.1:8086/ 2>/dev/null || true
assert_contains "$(wait_logs "$cid" 'wsprobe up=websocket')" "wsprobe up=websocket conn=upgrade" \
  "a client Upgrade makes the map send Connection: upgrade upstream"
docker exec "$cid" wget -q --tries=1 -T 3 -O /dev/null http://127.0.0.1:8086/ 2>/dev/null || true
assert_contains "$(wait_logs "$cid" 'wsprobe up=- ')" "wsprobe up=- conn=close" \
  "without a client Upgrade the map sends Connection: close upstream"
docker rm -f "$cid" >/dev/null

# --- Autotune never writes worker_processes 0 ---
# The count is a MINIMUM of candidates, so a non-positive one wins: an empty
# cpuset gave `worker_processes 0;`, which angie -t accepts and the master runs
# with no worker at all. The kernel forbids an empty cpuset on a populated
# cgroup, so the cgroup v2 file is replaced by a mount; on a cgroup v1 host
# the script reads another path and the check passes without exercising it.
cputmp=$(mktemp -d); tmpdirs="$tmpdirs $cputmp"
: >"$cputmp/cpuset.cpus.effective"
chmod 755 "$cputmp"; chmod 644 "$cputmp/cpuset.cpus.effective"
cid=$(start -e ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE=1 \
  -v "$cputmp/cpuset.cpus.effective:/sys/fs/cgroup/cpuset.cpus.effective:ro")
wait_healthy "$cid" || fail "empty cpuset: the container serves /healthz"
assert_contains "$(docker exec "$cid" grep -E '^worker_processes [1-9][0-9]*;' /data/conf/angie.conf 2>/dev/null || true)" \
  "worker_processes" "empty cpuset: autotune falls back to a positive worker count"
docker rm -f "$cid" >/dev/null

# --- Angie-only directives work on the wire ---
# max_headers limits the NUMBER of header fields, time_format puts milliseconds
# into the log; a typo in either passes angie -t and breaks only at the user.
# The exact threshold depends on wget's own fields, so both sides are probed.
cid=$(start)
wait_healthy "$cid" || fail "Angie-extras container is healthy"
many_headers() { # cid count
  docker exec "$1" sh -c '
n=$1; port=$2; set --
i=0; while [ "$i" -lt "$n" ]; do set -- "$@" --header "X-P$i: v"; i=$((i+1)); done
wget -S --tries=1 -T 3 -O /dev/null "$@" "http://127.0.0.1:$port/healthz" 2>&1
' sh "$2" "$PORT" 2>&1 || true
}
assert_contains "$(many_headers "$cid" 50)" "200 OK" "max_headers lets an ordinary number of header fields through"
assert_contains "$(many_headers "$cid" 150)" "400 Bad Request" "max_headers rejects too many header fields"
docker exec "$cid" wget -q --tries=1 -T 3 -O /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null || true
ts=$(wait_logs "$cid" '"date":' | grep -o '"date":"[^"]*"' | tail -1 || true)
case "$ts" in
'"date":"'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9]*'"')
  pass "the json date field carries milliseconds" ;;
*) fail "the json date field carries milliseconds (got '$ts')" ;;
esac
docker rm -f "$cid" >/dev/null

# --- ACME: guards, empty certificate, declarative reset ---
# A TLS listener on $acme_cert_* before the first issuance passes angie -t (the
# variable is legitimately empty) and fails only at the handshake; the pair of
# assertions pins that, each alone passes on a working config too.
actmp=$(mktemp -d); tmpdirs="$tmpdirs $actmp"; chmod 755 "$actmp"
cat >"$actmp/tls.conf" <<'EOF'
server {
  listen 8443 ssl;
  server_name acme.probe;
  acme le;
  ssl_certificate $acme_cert_le;
  ssl_certificate_key $acme_cert_key_le;
  location / { return 200 "never reached\n"; }
}
EOF
chmod 644 "$actmp/tls.conf"
cid=$(start -e ANGIE_ACME_ENABLED=1 -e ANGIE_ACME_DIRECTORY=https://127.0.0.1:19999/directory \
  -v "$actmp:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "ACME empty-certificate container is healthy"
assert_eq "$(listeners_on "$cid" 8443)" "1" \
  "with no certificate yet, the TLS listener comes up and startup passes angie -t"
assert_lacks "$(docker exec "$cid" wget -q --tries=1 -T 3 --no-check-certificate -O - https://127.0.0.1:8443/ 2>&1 || true)" \
  "never reached" "but the handshake fails, so nothing is served over TLS before the first issuance"
docker rm -f "$cid" >/dev/null
# Every value is substituted into a directive; the guard text is matched, since
# a `;` would also fail angie -t with exit 1.
run_to_exit -e ANGIE_ACME_ENABLED=1 -e 'ANGIE_ACME_DIRECTORY=https://ca.test/d;worker_processes 99' "$IMAGE"
assert_exit_one "ANGIE_ACME_DIRECTORY out of its charset" "ANGIE_ACME_DIRECTORY has unsupported characters"
run_to_exit -e ANGIE_ACME_ENABLED=1 -e 'ANGIE_ACME_CLIENT=le;evil' "$IMAGE"
assert_exit_one "ANGIE_ACME_CLIENT out of its charset" "ANGIE_ACME_CLIENT must be a non-empty name of A-Za-z0-9 _"
run_to_exit -e ANGIE_ACME_ENABLED=1 -e ANGIE_ACME_DIRECTORY=https://ca.test/dir -e 'ANGIE_ACME_EMAIL=a@b.c;evil' "$IMAGE"
assert_exit_one "ANGIE_ACME_EMAIL out of its charset" \
  "ANGIE_ACME_EMAIL has unsupported characters (allowed: A-Za-z0-9 . _ % + @ -): a@b.c;evil"
run_to_exit -e ANGIE_ACME_ENABLED=1 -e "ANGIE_ACME_HTTP_PORT=$long_port" "$IMAGE"
assert_exit_one "a 20-digit ANGIE_ACME_HTTP_PORT" "ANGIE_ACME_HTTP_PORT out of range 1-65535: $long_port"
assert_lacks "$exit_log" "Illegal number" "the 20-digit ACME port never reaches dash arithmetic"
cid=$(start -e ANGIE_ACME_ENABLED=1 -e ANGIE_ACME_DIRECTORY=https://127.0.0.1:19999/directory \
  -e ANGIE_ACME_EMAIL=ops@example.test -e ANGIE_ACME_CHALLENGE=dns)
wait_healthy "$cid" || fail "ACME email and challenge container is healthy"
assert_contains "$(dump_conf "$cid")" \
  "acme_client le https://127.0.0.1:19999/directory challenge=dns email=ops@example.test;" \
  "ANGIE_ACME_CHALLENGE and ANGIE_ACME_EMAIL are rendered into acme_client"
# Declarative reset in the same run: a disabled ACME must not keep ordering.
docker exec -e ANGIE_ACME_ENABLED=no "$cid" sh /docker-entrypoint.d/40-acme.sh >/dev/null 2>&1 || true
if docker exec "$cid" test -e /data/conf/http-conf.d/080-acme.conf; then
  fail "the ACME snippet is gone after a run with the variable cleared"
else
  pass "the ACME snippet is gone after a run with the variable cleared"
fi
docker rm -f "$cid" >/dev/null

# --- ACME and HSTS stay off by default; HSTS resets declaratively ---
cid=$(start -e ANGIE_HSTS_ENABLED=1)
wait_healthy "$cid" || fail "ACME-off and HSTS-reset container is healthy"
assert_lacks "$(docker exec "$cid" ls /data/conf/http-conf.d 2>/dev/null || true)" "080-acme.conf" \
  "the ACME snippet stays off by default"
docker exec -e ANGIE_HSTS_ENABLED=no "$cid" sh /docker-entrypoint.d/45-hsts.sh >/dev/null 2>&1 || true
assert_lacks "$(docker exec "$cid" ls /data/conf/http-conf.d 2>/dev/null || true)" "056-hsts.conf" \
  "the HSTS snippet is gone after a run with the variable cleared"
docker rm -f "$cid" >/dev/null

# --- ACME challenge port: shared with the built-in listener, not its own ---
# The module opens a dedicated listener only on a free address, and that one
# resets everything but a live token - it would kill an http -> https redirect.
# On the image port no listener is added and the consumer server answers. The
# consumer `acme le` server is required: a client no server references is
# dropped with "defined but not used", and its listener with it.
a55tmp=$(mktemp -d); tmpdirs="$tmpdirs $a55tmp"; chmod 755 "$a55tmp"
cat >"$a55tmp/site.conf" <<EOF
server {
  listen $PORT;
  server_name acme.probe;
  acme le;
  return 301 https://\$host\$request_uri;
}
EOF
chmod 644 "$a55tmp/site.conf"
cid=$(start -e ANGIE_ACME_ENABLED=1 -e ANGIE_ACME_DIRECTORY=https://127.0.0.1:19999/directory \
  -v "$a55tmp:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "ACME shared-port container is healthy"
assert_eq "$(listeners_on "$cid" 8081)" "0" "a matching acme_http_port adds no listener of its own"
assert_eq "$(http_status "$cid" "$PORT" / --header='Host: acme.probe')" "301" \
  "the consumer redirect on the shared port answers as usual"
docker rm -f "$cid" >/dev/null
cid=$(start -e ANGIE_ACME_ENABLED=1 -e ANGIE_ACME_DIRECTORY=https://127.0.0.1:19999/directory \
  -e ANGIE_ACME_HTTP_PORT=8081 -v "$a55tmp:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "ACME free-port container is healthy"
assert_eq "$(listeners_on "$cid" 8081)" "1" \
  "control: a free acme_http_port does get a dedicated listener"
assert_eq "$(raw_hostless_get "$cid" 8081 /)" "" \
  "the dedicated ACME listener resets ordinary requests, so it cannot carry the redirect"
docker rm -f "$cid" >/dev/null

# --- Security headers follow the content type ---
# A ladder: reverting to unconditional add_header literals keeps the first
# assertion green and breaks the rest, which is the regression to catch.
shtmp=$(mktemp -d); tmpdirs="$tmpdirs $shtmp"; chmod 755 "$shtmp"
cat >"$shtmp/site.conf" <<'EOF'
server {
  listen 8094;
  server_name sechdr.probe;
  location = /doc { default_type text/html; return 200 "<p>x</p>"; }
  location = /css { default_type text/css; return 200 "b{}"; }
  location = /png { default_type image/png; return 200 "PNG"; }
}
EOF
chmod 644 "$shtmp/site.conf"
cid=$(start -e ANGIE_SECURITY_HEADERS_ENABLED=1 -v "$shtmp:/etc/angie/custom/http.d:ro")
wait_healthy "$cid" || fail "security-headers map container is healthy"
sh_doc=$(resp_headers "$cid" http://127.0.0.1:8094/doc --header='Host: sechdr.probe')
assert_contains "$sh_doc" "X-Frame-Options: SAMEORIGIN" "a document gets X-Frame-Options"
assert_contains "$sh_doc" "Permissions-Policy: accelerometer=()" "a document gets the Permissions-Policy list"
sh_css=$(resp_headers "$cid" http://127.0.0.1:8094/css --header='Host: sechdr.probe')
assert_contains "$sh_css" "Referrer-Policy: strict-origin-when-cross-origin" \
  "a stylesheet keeps Referrer-Policy (its subrequests carry Referer)"
assert_lacks "$sh_css" "X-Frame-Options" "a stylesheet gets no X-Frame-Options"
sh_png=$(resp_headers "$cid" http://127.0.0.1:8094/png --header='Host: sechdr.probe')
assert_contains "$sh_png" "X-Content-Type-Options: nosniff" "an image keeps the unconditional nosniff"
assert_lacks "$sh_png" "Permissions-Policy" "an image carries none of the document headers"
docker rm -f "$cid" >/dev/null

# --- Cache busting: a versioned name served from one file ---
# The 404 half tells the rewrite apart from a server returning the file for any
# request: gone.v1.css has no base file and try_files must end in 404.
cbtmp=$(mktemp -d); tmpdirs="$tmpdirs $cbtmp"
mkdir -p "$cbtmp/www" "$cbtmp/http.d"
printf 'body{color:red}\n' >"$cbtmp/www/app.css"
cat >"$cbtmp/http.d/site.conf" <<'EOF'
server {
  listen 8096;
  server_name bust.probe;
  root /etc/angie/custom/www;
  include snippets/cache-busting.conf;
}
EOF
chmod -R a+rX "$cbtmp"
cid=$(start -v "$cbtmp:/etc/angie/custom:ro")
wait_healthy "$cid" || fail "cache-busting container is healthy"
assert_contains "$(docker exec "$cid" wget -q --tries=1 -T 3 -O - --header='Host: bust.probe' \
  http://127.0.0.1:8096/app.v123.css 2>/dev/null || true)" "body{color:red}" \
  "a versioned name is served from the single file on disk"
assert_eq "$(http_status "$cid" 8096 /gone.v1.css --header='Host: bust.probe')" "404" \
  "a versioned name whose base file is missing still 404s"
docker rm -f "$cid" >/dev/null

# --- Console Light: password ladder, relative redirect, refusals, none ---
# A wrong password must get 401 (the hash is verified, not any Authorization
# accepted); the slashless redirect must be relative, or behind a TLS proxy it
# would send the browser to plain http with the password in clear text.
# Changing the htpasswd on the host applies without HUP (read per request).
cid=$(start -e ANGIE_CONSOLE_ENABLED=1 -e "ANGIE_CONSOLE_PATH=$console_path" \
  -v "$console:/etc/angie/custom:ro")
wait_healthy "$cid" || fail "Console Light ladder container is healthy"
console_log=$(docker logs "$cid" 2>&1)
assert_contains "$console_log" "console enabled at the secret path (basic auth: /etc/angie/custom/console.htpasswd)" \
  "the entrypoint names the console htpasswd file"
assert_lacks "$console_log" "$console_path" "the entrypoint keeps the secret path out of the log"
assert_eq "$(http_status "$cid" "$PORT" "/$console_path/" '--header=Authorization: Basic Y29uc29sZTp3cm9uZw==')" "401" \
  "Console Light rejects a wrong password"
assert_eq "$(http_status "$cid" "$PORT" "/$console_path" "$auth")" "301" \
  "Console Light redirects the slashless path to the directory"
assert_eq "$(docker exec "$cid" wget -S --tries=1 -T 3 -O /dev/null "$auth" --header='Host: console.example.com' \
  "http://127.0.0.1:$PORT/$console_path" 2>&1 | sed -n 's|^ *Location: ||p' | head -1 || true)" "/$console_path/" \
  "the console redirect Location is relative"
assert_eq "$(http_status "$cid" "$PORT" "/$console_path/assets/app.bundle.js" "$auth")" "200" \
  "the console bundle is served through the alias"
assert_eq "$(http_status "$cid" "$PORT" /other/ "$auth")" "" \
  "any other path in the catch-all is still reset (444)"
cip=$(container_ip "$cid")
assert_eq "$(sibling_status "http://$cip:$PORT/$console_path/" "$auth")" "200" \
  "Console Light answers an external client with credentials"
# Hash of `openssl passwd -6 -salt smoketest renamed`; header base64 of console:renamed.
# shellcheck disable=SC2016 # dollar signs are separators in the crypt hash
printf 'console:%s\n' '$6$smoketest$CTi4MHdXT/AxudO2tsVYurjHcyL88.zsYg4CMveFEXZSL4MR/GCC6B5zjgooICkuAnZ4Xs/kkPuS16HuQpTfI/' \
  >"$console/console.htpasswd"
assert_eq "$(http_status "$cid" "$PORT" "/$console_path/" "$auth")" "401" \
  "after rewriting htpasswd on the host the old password gets 401 without HUP"
assert_eq "$(http_status "$cid" "$PORT" "/$console_path/" '--header=Authorization: Basic Y29uc29sZTpyZW5hbWVk')" "200" \
  "the new password gets 200 without HUP"
printf 'console:%s\n' "$console_hash" >"$console/console.htpasswd"
docker rm -f "$cid" >/dev/null
: >"$console/empty.htpasswd"; chmod 644 "$console/empty.htpasswd"
run_to_exit -e ANGIE_CONSOLE_ENABLED=1 -v "$console:/etc/angie/custom:ro" "$IMAGE"
assert_exit_one "Console Light with an unset path" "ANGIE_CONSOLE_PATH must be a non-empty segment"
run_to_exit -e ANGIE_CONSOLE_ENABLED=1 -e ANGIE_CONSOLE_PATH=abcdefgh/ijklmnopqr -v "$console:/etc/angie/custom:ro" "$IMAGE"
assert_exit_one "Console Light with a slash in the path" "ANGIE_CONSOLE_PATH must be a non-empty segment"
run_to_exit -e ANGIE_CONSOLE_ENABLED=1 -e "ANGIE_CONSOLE_PATH=$console_path" \
  -e ANGIE_CONSOLE_HTPASSWD_FILE=/etc/angie/custom/empty.htpasswd -v "$console:/etc/angie/custom:ro" "$IMAGE"
assert_exit_one "Console Light with an empty htpasswd" "ANGIE_CONSOLE_HTPASSWD_FILE is missing, not a regular file"
run_to_exit -e ANGIE_CONSOLE_ENABLED=1 -e "ANGIE_CONSOLE_PATH=$console_path" \
  -e ANGIE_CONSOLE_HTPASSWD_FILE=/etc/angie/custom -v "$console:/etc/angie/custom:ro" "$IMAGE"
assert_exit_one "Console Light with a directory as htpasswd" "ANGIE_CONSOLE_HTPASSWD_FILE is missing, not a regular file"
run_to_exit -e ANGIE_CONSOLE_ENABLED=1 -e "ANGIE_CONSOLE_PATH=$console_path" \
  -e ANGIE_CONSOLE_HTPASSWD_FILE=etc/angie/custom/console.htpasswd -v "$console:/etc/angie/custom:ro" "$IMAGE"
assert_exit_one "Console Light with a relative htpasswd path" "ANGIE_CONSOLE_HTPASSWD_FILE must be an absolute path"
cid=$(start -e ANGIE_CONSOLE_ENABLED=1 -e "ANGIE_CONSOLE_PATH=$console_path" -e ANGIE_CONSOLE_HTPASSWD_FILE=none)
wait_healthy "$cid" || fail "Console Light without basic auth starts"
assert_contains "$(docker logs "$cid" 2>&1)" \
  "console basic auth disabled: /status/ is readable by anyone who learns the path" \
  "ANGIE_CONSOLE_HTPASSWD_FILE=none logs the warning"
assert_eq "$(http_status "$cid" "$PORT" "/$console_path/api/angie/")" "200" \
  "ANGIE_CONSOLE_HTPASSWD_FILE=none serves the API without credentials"
assert_lacks "$(dump_conf "$cid" | grep -v '^ *#' || true)" "auth_basic" \
  "ANGIE_CONSOLE_HTPASSWD_FILE=none renders no auth_basic"
docker rm -f "$cid" >/dev/null

# --- A customized angie.conf: in-place editors leave unknown lines alone ---
# 31 and 32 edit angie.conf only on the known line form; a replaced file must
# get a warning and stay untouched, not a guess or a failed start. The fixture
# is checked on the host: were the stock line to change, sed would replace
# nothing and the warnings would be missing for another reason.
actmp2=$(mktemp -d); tmpdirs="$tmpdirs $actmp2"; chmod 755 "$actmp2"
docker run --rm --label "$SMOKE_RUN_LABEL" --entrypoint cat "$IMAGE" /etc/angie/angie.conf |
  sed -e 's|^error_log /dev/stderr format=json;$|error_log /dev/stderr notice;|' \
    -e '/^worker_shutdown_timeout /d' >"$actmp2/angie.conf"
chmod 644 "$actmp2/angie.conf"
if grep -q '^error_log /dev/stderr notice;$' "$actmp2/angie.conf" &&
  ! grep -q '^worker_shutdown_timeout' "$actmp2/angie.conf"; then
  pass "customized angie.conf fixture: error_log edited, worker_shutdown_timeout removed"
else
  fail "customized angie.conf fixture: the stock error_log or worker_shutdown_timeout line changed"
fi
cid=$(start -e ANGIE_WORKER_SHUTDOWN_TIMEOUT=3s -v "$actmp2/angie.conf:/etc/angie/angie.conf:ro")
wait_healthy "$cid" || fail "customized angie.conf container is healthy"
custom_log=$(docker logs "$cid" 2>&1)
assert_contains "$custom_log" "neither known error_log state found" \
  "31-error-log-json.sh warns about an unknown error_log line"
assert_contains "$custom_log" "no stock worker_shutdown_timeout line found" \
  "32-worker-shutdown-timeout.sh warns about a missing stock line"
live_conf=$(docker exec "$cid" cat /data/conf/angie.conf 2>/dev/null || true)
assert_contains "$live_conf" "error_log /dev/stderr notice;" "the customized error_log line is left as is"
assert_lacks "$live_conf" "worker_shutdown_timeout" "no worker_shutdown_timeout line is invented"
docker rm -f "$cid" >/dev/null

# --- Entrypoint lines follow the error_log format ---
# ANGIE_ERROR_LOG_JSON_ENABLED sets the format of the server and the entrypoint
# alike: a half-JSON stderr is parsed half by a collector. Both streams count,
# docker logs and kubelet merge them. A value with a quote and a backslash in a
# refusal breaks hand-built JSON without escaping; a multi-line angie -t output
# must be one record.
json_stream_check() { # label stream
  assert_eq "$(printf '%s\n' "$2" | grep -v '^{.*}$' | grep -v '^$' || true)" "" \
    "$1: every log line is one JSON object"
}
cid=$(start)
wait_healthy "$cid" || fail "entrypoint-json container is healthy"
ep_log=$(docker logs "$cid" 2>&1)
docker rm -f "$cid" >/dev/null
json_stream_check "entrypoint json default" "$ep_log"
ep_json=$(printf '%s\n' "$ep_log" | grep -e '"tags":\["entrypoint"\]}$' || true)
if [ -n "$ep_json" ]; then pass "entrypoint json lines carry tags [entrypoint]";
else fail "entrypoint json lines carry tags [entrypoint]"; fi
assert_eq "$(printf '%s\n' "$ep_json" | sed -n 's/.*"level":"\([a-z]*\)".*/\1/p' | sort -u |
  grep -vxE 'error|warn|notice|info' || true)" "" "entrypoint json levels are angie's (error, warn, notice, info)"
assert_contains "$ep_json" '"message":"configuration complete; ready for start up"' \
  "the entrypoint completion message is a JSON string"
cid=$(start -e ANGIE_ERROR_LOG_JSON_ENABLED=no)
wait_healthy "$cid" || fail "entrypoint-text container is healthy"
ep_err=$(docker logs "$cid" 2>&1 >/dev/null)
docker rm -f "$cid" >/dev/null
assert_eq "$(printf '%s\n' "$ep_err" | grep -e ': entrypoint: ' |
  grep -vE '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[(error|warn|notice|info)\] [0-9]+: entrypoint: ' || true)" "" \
  "ANGIE_ERROR_LOG_JSON_ENABLED=no: entrypoint lines keep the angie text format"
assert_contains "$ep_err" ': entrypoint: ' "ANGIE_ERROR_LOG_JSON_ENABLED=no: entrypoint lines are there"
run_to_exit -e 'ANGIE_REAL_IP_FROM=10.0.0.0/8"x\y' "$IMAGE"
assert_exit_one "a refusal carrying a quote and a backslash" "unsupported characters"
json_stream_check "entrypoint json refusal" "$exit_log"
assert_contains "$exit_log" '10.0.0.0/8\"x\\y' "the refused value is JSON-escaped, not raw"
eptmp=$(mktemp -d); tmpdirs="$tmpdirs $eptmp"
printf 'server {\n  listen 8085;\n  bogus_directive_for_smoke on;\n}\n' >"$eptmp/bad.conf"
chmod -R a+rX "$eptmp"
run_to_exit -v "$eptmp:/etc/angie/custom/http.d:ro" "$IMAGE"
assert_exit_one "a broken configuration" "bogus_directive_for_smoke"
json_stream_check "entrypoint json angie -t output" "$exit_log"

# --- ModSecurity rules from a read-only custom volume ---
# The WAF recipe of docs/configuration.md: engine at server level, rules and
# audit from a file on a :ro mount, SecTmpDir on /data/tmp (the only writable
# dir under --read-only). `<script>` gets 403, a neighbour 200, the audit is
# one JSON line; a `return` location answers in the rewrite phase, before
# ModSecurity, and passes the same request.
mstmp=$(mktemp -d); tmpdirs="$tmpdirs $mstmp"
mkdir -p "$mstmp/custom/http.d" "$mstmp/custom/modsec" "$mstmp/site"
cat >"$mstmp/custom/http.d/site.conf" <<EOF
server {
  listen $PORT;
  server_name site.example;
  modsecurity on;
  modsecurity_rules_file /etc/angie/custom/modsec/main.conf;
  root /srv/site;
  location = /ret { return 200 "ret\n"; }
}
EOF
cat >"$mstmp/custom/modsec/main.conf" <<'EOF'
SecRuleEngine On
SecTmpDir /data/tmp
SecDataDir /data/tmp
SecAuditEngine RelevantOnly
SecAuditLogParts ABHZ
SecAuditLogType Serial
SecAuditLogFormat JSON
SecAuditLog /dev/stdout
SecRule ARGS "@contains <script>" "id:1000,phase:2,deny,status:403,log"
EOF
printf 'site-ok\n' >"$mstmp/site/index.html"
chmod -R a+rX "$mstmp"
cid=$(start --read-only --tmpfs /data:rw,noexec,nosuid,nodev,mode=1777 -e ANGIE_MODSECURITY_ENABLED=yes \
  -v "$mstmp/custom:/etc/angie/custom:ro" -v "$mstmp/site:/srv/site:ro")
if wait_healthy "$cid"; then
  pass "the documented WAF recipe starts on a read-only rootfs"
else
  fail "the documented WAF recipe starts on a read-only rootfs"
  docker logs "$cid" 2>&1 | grep -iE 'emerg|"level":"error"' | head -2 || true
fi
assert_eq "$(http_status "$cid" "$PORT" '/?x=%3Cscript%3E' --header='Host: site.example')" "403" \
  "WAF: <script> in a parameter gets 403"
assert_eq "$(http_status "$cid" "$PORT" '/?x=hello' --header='Host: site.example')" "200" \
  "WAF: a neighbouring request gets 200"
audit=$(wait_logs "$cid" '"transaction"' | grep '"transaction"' | tail -1 || true)
case "$audit" in
'{'*'}') pass "WAF: the audit record of the refusal is one JSON line" ;;
*) fail "WAF: the audit record of the refusal is one JSON line (got '$audit')" ;;
esac
assert_contains "$audit" '"ruleId":"1000"' "WAF: the audit record names the rule that fired"
assert_eq "$(http_status "$cid" "$PORT" '/ret?x=%3Cscript%3E' --header='Host: site.example')" "200" \
  "WAF: a location answering with return is passed before ModSecurity runs"
docker rm -f "$cid" >/dev/null

# --- A non-directory in place of /data/tmp aborts startup ---
ftmp_vol="angie-layout-tmpfile-$$"
docker volume create "$ftmp_vol" >/dev/null
vols="$vols $ftmp_vol"
docker run --rm --label "$SMOKE_RUN_LABEL" -u 0 -v "$ftmp_vol:/data" --entrypoint sh "$IMAGE" \
  -c 'chmod 1777 /data && rm -rf /data/tmp && : >/data/tmp'
run_to_exit -v "$ftmp_vol:/data" "$IMAGE"
assert_exit_one "a regular file at /data/tmp" "/data/tmp exists but is not a directory"

printf '\n%d test(s), %d failure(s)\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
