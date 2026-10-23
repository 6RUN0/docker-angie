#!/bin/sh

# Self-contained integration tests for the vendored angie-ctl.
# No external dependencies: builds a throwaway ANGIE_ETC tree in a temp dir and
# drives the vendored script against it. Run: ./test/angie-ctl.sh

set -u

# shellcheck disable=SC1007  # CDPATH= is a deliberate per-command reset, not a typo
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$SCRIPT_DIR/../rootfs/usr/local/bin/angie-ctl"

PASS=0
FAIL=0
ROOT=""

cleanup() {
  [ -n "$ROOT" ] && rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

# Fresh ANGIE_ETC tree before each test so cases never bleed into each other.
setup_tree() {
  cleanup
  ROOT=$(mktemp -d)
  mkdir -p "$ROOT/http-conf-available.d" "$ROOT/http-conf.d" \
    "$ROOT/modules-available.d" "$ROOT/modules.d"
  printf 'cfg\n' >"$ROOT/http-conf-available.d/drupal.conf"
}

# Default driver: validation off so symlink-logic tests are deterministic
# regardless of whether a real `angie` binary is installed on the host.
ctl() {
  ANGIE_ETC="$ROOT" "$CTL" --no-test "$@"
}

# Raw driver: no implicit flags, for tests that assert on option parsing.
ctl_raw() {
  ANGIE_ETC="$ROOT" "$CTL" "$@"
}

# Install a fake `angie` under $ROOT/bin that exits with the given code, so the
# config-test path can be exercised without a real Angie install.
make_stub() {
  mkdir -p "$ROOT/bin"
  printf '#!/bin/sh\nexit %s\n' "$1" >"$ROOT/bin/angie"
  chmod +x "$ROOT/bin/angie"
}

ok() {
  PASS=$((PASS + 1))
  printf 'ok   - %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL - %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}

# assert_status EXPECTED DESC -- command...
assert_status() {
  expected=$1
  desc=$2
  shift 2
  "$@" >/dev/null 2>&1
  actual=$?
  if [ "$actual" -eq "$expected" ]; then
    ok "$desc"
  else
    bad "$desc" "expected exit $expected, got $actual"
  fi
}

# assert_exists DESC PATH  /  assert_absent DESC PATH
assert_exists() {
  if [ -e "$2" ] || [ -L "$2" ]; then ok "$1"; else bad "$1" "missing: $2"; fi
}
assert_absent() {
  if [ -e "$2" ] || [ -L "$2" ]; then bad "$1" "still present: $2"; else ok "$1"; fi
}

# assert_contains DESC NEEDLE -- command...
assert_contains() {
  desc=$1
  needle=$2
  shift 2
  out=$("$@" 2>&1)
  case "$out" in
  *"$needle"*) ok "$desc" ;;
  *) bad "$desc" "output missing '$needle': $out" ;;
  esac
}

# --- basic enable / disable / list ---------------------------------------

setup_tree
assert_contains "ls marks available config off" "[off] drupal.conf" ctl httpconf ls
assert_status 0 "enable resolves bare name to .conf" ctl httpconf en drupal
assert_exists "enable creates symlink" "$ROOT/http-conf.d/drupal.conf"
assert_contains "ls marks enabled config on" "[on ] drupal.conf" ctl httpconf ls
assert_status 0 "enabling twice is idempotent (exit 0)" ctl httpconf en drupal
assert_status 0 "disable removes the config" ctl httpconf dis drupal
assert_absent "disable removed the symlink" "$ROOT/http-conf.d/drupal.conf"
assert_status 1 "disabling absent config fails" ctl httpconf dis drupal

# --- security: path traversal --------------------------------------------

setup_tree
printf 'SECRET\n' >"$ROOT/secret.conf"
assert_status 1 "traversal name on disable is rejected" ctl httpconf dis ../secret
assert_exists "traversal target survives" "$ROOT/secret.conf"
assert_status 1 "traversal name on enable is rejected" ctl httpconf en ../../secret

# --- security: refuse to delete a non-symlink ----------------------------

setup_tree
printf 'real\n' >"$ROOT/http-conf.d/manual.conf"
assert_status 1 "disable refuses a real (non-symlink) file" ctl httpconf dis manual
assert_exists "real file survives disable attempt" "$ROOT/http-conf.d/manual.conf"

# --- dangling symlink visibility & removal -------------------------------

