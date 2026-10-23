#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_CONSOLE_ENABLED:=no}"

# No reset_httpconf: the snippet has no activation, it is a plain file that
# http.d/default.conf includes. The disabled state is the skeleton's stub,
# which 10-conf-overlay.sh copies in on every start; rendering below overwrites
# the copy only.
case "${ANGIE_CONSOLE_ENABLED}" in
yes | on | 1 | true | enable | enabled) ;;
*)
  exit 0
  ;;
esac

: "${ANGIE_CONSOLE_PATH:=}"
: "${ANGIE_CONSOLE_HTPASSWD_FILE:=/etc/angie/custom/console.htpasswd}"

# The path is substituted into two location directives; the charset keeps it
# from breaking out of them (config injection) or the sed substitution, as for
# GEOIP2_DB_COUNTRY and ANGIE_STATUS_API_*. No slash: one segment. At least 16
# characters: the path is what hides the panel from scanners, a short one is
# brute-forced.
case "$ANGIE_CONSOLE_PATH" in
'' | *[!A-Za-z0-9_-]*)
  ngx_err "ANGIE_CONSOLE_PATH must be a non-empty segment of A-Za-z0-9 _ - (no slashes); generate one with: openssl rand -hex 16; got: '$ANGIE_CONSOLE_PATH'"
  exit 1
  ;;
esac
if [ "${#ANGIE_CONSOLE_PATH}" -lt 16 ]; then
  ngx_err "ANGIE_CONSOLE_PATH must be at least 16 characters, the path stands in for the console being hidden from scanners; generate one with: openssl rand -hex 16; got ${#ANGIE_CONSOLE_PATH}: '$ANGIE_CONSOLE_PATH'"
  exit 1
fi

# Without a file only the path protects the panel, so that is an explicit
# operator choice (`none`), never a default: a typo in the file name fails
# below instead of silently dropping auth.
if [ "$ANGIE_CONSOLE_HTPASSWD_FILE" = none ]; then
  console_auth_basic=""
  console_auth_file=""
  ngx_warning "console basic auth disabled: /status/ is readable by anyone who learns the path"
else
  # Same charset as GEOIP2_DB_COUNTRY in 50-geoip2.sh. The path must be
  # absolute: a relative one resolves against the entrypoint's cwd here but
  # against the /data/conf prefix in angie, so the check would pass and every
  # request would get 403.
  case "$ANGIE_CONSOLE_HTPASSWD_FILE" in
  *[!A-Za-z0-9._/-]*)
    ngx_err "ANGIE_CONSOLE_HTPASSWD_FILE has unsupported characters (allowed: A-Za-z0-9 . _ / -): $ANGIE_CONSOLE_HTPASSWD_FILE"
    exit 1
    ;;
  /*) ;;
  *)
    ngx_err "ANGIE_CONSOLE_HTPASSWD_FILE must be an absolute path, got: $ANGIE_CONSOLE_HTPASSWD_FILE"
    exit 1
    ;;
  esac
  # In the unprivileged image this uid is the workers' uid, so `-r` reflects
  # exactly the rights angie opens the file with. `-f` rejects a directory: it
  # is readable and "non-empty", but the first authenticated request would get
  # 500.
  if [ ! -f "$ANGIE_CONSOLE_HTPASSWD_FILE" ] || [ ! -r "$ANGIE_CONSOLE_HTPASSWD_FILE" ] || [ ! -s "$ANGIE_CONSOLE_HTPASSWD_FILE" ]; then
    ngx_err "ANGIE_CONSOLE_HTPASSWD_FILE is missing, not a regular file, unreadable by uid $(id -u) or empty: $ANGIE_CONSOLE_HTPASSWD_FILE; create it with: printf 'admin:%s\\n' \"\$(openssl passwd -6)\" > console.htpasswd and mount it there, or set ANGIE_CONSOLE_HTPASSWD_FILE=none to serve the console without basic auth"
    exit 1
  fi
  # The root master can read more than its unprivileged workers: `-r` as root
  # passes for a file the angie workers cannot open, and the first request
  # would get 500.
  if is_root && [ -z "${ANGIE_UNPRIVILEGED:-}" ] &&
    ! su -s /bin/sh angie -c "test -r '$ANGIE_CONSOLE_HTPASSWD_FILE'"; then
    ngx_err "ANGIE_CONSOLE_HTPASSWD_FILE is not readable by the angie worker user: $ANGIE_CONSOLE_HTPASSWD_FILE"
    exit 1
  fi
  console_auth_basic='auth_basic "Angie console";'
  console_auth_file="auth_basic_user_file ${ANGIE_CONSOLE_HTPASSWD_FILE};"
fi

# Render the active snippet from the pristine template every start (same
# pattern as 40-status-api.sh). Two placeholders on two lines rather than one:
# a multi-line sed replacement is not portable. With `none` both lines become
# empty and the last expression drops them; the template has no other empty
# lines.
console_conf="${ANGIE_CONF_DIR}/snippets/console.conf"
sed \
  -e "s|%%CONSOLE_PATH%%|${ANGIE_CONSOLE_PATH}|g" \
  -e "s|%%CONSOLE_AUTH_BASIC%%|${console_auth_basic}|" \
  -e "s|%%CONSOLE_AUTH_FILE%%|${console_auth_file}|" \
  -e '/^ *$/d' \
  "${console_conf}.template" >"$console_conf"

# The path is kept out of the startup log, but the access log records it on
# every panel request to the same stdout: whoever reads container logs knows
# it, which with `none` means access to the data.
ngx_info "console enabled at the secret path (basic auth: ${ANGIE_CONSOLE_HTPASSWD_FILE})"
