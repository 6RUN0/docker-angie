#!/bin/sh -

if [ -z "${ANGIE_ENTRYPOINT_QUIET_LOGS:-}" ]; then
  exec 3>&2
else
  exec 3>/dev/null
fi

# One toggle sets the format of both angie's error_log (31-error-log-json.sh)
# and the entrypoint's own lines: both write to the container's stderr, and a
# log collector parses a mixed-format stream only by half. The default lives
# here because every script sources this file and 31- does not run first.
: "${ANGIE_ERROR_LOG_JSON_ENABLED:=yes}"
case "${ANGIE_ERROR_LOG_JSON_ENABLED}" in
yes | on | 1 | true | enable | enabled) ngx_log_json=yes ;;
*) ngx_log_json= ;;
esac

# One JSON line in angie's `error_log ... format=json` schema: same keys in the
# same order, `tags` tells entrypoint lines from server lines. No milliseconds:
# busybox date has no %N and silently truncates the format there.
#
# The message arrives on stdin, not via -v: -v expands backslashes, and
# messages carry values from the consumer's environment. Escaping walks the
# string per character instead of gsub, whose backslash handling differs
# between busybox awk, mawk (Debian) and gawk. Newlines are joined per record:
# per-character concatenation of one long string is quadratic in busybox awk.
ngx_log_json_line() {
  printf '%s' "$4" | awk -v time="$1" -v level="$2" -v pid="$3" '
    BEGIN {
      for (i = 1; i < 32; i++) esc[sprintf("%c", i)] = sprintf("\\u%04x", i)
      esc["\r"] = "\\r"; esc["\t"] = "\\t"
      esc["\""] = "\\\""; esc["\\"] = "\\\\"
    }
    {
      line = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        line = line ((c in esc) ? esc[c] : c)
      }
      out = (NR > 1) ? out "\\n" line : line
    }
    END {
      printf "{\"time\":\"%s\",\"level\":\"%s\",\"pid\":%s,\"message\":\"%s\",\"tags\":[\"entrypoint\"]}\n", time, level, pid, out
    }'
}

# Level names match angie's in both formats (error and warn, not err and
# warning), so a search by level matches server and entrypoint lines alike.
ngx_log() {
  __type="$1"
  shift
  if [ -n "$ngx_log_json" ]; then
    ngx_log_json_line "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$__type" "$$" "$*" >&3
  else
    printf '%s [%s] %s: entrypoint: %s\n' "$(date +'%Y/%m/%d %H:%M:%S')" "$__type" "$$" "$*" >&3
  fi
}
ngx_err() {
  ngx_log error "$@"
}
ngx_warning() {
  ngx_log warn "$@"
}
ngx_notice() {
  ngx_log notice "$@"
}
ngx_info() {
  ngx_log info "$@"
}

# The only writable location in the container. Everything changed at runtime
# lives below it, so hardening comes down to one mount: the live config tree (a
# copy of the shipped one, see 10-conf-overlay.sh) and angie's temp files. A
# proxy cache placed here too keeps the temp-to-cache `rename()` on one
# filesystem.
ANGIE_DATA_DIR="/data"

# The live config tree. The shipped /etc/angie is never edited and serves only
# as the skeleton for this copy.
ANGIE_CONF_DIR="$ANGIE_DATA_DIR/conf"

# Keep all Angie-created temporary files on the writable data mount. The value
# is duplicated by the *_temp_path directives in 010-common.conf: angie config
# cannot read shell variables, so only this comment ties the two together.
# shellcheck disable=SC2034 # Used by 10-conf-overlay.sh after sourcing this file.
ANGIE_TMP_DIR="$ANGIE_DATA_DIR/tmp"

# Port of the built-in listener: the root image binds the privileged :80, the
# unprivileged one cannot and uses :8080. Exported for the toggle scripts that
# compare consumer ports against it.
if [ -n "${ANGIE_UNPRIVILEGED:-}" ]; then
  ANGIE_HTTP_PORT=8080
else
  ANGIE_HTTP_PORT=80
fi
export ANGIE_HTTP_PORT

# angie-ctl takes the tree root from here, so its activation symlinks land in
# the live copy rather than the shipped skeleton. Exported because angie-ctl is
# a separate process.
export ANGIE_ETC="$ANGIE_CONF_DIR"

# Directory holding the shippable (disabled-by-default) http-conf snippets.
HTTP_CONF_AVAILABLE_DIR="$ANGIE_CONF_DIR/http-conf-available.d"

# Every entrypoint config mutation goes through this wrapper. --no-test skips
# angie-ctl's per-call `angie -t`; the entrypoint validates the assembled config
# once at the very end (see docker-entrypoint.sh). This removes an ordering
# trap: angie validates the variables of EVERY declared log_format on each
# `angie -t`, so while one toggle enables its snippet, an orphan from another
# feature not yet reset this run would poison that intermediate test and abort
# startup at an unrelated, earlier script.
#
# angie-ctl's stdout ("Enabled http-conf: ...") is plain text amid JSON in
# `docker logs`, and ngx_info reports each change anyway; its errors go to
# stderr and stay visible.
ngx_ctl() {
  angie-ctl --no-test "$@" >/dev/null
}

# True when the entrypoint runs as root. Privileged setup steps (chown, the
# root-only listener and temp-dir checks) are skipped otherwise so the image
# works under `docker run --user`.
is_root() {
  [ "$(id -u)" -eq 0 ]
}

# Feature toggles are declarative: each NN-*.sh resets the snippets/modules it
# owns at the start of every run, then re-enables only what the current
# environment asks for. Two reasons, both within a single run: the skeleton
# ships the json log pair enabled (see Dockerfile), so picking another format
# would add a second access_log instead of replacing it; and a later toggle must
# cleanly override an earlier one (50-geoip2 over 40-log) instead of stacking
# on it. These helpers centralise that "disable then conditionally enable"
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
  # and can never drift out of sync.
  reset_httpconf '040-log-*.conf'
  ngx_ctl httpconf en "040-log-$1.conf" &&
    ngx_info "Use $1 format for access log"
}