setup_tree
ln -s ../http-conf-available.d/ghost.conf "$ROOT/http-conf.d/ghost.conf"
assert_contains "ls-enabled lists a dangling symlink" "ghost.conf" ctl httpconf ls-enabled
assert_status 0 "dangling symlink can be disabled" ctl httpconf dis ghost
assert_absent "dangling symlink removed" "$ROOT/http-conf.d/ghost.conf"

# --- orphan visibility in ls ---------------------------------------------

setup_tree
ln -s ../http-conf-available.d/gone.conf "$ROOT/http-conf.d/gone.conf"
assert_contains "ls flags enabled-without-source as orphan" "[orphan] gone.conf" ctl httpconf ls

# --- dry-run makes no changes --------------------------------------------

setup_tree
assert_contains "dry-run previews enable" "[dry-run] would enable" ctl --dry-run httpconf en drupal
assert_absent "dry-run did not create symlink" "$ROOT/http-conf.d/drupal.conf"
ctl httpconf en drupal >/dev/null 2>&1
assert_contains "dry-run previews disable" "[dry-run] would disable" ctl -n httpconf dis drupal
assert_exists "dry-run did not remove symlink" "$ROOT/http-conf.d/drupal.conf"

# --- help and option handling --------------------------------------------

setup_tree
assert_status 0 "--help exits 0" ctl_raw --help
assert_status 0 "-h exits 0 with no other args" ctl_raw -h
assert_contains "help mentions dry-run option" "--dry-run" ctl_raw --help
assert_contains "help mentions no-test option" "--no-test" ctl_raw --help
assert_status 1 "unknown option is rejected" ctl --bogus httpconf ls
assert_status 1 "missing command shows usage" ctl httpconf
assert_status 0 "--version exits 0 with no other args" ctl_raw --version
assert_contains "version output names the tool" "angie-ctl " ctl_raw -V

# --- ANGIE_ETC validation ------------------------------------------------

setup_tree
# shellcheck disable=SC2016  # $0/ANGIE_ETC must stay literal for the inner sh -c
assert_status 1 "relative ANGIE_ETC is rejected" sh -c 'ANGIE_ETC=relative/path "$0" httpconf ls' "$CTL"
# shellcheck disable=SC2016
assert_status 1 "ANGIE_ETC with '..' is rejected" sh -c 'ANGIE_ETC=/etc/angie/../evil "$0" httpconf ls' "$CTL"

# --- modules type --------------------------------------------------------

setup_tree
printf 'mod\n' >"$ROOT/modules-available.d/geoip.conf"
assert_status 0 "module enable works" ctl mod en geoip
assert_exists "module symlink created" "$ROOT/modules.d/geoip.conf"

# --- config test (angie -t) ----------------------------------------------

setup_tree
make_stub 0
assert_status 0 "passing config test lets enable succeed" \
  env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/angie" "$CTL" httpconf en drupal
assert_exists "symlink created when config test passes" "$ROOT/http-conf.d/drupal.conf"

setup_tree
make_stub 1
assert_status 1 "failing config test makes enable exit non-zero" \
  env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/angie" "$CTL" httpconf en drupal
assert_exists "symlink kept after failed config test (no rollback)" "$ROOT/http-conf.d/drupal.conf"

setup_tree
make_stub 1
assert_status 0 "--no-test skips a failing config test" \
  env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/angie" "$CTL" --no-test httpconf en drupal

setup_tree
assert_status 0 "missing angie binary skips the config test" \
  env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/nonexistent" "$CTL" httpconf en drupal

# Smart part: a no-op batch (nothing actually changed) must not run the test,
# so a pre-existing broken config does not block an idempotent re-enable.
setup_tree
make_stub 1
env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/angie" "$CTL" --no-test httpconf en drupal >/dev/null 2>&1
assert_status 0 "no-op enable does not trigger the config test" \
  env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/angie" "$CTL" httpconf en drupal

setup_tree
make_stub 1
assert_status 0 "dry-run never runs the config test" \
  env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/angie" "$CTL" --dry-run httpconf en drupal

# --- status --------------------------------------------------------------

setup_tree
assert_status 1 "status of a disabled config is non-zero" ctl httpconf status drupal
assert_contains "status prints the off marker" "[off] drupal.conf" ctl httpconf status drupal
ctl httpconf en drupal >/dev/null 2>&1
assert_status 0 "status of an enabled config is zero" ctl httpconf status drupal
assert_contains "status prints the on marker" "[on ] drupal.conf" ctl httpconf status drupal
printf 'cfg\n' >"$ROOT/http-conf-available.d/other.conf"
assert_status 1 "status is non-zero if any name is disabled" ctl httpconf status drupal other
assert_status 1 "status rejects an invalid name" ctl httpconf status ../escape

