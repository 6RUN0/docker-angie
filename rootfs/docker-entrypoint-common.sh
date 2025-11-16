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

enable_log_format() {
  angie-ctl httpconf en "030-log-format-$1.conf" &&
    ngx_info "Enabled $1 log format"
}

enable_log() {
  enable_log_format "$1"
  angie-ctl httpconf en "040-log-$1.conf" &&
    ngx_info "Use $1 format for access log"
}
