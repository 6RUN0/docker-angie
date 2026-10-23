#!/bin/sh
# End-to-end run of the built-in ACME client against a local CA: account
# registration, order, http-01 validation, certificate written and served over
# TLS. Works on both variants: PORT is the built-in listener port (80 root,
# 8080 unprivileged), and the run keeps the image's own user.
#
# Separate from the smoke suites and not part of `make test`: it pulls the
# third-party ghcr.io/letsencrypt/pebble image, so it needs the network and a
# foreign registry, while the smoke suites work with the image under test only.
#
# Usage: IMAGE=angie-alpine PORT=80 ./test/acme-e2e.sh
#        IMAGE=angie-alpine-unprivileged PORT=8080 ./test/acme-e2e.sh
#
# Why this is not in the smoke suites: without a live CA no token exists, and
# without a token the challenge handler returns NGX_DECLINED and is
# indistinguishable from a missing one. The load-bearing assertion is that the
# challenge is served by the same listener on which the consumer server does
# `return 301` to https. The handler sits in the post_read phase, before the
# rewrite phase where `return` lives; if that order broke, the CA would get a
# redirect instead of the token and the order would fail.
set -eu
# shellcheck disable=SC3040 # pipefail support is probed before enabling it
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

IMAGE="${IMAGE:?set IMAGE=<image:tag>}"
PORT="${PORT:-80}"
PEBBLE_IMAGE="${PEBBLE_IMAGE:-ghcr.io/letsencrypt/pebble:2.10.1@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199}"

# The domain is ordered from the CA, so it must resolve FROM the pebble
# container. Docker's embedded DNS resolves it by network alias, which needs a
# user-defined network: the default bridge has no aliases.
DOMAIN="site.example"
NET="angie-acme-e2e-$$"
TRUST_IMAGE="angie-acme-e2e-trust-$$"
# The TLS port is published on loopback for one check only: which certificate
# goes into the handshake; the image has no openssl s_client. By default docker
# picks a free port, since a fixed one would fail on a busy machine. TLS_PORT
# sets it explicitly.
TLS_PORT="${TLS_PORT:-}"

tests=0
fails=0
tmpdir=""
ca_ref=""

cleanup() {
  docker rm -f "acme-e2e-ca-$$" "acme-e2e-angie-$$" >/dev/null 2>&1 || true
  if [ -n "$ca_ref" ]; then docker rm -f "$ca_ref" >/dev/null 2>&1 || true; fi
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker rmi -f "$TRUST_IMAGE" >/dev/null 2>&1 || true
  if [ -n "$tmpdir" ]; then rm -rf "$tmpdir"; fi
}
trap cleanup EXIT
# dash and busybox ash skip the EXIT trap on an unhandled SIGTERM, so signals
# are trapped separately and exit with the usual 128 + signal number.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

pass() {
  tests=$((tests + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  tests=$((tests + 1))
  fails=$((fails + 1))
  printf '  FAIL %s\n' "$1"
}
assert_contains() { # haystack needle label
  case "$1" in
  *"$2"*) pass "$3" ;;
  *) fail "$3 (missing '$2')" ;;
  esac
}

printf 'ACME end-to-end: %s (port %s) against %s\n' "$IMAGE" "$PORT" "$PEBBLE_IMAGE"

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/http.d" "$tmpdir/config" "$tmpdir/trust"

# Consumer fixture: one server on the built-in listener port references the
# ACME client and does nothing but redirect. That is the point of the
# assertion: the token must leave before the redirect.
cat >"$tmpdir/http.d/site.conf" <<CONF
server {
  listen $PORT;
  server_name $DOMAIN;

  acme le;

  return 301 https://\$host\$request_uri;
}

server {
  listen 8443 ssl;
  server_name $DOMAIN;

  ssl_certificate \$acme_cert_le;
  ssl_certificate_key \$acme_cert_key_le;

  location / { return 200 "tls ok\n"; }
}
CONF
chmod -R a+rX "$tmpdir"

# The CA root and the sample config come from the pebble image itself rather
# than being pinned in the tree: a pinned third-party root is read by nobody
# and silently goes stale with the image.
ca_ref=$(docker create "$PEBBLE_IMAGE")
docker cp "$ca_ref:/test/certs/pebble.minica.pem" "$tmpdir/trust/pebble.pem" >/dev/null
docker cp "$ca_ref:/test/config/pebble-config.json" "$tmpdir/config/pebble.json.in" >/dev/null
docker rm "$ca_ref" >/dev/null
ca_ref=""

# Pebble validates http-01 on httpPort. It is set to the image's listener port:
# the whole point of the layout is that the challenge and the site share one
# listener.
sed "s/\"httpPort\": [0-9]*/\"httpPort\": $PORT/" \
  "$tmpdir/config/pebble.json.in" >"$tmpdir/config/pebble-config.json"