# --- prune ---------------------------------------------------------------

setup_tree
# An orphan: an enabled symlink whose source no longer exists in available.
ln -s ../http-conf-available.d/ghost.conf "$ROOT/http-conf.d/ghost.conf"
assert_contains "ls marks the orphan" "[orphan] ghost.conf" ctl httpconf ls
assert_contains "prune dry-run announces the orphan" "would prune" ctl -n httpconf prune
assert_exists "dry-run prune keeps the orphan" "$ROOT/http-conf.d/ghost.conf"
assert_status 0 "prune removes the orphan" ctl httpconf prune
assert_absent "orphan gone after prune" "$ROOT/http-conf.d/ghost.conf"
assert_status 1 "prune rejects positional names" ctl httpconf prune ghost

setup_tree
assert_status 0 "prune with no orphans is a no-op" ctl httpconf prune

# Safety: an orphaned *real* file (not a symlink) must never be deleted.
setup_tree
printf 'real\n' >"$ROOT/http-conf.d/real-orphan.conf"
assert_status 0 "prune skips a non-symlink orphan" ctl httpconf prune
assert_exists "prune leaves a real orphan file untouched" "$ROOT/http-conf.d/real-orphan.conf"

# --- reload (--reload) ---------------------------------------------------

# A reload stub that records its invocation by creating a marker file. An
# absolute ANGIE_RELOAD_CMD bypasses the fixed reload PATH, like ANGIE_BIN.
make_reload_stub() {
  mkdir -p "$ROOT/bin"
  printf '#!/bin/sh\n: >"%s/reloaded"\n' "$ROOT" >"$ROOT/bin/reloadcmd"
  chmod +x "$ROOT/bin/reloadcmd"
}

setup_tree
make_reload_stub
assert_status 0 "reload runs after a successful enable" \
  env ANGIE_ETC="$ROOT" ANGIE_RELOAD_CMD="$ROOT/bin/reloadcmd" "$CTL" --no-test --reload httpconf en drupal
assert_exists "reload command was invoked" "$ROOT/reloaded"

setup_tree
make_reload_stub
env ANGIE_ETC="$ROOT" "$CTL" --no-test httpconf en drupal >/dev/null 2>&1
env ANGIE_ETC="$ROOT" ANGIE_RELOAD_CMD="$ROOT/bin/reloadcmd" "$CTL" --no-test --reload httpconf en drupal >/dev/null 2>&1
assert_absent "reload is skipped when nothing changed" "$ROOT/reloaded"

setup_tree
make_reload_stub
assert_contains "dry-run reload only announces" "would reload" \
  env ANGIE_ETC="$ROOT" ANGIE_RELOAD_CMD="$ROOT/bin/reloadcmd" "$CTL" --dry-run --reload httpconf en drupal
assert_absent "dry-run reload does not run the command" "$ROOT/reloaded"

setup_tree
make_stub 1
make_reload_stub
assert_status 1 "failing config test prevents reload" \
  env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/angie" ANGIE_RELOAD_CMD="$ROOT/bin/reloadcmd" "$CTL" --reload httpconf en drupal
assert_absent "reload is skipped when the config test fails" "$ROOT/reloaded"

# --- rollback (--rollback) -----------------------------------------------

setup_tree
assert_status 1 "--rollback with --no-test is rejected" ctl_raw --rollback --no-test httpconf en drupal

setup_tree
make_stub 1
assert_status 1 "rollback enable exits non-zero on a failed test" \
  env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/angie" "$CTL" --rollback httpconf en drupal
assert_absent "rollback removes the symlink it created" "$ROOT/http-conf.d/drupal.conf"

setup_tree
make_stub 1
env ANGIE_ETC="$ROOT" "$CTL" --no-test httpconf en drupal >/dev/null 2>&1
assert_status 1 "rollback disable exits non-zero on a failed test" \
  env ANGIE_ETC="$ROOT" ANGIE_BIN="$ROOT/bin/angie" "$CTL" --rollback httpconf dis drupal
assert_exists "rollback recreates the disabled symlink" "$ROOT/http-conf.d/drupal.conf"

# --- summary -------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
