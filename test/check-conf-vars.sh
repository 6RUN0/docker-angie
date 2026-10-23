#!/bin/sh
# Tests for ci/check-conf-vars.sh: findings, no false positives, and refusals
# where parsing did not happen. Needs no Docker.
#
# Usage: sh test/check-conf-vars.sh
#
# The load-bearing assertion is the declaration count on the shipped tree: a
# check whose parser stopped matching the tree finds no violations and is
# indistinguishable from a green one; without the count it would stay green
# forever.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/ci/check-conf-vars.sh

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
assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}
assert_contains() { # haystack needle label
  case "$1" in
  *"$2"*) pass "$3" ;;
  *) fail "$3 (missing '$2')" ;;
  esac
}

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# One run over fixture files: exit status and combined output.
run() { # file...
  out=$(sh "$SCRIPT" "$@" 2>&1) && rc=0 || rc=$?
}

# --- 1. The shipped tree: clean, and declarations are actually found ---
out=$(cd "$ROOT" && sh "$SCRIPT" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 0 "the shipped tree passes"
found=$(printf '%s' "$out" | sed -n 's/^conf-vars: \([0-9]*\) declarations.*/\1/p')
if [ -n "$found" ] && [ "$found" -gt 0 ]; then
  pass "the shipped tree yields declarations to check (found $found)"
else
  fail "the shipped tree yields declarations to check (got '$out')"
fi

# --- 2. A violation in every declaration form ---
cat >"$tmp/map.conf" <<'CONF'
map $http_upgrade $connection_upgrade {
  default upgrade;
}
CONF
run "$tmp/map.conf"
assert_eq "$rc" 1 "an unprefixed map target is rejected"
assert_contains "$out" "\$connection_upgrade" "the map diagnostic names the variable"

cat >"$tmp/geo.conf" <<'CONF'
geo $remote_addr $loopback {
  default 0;
}
CONF
run "$tmp/geo.conf"
assert_eq "$rc" 1 "an unprefixed geo target is rejected"
assert_contains "$out" "\$loopback" "the geo diagnostic names the variable"

cat >"$tmp/geoip2.conf" <<'CONF'
geoip2 /geo/Country.mmdb {
  auto_reload 1h;
  $geoip2_country_code default=ZZ source=$remote_addr country iso_code;
}
CONF
run "$tmp/geoip2.conf"
assert_eq "$rc" 1 "an unprefixed geoip2 variable is rejected"
assert_contains "$out" "\$geoip2_country_code" "the geoip2 diagnostic names the variable"

cat >"$tmp/time.conf" <<'CONF'
time_format $time_ms "%Y";
CONF
run "$tmp/time.conf"
assert_eq "$rc" 1 "an unprefixed time_format target is rejected"

# --- 3. Prefix in place: silence ---
cat >"$tmp/ok.conf" <<'CONF'
map $http_upgrade $_stock_connection_upgrade {
  default upgrade;
}
geo $_stock_loopback {
  default 0;
}
time_format $_stock_time_ms "%Y";
CONF
run "$tmp/ok.conf"
assert_eq "$rc" 0 "prefixed declarations pass"
assert_contains "$out" "3 declarations" "all three prefixed declarations are counted"

# --- 4. Forms that look like a declaration but declare nothing ---
# Each would be caught by a line-prefix pattern instead of a token compare.
cat >"$tmp/lookalike.conf" <<'CONF'
# example in a comment: map $http_upgrade $connection_upgrade {
map_hash_bucket_size 64;
geoip2_proxy 10.0.0.0/8;
log_format example escape=json
  '"date":"$time_local"'
  ',"host":"$host"';
CONF
run "$tmp/lookalike.conf"
assert_eq "$rc" 0 "lookalikes are not mistaken for declarations"
assert_contains "$out" "0 declarations" "lookalikes yield no declarations at all"

# --- 5. A declaration split across lines halts the check ---
# A silent skip would look like a clean file, and a line break would bypass the
# prefix.
cat >"$tmp/wrapped.conf" <<'CONF'
map $http_upgrade
  $connection_upgrade {
  default upgrade;
}
CONF
run "$tmp/wrapped.conf"
assert_eq "$rc" 2 "a declaration split across lines halts the check"
assert_contains "$out" "not parsed" "the halt diagnostic says why"

# --- 6. A failing awk is a failed check, not a clean run ---
# An awk that rejects the program (busybox: `bad regex '{'`) exits with its own
# code, no TOTAL line and no BAD; without an explicit refusal that is a green
# run. The stub fails only the call carrying the check program.
mkdir -p "$tmp/bin"
real_awk=$(command -v awk)
cat >"$tmp/bin/awk" <<SH
#!/bin/sh
case "\$1" in
*TOTAL*) echo "awk: bad regex" >&2; exit 1 ;;
esac
exec "$real_awk" "\$@"
SH
chmod +x "$tmp/bin/awk"
out=$(cd "$ROOT" && PATH="$tmp/bin:$PATH" sh "$SCRIPT" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 2 "a failing awk halts the check"
assert_contains "$out" "did not run" "the awk-failure diagnostic says why"

# --- 7. An empty file list is a refusal, not a success ---
# Outside the repository root find yields nothing, so the empty list must differ
# from "no violations".
mkdir -p "$tmp/empty"
out=$(cd "$tmp/empty" && sh "$SCRIPT" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 2 "an empty file list is refused"
assert_contains "$out" "empty file list" "the empty-list diagnostic says why"

printf '\n%d test(s), %d failure(s)\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