# The ACME client reaches the directory over https, so the CA root must be
# trusted. The layer is throwaway and lives for this run only. It switches back
# to the image's own user (empty for the root variant, which runs as root).
image_user=$(docker image inspect -f '{{.Config.User}}' "$IMAGE")
{
  echo "FROM $IMAGE"
  echo "USER root"
  echo "COPY pebble.pem /usr/local/share/ca-certificates/pebble-e2e.crt"
  echo "RUN (command -v update-ca-certificates >/dev/null || \\"
  echo "     (command -v apk >/dev/null && apk add --no-cache ca-certificates)) && \\"
  echo "    update-ca-certificates"
  if [ -n "$image_user" ]; then echo "USER $image_user"; fi
} >"$tmpdir/trust/Dockerfile"
docker build -q -t "$TRUST_IMAGE" "$tmpdir/trust" >/dev/null

docker network create "$NET" >/dev/null

docker run -d --name "acme-e2e-ca-$$" --network "$NET" --network-alias pebble \
  -v "$tmpdir/config/pebble-config.json:/test/config/pebble-config.json:ro" \
  -e PEBBLE_VA_NOSLEEP=1 \
  "$PEBBLE_IMAGE" >/dev/null

cid=$(docker run -d --name "acme-e2e-angie-$$" --network "$NET" --network-alias "$DOMAIN" \
  -v "$tmpdir/http.d:/etc/angie/custom/http.d:ro" \
  -p "127.0.0.1:$TLS_PORT:8443" \
  -e ANGIE_ACME_ENABLED=1 \
  -e ANGIE_ACME_DIRECTORY=https://pebble:14000/dir \
  -e ANGIE_ACME_EMAIL=ops@example.test \
  -e ANGIE_HSTS_ENABLED=1 \
  -e ANGIE_HSTS_MAX_AGE=31536000 \
  "$TRUST_IMAGE")

# The published port is read from docker: with an empty TLS_PORT docker chose it.
TLS_PORT=$(docker port "$cid" 8443/tcp | head -1 | sed 's/.*://')

# Budget: 120 iterations of 0.5 s, 60 s, twice wait_healthy in the smoke suites:
# besides startup it covers registration, order and validation at the CA.
# Issuance strictly follows the listener coming up, so the wait is keyed to the
# file appearing, not to a fixed pause.
issued=0
for _ in $(seq 1 120); do
  if docker exec "$cid" sh -c 'test -s /data/acme/le/certificate.pem' 2>/dev/null; then
    issued=1
    break
  fi
  sleep 0.5
done

if [ "$issued" -eq 1 ]; then
  pass "a certificate is issued end to end under the image's own user"
else
  fail "a certificate is issued end to end under the image's own user"
  docker logs "$cid" 2>&1 | tail -20
  docker logs "acme-e2e-ca-$$" 2>&1 | tail -20
fi

# The phase assertion this run exists for: the challenge request must get 200
# from the handler, not 301 from the consumer server, although it came to the
# same listener and the same server {}.
access_log=$(docker logs "$cid" 2>/dev/null | grep 'acme-challenge' | tail -1 || true)
assert_contains "$access_log" '"status":200' \
  "the challenge is answered by the ACME handler, not by the consumer's return 301"

# The contrast to the assertion above: the same server redirects on an ordinary
# path. Without this pair, "200 on the challenge" cannot tell a working handler
# from a server that answers 200 to everything.
redirect_status=$(docker exec "$cid" sh -c \
  "wget -S --tries=1 -O /dev/null --header='Host: $DOMAIN' 'http://127.0.0.1:$PORT/' 2>&1 |
     sed -n 's|^ *HTTP/1.1 \\([0-9]*\\).*|\\1|p' | head -1" || true)
if [ "$redirect_status" = "301" ]; then
  pass "an ordinary path on the same server still redirects to https"
else
  fail "an ordinary path on the same server still redirects to https (got '$redirect_status')"
fi

# The issued certificate must reach the handshake through $acme_cert_le,
# otherwise ACME would issue into the void.
served=$(echo | openssl s_client -connect "127.0.0.1:$TLS_PORT" -servername "$DOMAIN" 2>/dev/null |
  openssl x509 -noout -issuer -ext subjectAltName 2>/dev/null || true)
assert_contains "$served" "Pebble" \
  "the issued certificate is what the TLS listener serves via \$acme_cert_le"
assert_contains "$served" "DNS:$DOMAIN" \
  "and it carries the ordered domain"

# HSTS is sent only over https (the $scheme map); this is the one place with a
# real certificate on an ssl listener to observe it.
hsts_resp=$(printf 'GET / HTTP/1.0\r\nHost: %s\r\n\r\n' "$DOMAIN" |
  openssl s_client -quiet -connect "127.0.0.1:$TLS_PORT" -servername "$DOMAIN" 2>/dev/null || true)
assert_contains "$hsts_resp" "Strict-Transport-Security: max-age=31536000" \
  "HSTS reaches the client over https, where the \$scheme map lets it through"

printf '\n%d test(s), %d failure(s)\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
