#!/bin/sh -

if [ -z "${ANGIE_ENTRYPOINT_QUIET_LOGS:-}" ]; then
  exec 3>&2
else
  exec 3>/dev/null
fi

ngx_log() {
  __type="$1"
  shift
  printf '%s [%s] %s: entrypoint: %s\n' "$(date +'%Y/%m/%d %H:%M:%S')" "$__type" "$$" "$*" >&3
}
ngx_err() {
  ngx_log err "$@"
}
ngx_warning() {
  ngx_log warning "$@"
}
ngx_notice() {
  ngx_log notice "$@"
}
ngx_info() {
  ngx_log info "$@"
}

# True when the entrypoint runs as root. Privileged setup steps (chown, editing
# angie.conf) are skipped otherwise so the image works under `docker run --user`.
is_root() {
  [ "$(id -u)" = 0 ]
}

# Feature-toggle scripts shell out to angie-ctl (which symlinks into
# /etc/angie/{http-conf,modules}.d) and render into http-conf-available.d. The
# default image owns those as root; the unprivileged image chowns them to the
# angie user at build time, so its default runtime uid can toggle features. A
# foreign `docker run --user <uid>` that does not own them cannot write there:
# warn and skip gracefully (the baked build-time config still serves) instead of
# letting angie-ctl's EACCES abort the fail-fast startup. Keying on writability
# rather than uid keeps the same path correct for root, for the angie user, and
# for an arbitrary uid alike.
skip_toggle_unless_writable() {
  if [ -w /etc/angie/http-conf.d ] &&
    [ -w /etc/angie/modules.d ] &&
    [ -w /etc/angie/http-conf-available.d ]; then
    return 0
  fi
  ngx_warning "$(basename "$0"): config dirs not writable by uid $(id -u); runtime toggling unavailable, using build-time config. The declarative reset also does not run, so a feature enabled by a prior run on a persistent /etc/angie volume stays active -- including a stale real-ip trusted-proxy list, which can let a client spoof \$remote_addr. Recreate the /etc/angie volume or run with a uid that owns the config dirs."
  exit 0
}

# Directory holding the shippable (disabled-by-default) http-conf snippets.
HTTP_CONF_AVAILABLE_DIR="/etc/angie/http-conf-available.d"

# Every entrypoint config mutation goes through angie-ctl with --no-test, so no
# single en/dis runs `angie -t`. The entrypoint validates the assembled config
# once at the very end (see docker-entrypoint.sh). This removes an ordering
# trap: angie validates the variables of EVERY declared log_format (and every
# directive) on each `angie -t`, so while one toggle enables its snippet, an
# orphan from another feature not yet reset this run (e.g. a geoip2 log format
# outliving geoip2 on a persistent /etc/angie volume) would otherwise poison
# that intermediate test and abort startup at an unrelated, earlier script. With
# validation deferred, only the final, fully-reset state is ever tested.
ngx_ctl() {
  angie-ctl --no-test "$@"
}

# Feature toggles are declarative: each NN-*.sh resets the snippets/modules it
# owns at the start of every run, then re-enables only what the current
# environment asks for. Without this, toggles would be enable-only -- a feature
# enabled on a prior run survives as an orphaned symlink on a persistent
# /etc/angie volume, so removing its ANGIE_* variable could not turn it off.
# These reset helpers centralise that "disable then conditionally enable"
# pattern.
#
# `reset_httpconf` takes basenames or shell globs matched against the available
# dir; `reset_module` takes module-load basenames. Both are idempotent. Guard
# every disable with `|| true`: resetting a snippet that is not currently
# enabled is a normal no-op, but angie-ctl exits non-zero for "not enabled",
# which would otherwise abort these `set -e` scripts.
reset_httpconf() {
  # Distinct __reset_ prefix: POSIX sh has no `local`, so these loop variables
  # leak into the caller; the prefix avoids clobbering a caller's own _path/_name.
  for __reset_pattern in "$@"; do
    for __reset_path in "$HTTP_CONF_AVAILABLE_DIR"/$__reset_pattern; do
      [ -e "$__reset_path" ] || continue # glob matched nothing: nothing to disable
      ngx_ctl httpconf dis "$(basename "$__reset_path")" >/dev/null 2>&1 || true
    done
  done
}

reset_module() {
  for __reset_name in "$@"; do
    ngx_ctl mod dis "$__reset_name" >/dev/null 2>&1 || true
  done
}

enable_log_format() {
  ngx_ctl httpconf en "030-log-format-$1.conf" &&
    ngx_info "Enabled $1 log format"
}

enable_log() {
  enable_log_format "$1"
  # Exactly one access_log may be active: angie applies every `access_log` it
  # parses, so two enabled 040-log-* snippets log each request twice. Disable
  # the whole group first, discovered by the 040-log-* naming convention rather
  # than a hand-kept list, so a new format snippet joins the group automatically
  # and can never drift out of sync. This also keeps selection idempotent across
  # restarts and lets a later script (e.g. 50-geoip2) override an earlier default
  # (40-log) cleanly instead of stacking a second access_log directive.
  reset_httpconf '040-log-*.conf'
  ngx_ctl httpconf en "040-log-$1.conf" &&
    ngx_info "Use $1 format for access log"
}
