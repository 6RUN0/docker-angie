#!/bin/sh
# Mirror-override checks for both base Dockerfiles: an unreachable mirror must
# fail the build at the first package-manager call, loudly and with the mirror
# URL in the error. Pins two facts the Dockerfiles do not show: apk-tools 3 (the
# alpine:3.24 base) refuses an unavailable repository by itself unless given
# --force-missing-repositories (apk-tools 2 went on with a WARNING and failed
# later, at package selection), while apt-get update does so only with
# APT::Update::Error-Mode=any (without it: exit 0 with W: lines, and only the
# install fails). An https Debian mirror is covered too: the slim base has no
# ca-certificates, so TLS verification fails.
#
# Not part of `make test`: every probe is a docker build that fetches the Angie
# signing key and package indexes over the network. There is no positive probe
# (a full build with overridden mirrors); the default-mirror build is covered by
# test-alpine and test-debian.
#
# Run from anywhere, no arguments: sh test/build-mirrors.sh
# Environment:
#   TLS_PROBE_MIRROR  a real https Debian mirror for the TLS probe; the failure
#                     must come from certificate verification, not from
#                     reachability (default https://deb.debian.org/debian).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)

tests=0
fails=0

pass() {
  tests=$((tests + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  tests=$((tests + 1))
  fails=$((fails + 1))
  printf '  FAIL %s\n' "$1"
}

# The build must fail and its output must hold every expected substring: an exit
# code alone does not tell the right refusal from an unrelated one (no network
# to the signing key, a Dockerfile typo), and a refusal line without the URL
# does not tell the overridden mirror from a failing default one. apk prints the
# URL in a WARNING above the ERROR, so the alpine probes expect both. The
# substrings are taken from real apk and apt output. --progress=plain prints the
# layer's command output verbatim, without folding.
assert_build_fails() { # label dockerfile expected-substring... -- build-arg...
  label=$1
  dockerfile=$2
  shift 2
  wants=
  while [ "$1" != "--" ]; do
    wants="${wants}${1}
"
    shift
  done
  shift
  rc=0
  out=$(cd "$ROOT" && DOCKER_BUILDKIT=1 docker build --progress=plain \
    -f "$dockerfile" "$@" . 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label (expected a failure, the build passed)"
    return
  fi
  if printf '%s' "$wants" | while IFS= read -r want; do
    case "$out" in
    *"$want"*) ;;
    *)
      printf '%s\n' "$out" | tail -20
      exit 1
      ;;
    esac
  done; then
    pass "$label"
  else
    fail "$label (an expected substring is missing from the output)"
  fi
}

# Port 1 on loopback: the connection is refused at once, no timeout to wait for.
unreachable=127.0.0.1:1

apk_refuses="ERROR: Not continuing due to stale/unavailable repositories"

TLS_PROBE_MIRROR="${TLS_PROBE_MIRROR:-https://deb.debian.org/debian}"

echo "alpine"
assert_build_fails "an unreachable ALPINE_MIRROR fails the first apk" alpine/Dockerfile \
  "WARNING: fetching https://$unreachable/alpine/v" "$apk_refuses" \
  -- --build-arg "ALPINE_MIRROR=https://$unreachable/alpine"
assert_build_fails "an unreachable ANGIE_MIRROR fails the first apk" alpine/Dockerfile \
  "WARNING: fetching https://$unreachable/angie/alpine/v" "$apk_refuses" \
  -- --build-arg "ANGIE_MIRROR=https://$unreachable/angie"
assert_build_fails "a wrong ANGIE_SIGNING_KEY_SHA256 fails before the key is trusted" alpine/Dockerfile \
  "signing key sha256 mismatch" \
  -- --build-arg "ANGIE_SIGNING_KEY_SHA256=0000"

echo "debian"
assert_build_fails "an unreachable DEBIAN_MIRROR fails the first apt-get update" debian/Dockerfile \
  "E: Failed to fetch http://$unreachable/debian/dists/" \
  -- --build-arg "DEBIAN_MIRROR=http://$unreachable/debian"
assert_build_fails "an unreachable DEBIAN_SECURITY_MIRROR fails the first apt-get update" debian/Dockerfile \
  "E: Failed to fetch http://$unreachable/debian-security/dists/" \
  -- --build-arg "DEBIAN_SECURITY_MIRROR=http://$unreachable/debian-security"
assert_build_fails "an https Debian mirror fails TLS verification without ca-certificates" debian/Dockerfile \
  "E: Failed to fetch $TLS_PROBE_MIRROR/dists/" "certificate verify failed" \
  -- --build-arg "DEBIAN_MIRROR=$TLS_PROBE_MIRROR"
assert_build_fails "an unreachable ANGIE_MIRROR fails the second apt-get update" debian/Dockerfile \
  "E: Failed to fetch http://$unreachable/angie/debian/" \
  -- --build-arg "ANGIE_MIRROR=http://$unreachable/angie"
assert_build_fails "a wrong ANGIE_SIGNING_KEY_SHA256 fails before Signed-By refers to it" debian/Dockerfile \
  "signing key sha256 mismatch" \
  -- --build-arg "ANGIE_SIGNING_KEY_SHA256=0000"

echo
echo "$tests test(s), $fails failure(s)"
[ "$fails" -eq 0 ]
