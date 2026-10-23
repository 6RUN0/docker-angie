#!/bin/sh -e

. /docker-entrypoint-common.sh

entrypoint_dir="/docker-entrypoint.d"

if { [ "$1" = "angie" ] || [ "$1" = "angie-debug" ]; } &&
  ! is_root && [ -z "${ANGIE_UNPRIVILEGED:-}" ]; then
  # The default image must run as root: it binds port 80 and its workers switch
  # to the angie user (conf.d/05-worker-user.conf). A non-root master would
  # crash later with an opaque EACCES, so fail fast with a clear message. The
  # unprivileged image sets ANGIE_UNPRIVILEGED=1, which lifts this guard.
  ngx_err "the default image requires a root master for port 80 and the angie worker user; use the unprivileged image for rootless operation"
  exit 1
elif [ "$1" = "angie" ] || [ "$1" = "angie-debug" ]; then
  # Iterate with a glob in THIS shell. A `find ... | sort -V | while` loop runs
  # its body in a pipeline subshell, where `set -e` does not propagate: a
  # failing config script would be silently discarded and angie would start
  # with a half-applied configuration. The two-digit numeric prefixes (10-,
  # 30-, ... 90-) sort identically under the shell's lexical glob order, so no
  # external `sort` is needed.
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
  # of the run: a transient inconsistency while toggling (e.g. an orphaned
  # geoip2 log format not yet reset) is harmless, only the final state is
  # tested. The whole argument list is tested, not just the binary: the live
  # tree is not at the compiled-in path, CMD points at it with -p and -c, and a
  # bare `angie -t` would test the read-only skeleton instead of the copy.
  if ! ngx_test_output=$("$@" -t 2>&1); then
    ngx_err "assembled configuration failed '$1 -t', aborting startup"
    # In JSON mode the test output goes out as one record with escaped
    # newlines: raw lines would break line-by-line parsing of the stream.
    if [ -n "$ngx_log_json" ]; then
      ngx_log_json_line "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" error "$$" "$ngx_test_output" >&2
    else
      printf '%s\n' "$ngx_test_output" >&2
    fi
    exit 1
  fi
fi

if [ -n "${1:-}" ] && { [ -x "$1" ] || [ -x "$(command -v "$1" 2>/dev/null)" ]; }; then
  exec "$@"
else
  ngx_err "$1: not executable or not found"
  exit 1
fi
