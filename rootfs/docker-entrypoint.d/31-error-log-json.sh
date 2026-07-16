#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_ERROR_LOG_JSON_ENABLED:=no}"

# The error_log format lives in the MAIN context of angie.conf -- an http-conf.d
# snippet cannot reach startup/core messages -- so this toggle rewrites the
# shipped line in place, the same pattern exception as worker_processes
# autotune (30-tune-worker-processes.sh). Only the two known states are
# matched, exactly and in full; a user-customized error_log line is left alone.
plain_line='error_log /dev/stderr;'
json_line='error_log /dev/stderr format=json;'

case "${ANGIE_ERROR_LOG_JSON_ENABLED}" in
yes | on | 1 | true | enable | enabled)
  from_line=$plain_line
  to_line=$json_line
  ;;
*)
  from_line=$json_line
  to_line=$plain_line
  ;;
esac

# Already in the desired state (including the shipped default): nothing to do.
# This also keeps the default read-only-FS startup silent -- the write path
# below is only reached when a change is actually needed.
if grep -qxF "$to_line" /etc/angie/angie.conf 2>/dev/null; then
  exit 0
fi

if ! grep -qxF "$from_line" /etc/angie/angie.conf 2>/dev/null; then
  ngx_warning "$(basename "$0"): neither known error_log state found in /etc/angie/angie.conf (customized config?); leaving error_log as is"
  exit 0
fi

if ! touch /etc/angie/angie.conf 2>/dev/null; then
  ngx_warning "$(basename "$0"): can not modify /etc/angie/angie.conf (read-only file system?); leaving error_log as is"
  exit 0
fi

sed -i "s|^${from_line}\$|${to_line}|" /etc/angie/angie.conf &&
  ngx_info "error_log switched to: ${to_line}"
