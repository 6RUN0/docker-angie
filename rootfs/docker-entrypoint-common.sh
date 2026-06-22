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

# Active access-log snippets. Exactly one may be enabled at a time: angie applies
# every `access_log` directive it encounters, so two active 040-log-* snippets
# log each request twice. Keep this list in sync with http-conf-available.d.
ACCESS_LOG_SNIPPETS="040-log-extended.conf 040-log-logfmt.conf 040-log-logfmt-with-geoip2.conf 040-log-main.conf 040-log-matomo.conf"

enable_log_format() {
  angie-ctl httpconf en "030-log-format-$1.conf" &&
    ngx_info "Enabled $1 log format"
}

enable_log() {
  enable_log_format "$1"
  # Disable the whole group first so the requested format is the only active
  # access_log. This makes selection idempotent across restarts and lets a later
  # script (e.g. 50-geoip2) override an earlier default (40-log) cleanly instead
  # of stacking a second access_log directive.
  for _snippet in $ACCESS_LOG_SNIPPETS; do
    angie-ctl httpconf dis "$_snippet" >/dev/null 2>&1 || true
  done
  angie-ctl httpconf en "040-log-$1.conf" &&
    ngx_info "Use $1 format for access log"
}
