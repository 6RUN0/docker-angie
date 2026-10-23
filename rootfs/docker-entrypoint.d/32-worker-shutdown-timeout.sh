#!/bin/sh -e

. /docker-entrypoint-common.sh

# The default matches the line shipped in angie.conf, so a default start exits
# early below and never edits the file.
: "${ANGIE_WORKER_SHUTDOWN_TIMEOUT:=8s}"

# worker_shutdown_timeout lives in the MAIN context, and a second declaration
# fails with `is duplicate`, so custom/conf.d cannot override it. The line is
# rewritten in place in the live tree, the same exception as error_log
# (31-error-log-json.sh) and worker_processes (30-tune-worker-processes.sh).
# Any `worker_shutdown_timeout <number>[ms|s|m];` line is rewritten; a line of
# another shape is left alone with a warning.
#
# The value is limited to angie's time syntax, a number with an optional ms, s
# or m: a `;` would break out of the directive (config injection). The unit is
# stripped first (two letters, else one); the rest must be a non-empty number.
# Overflow is left for `angie -t`.
#
# Zero is refused: `worker_shutdown_timeout 0` means no limit, not "at once",
# a worker waits on an open connection forever and docker SIGKILLs the
# container at stop_grace_period (exit 137). The limit can only be raised.
number=${ANGIE_WORKER_SHUTDOWN_TIMEOUT%ms}
[ "$number" != "$ANGIE_WORKER_SHUTDOWN_TIMEOUT" ] || number=${ANGIE_WORKER_SHUTDOWN_TIMEOUT%[sm]}
case "$number" in
'' | *[!0-9]*)
  ngx_err "ANGIE_WORKER_SHUTDOWN_TIMEOUT must be a number with an optional unit ms, s or m (for example 8s), got: $ANGIE_WORKER_SHUTDOWN_TIMEOUT"
  exit 1
  ;;
esac
case "$number" in
*[1-9]*) ;;
*)
  ngx_err "ANGIE_WORKER_SHUTDOWN_TIMEOUT must be positive: 0 would remove the limit, and docker would SIGKILL the container at stop_grace_period; got: $ANGIE_WORKER_SHUTDOWN_TIMEOUT"
  exit 1
  ;;
esac

stock_pattern='^worker_shutdown_timeout [0-9]+(ms|s|m)?;$'
to_line="worker_shutdown_timeout ${ANGIE_WORKER_SHUTDOWN_TIMEOUT};"

# Already in the desired state (including the shipped default): nothing to do.
if grep -qxF "$to_line" "$ANGIE_CONF_DIR/angie.conf" 2>/dev/null; then
  exit 0
fi

if ! grep -qE "$stock_pattern" "$ANGIE_CONF_DIR/angie.conf" 2>/dev/null; then
  ngx_warning "$(basename "$0"): no stock worker_shutdown_timeout line found in $ANGIE_CONF_DIR/angie.conf (customized config?); leaving it as is"
  exit 0
fi

sed -i -E "s#${stock_pattern}#${to_line}#" "$ANGIE_CONF_DIR/angie.conf" &&
  ngx_info "worker_shutdown_timeout set to: ${ANGIE_WORKER_SHUTDOWN_TIMEOUT}"
