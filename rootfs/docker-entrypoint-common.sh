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
  ngx_warning "$(basename "$0"): config dirs not writable by uid $(id -u); runtime toggling unavailable, using build-time config"
  exit 0
}

# Directory holding the shippable (disabled-by-default) http-conf snippets.
HTTP_CONF_AVAILABLE_DIR="/etc/angie/http-conf-available.d"

enable_log_format() {
  angie-ctl httpconf en "030-log-format-$1.conf" &&
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
  for _snippet in "$HTTP_CONF_AVAILABLE_DIR"/040-log-*.conf; do
    [ -e "$_snippet" ] || continue # no 040-log-* present: nothing to disable
    angie-ctl httpconf dis "$(basename "$_snippet")" >/dev/null 2>&1 || true
  done
  angie-ctl httpconf en "040-log-$1.conf" &&
    ngx_info "Use $1 format for access log"
}
