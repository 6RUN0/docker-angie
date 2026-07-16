#!/bin/sh -e

. /docker-entrypoint-common.sh

entrypoint_dir="/docker-entrypoint.d"

if { [ "$1" = "angie" ] || [ "$1" = "angie-debug" ]; } && ! is_root && [ -z "${ANGIE_UNPRIVILEGED:-}" ]; then
  # The default image must run as root: it binds port 80, its pidfile
  # (/run/angie.pid) and temp dirs (/var/cache/angie/*) are root-owned, and
  # angie-ctl needs write access to /etc/angie/*.d. A non-root master cannot do
  # any of that, so angie would crash later with an opaque EACCES. Fail fast with
  # a clear message instead. The unprivileged image variant sets
  # ANGIE_UNPRIVILEGED=1, which lifts this guard: its config is baked at build
  # time and its pid/temp paths and listener were relocated for rootless use.
  ngx_err "the default image requires root; got uid $(id -u). Use the unprivileged image variant for rootless operation."
  exit 1
elif [ "$1" = "angie" ] || [ "$1" = "angie-debug" ]; then
  # Iterate with a glob in THIS shell. The previous `find ... | sort -V | while`
  # ran the loop body in a pipeline subshell, where `set -e` does not propagate:
  # a failing config script was silently discarded and angie started with a
  # half-applied configuration. A `for` over the glob keeps the body in the main
  # shell so a non-zero exit aborts startup. The two-digit numeric prefixes
  # (30-, 40-, ... 90-) sort identically under the shell's lexical glob order,
  # so no external `sort` is needed.
  found=
  for f in "$entrypoint_dir"/*; do
    # POSIX sh has no `nullglob`: an empty dir yields the literal pattern, so
    # skip anything that does not actually exist.
    [ -e "$f" ] || continue
    found=yes
    case "$f" in
    *.sh)
      if [ -x "$f" ]; then
        ngx_notice "launching $f"
        # Run in the main shell and fail loudly: a broken config script must
        # stop the container, not let angie come up misconfigured.
        "$f" || {
          rc=$?
          ngx_err "$f failed with exit $rc, aborting startup"
          exit "$rc"
        }
      else
        # warn on shell scripts without exec bit
        ngx_warning "ignoring $f, not executable"
      fi
      ;;
    *) ngx_warning "ignoring $f" ;;
    esac
  done

  if [ -n "$found" ]; then
    ngx_notice "configuration complete; ready for start up"
  else
    ngx_notice "no files found in $entrypoint_dir, skipping configuration"
  fi

  # Single authoritative config test. The toggle scripts mutate config through
  # angie-ctl, which runs no config test itself, so this is the only `angie -t`
  # of the run: it validates the fully-assembled final state once, here. A
  # transient inconsistency while toggling -- e.g. an orphaned geoip2 log format
  # not yet reset when an earlier script enabled its own snippet -- is therefore
  # harmless; only the final state is tested. Fail loudly with the test output
  # instead of letting the `exec` below start angie on a config that cannot load.
  if ! ngx_test_output=$("$1" -t 2>&1); then
    ngx_err "assembled configuration failed '$1 -t', aborting startup"
    printf '%s\n' "$ngx_test_output" >&2
    exit 1
  fi
fi

if [ -n "${1:-}" ] && { [ -x "$1" ] || [ -x "$(command -v "$1" 2>/dev/null)" ]; }; then
  exec "$@"
else
  ngx_err "$1: not executable or not found"
  exit 1
fi
