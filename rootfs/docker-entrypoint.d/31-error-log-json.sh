#!/bin/sh -e

. /docker-entrypoint-common.sh

# The ANGIE_ERROR_LOG_JSON_ENABLED default (yes) is set in
# docker-entrypoint-common.sh, since the same variable picks the format of the
# entrypoint's own lines. It matches the line shipped in angie.conf, so a
# default start exits early below and never edits the file.
#
# The error_log format lives in the MAIN context of angie.conf (an http-conf.d
# snippet cannot reach startup/core messages), so this toggle rewrites the
# line in place in the live tree, the same pattern exception as worker_processes
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
if grep -qxF "$to_line" "$ANGIE_CONF_DIR/angie.conf" 2>/dev/null; then
  exit 0
fi

if ! grep -qxF "$from_line" "$ANGIE_CONF_DIR/angie.conf" 2>/dev/null; then
  ngx_warning "$(basename "$0"): neither known error_log state found in $ANGIE_CONF_DIR/angie.conf (customized config?); leaving error_log as is"
  exit 0
fi

sed -i "s|^${from_line}\$|${to_line}|" "$ANGIE_CONF_DIR/angie.conf" &&
  ngx_info "error_log switched to: ${to_line}"
