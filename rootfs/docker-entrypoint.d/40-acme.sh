#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_ACME_ENABLED:=no}"

# Reset before deciding whether ACME is on this start (declarative toggle, see
# docker-entrypoint-common.sh): an active snippet would keep ordering
# certificates after the toggle is switched off.
reset_httpconf 080-acme.conf

case "${ANGIE_ACME_ENABLED}" in
yes | on | 1 | true | enable | enabled) ;;
*)
  exit 0
  ;;
esac

: "${ANGIE_ACME_CLIENT:=le}"
: "${ANGIE_ACME_CHALLENGE:=http}"
: "${ANGIE_ACME_HTTP_PORT:=${ANGIE_HTTP_PORT}}"
: "${ANGIE_ACME_DIRECTORY:=}"
: "${ANGIE_ACME_EMAIL:=}"

# The client name becomes the suffix of $acme_cert_<name> and
# $acme_cert_key_<name>, so it takes a variable-name charset.
case "$ANGIE_ACME_CLIENT" in
'' | *[!A-Za-z0-9_]*)
  ngx_err "ANGIE_ACME_CLIENT must be a non-empty name of A-Za-z0-9 _ (it becomes the suffix of \$acme_cert_<name>), got: $ANGIE_ACME_CLIENT"
  exit 1
  ;;
esac

# A list, not a charset: there are three values, and angie rejects a wrong one
# itself (`"acme_client" directive has an invalid "challenge" value`). The
# check exists for a message that names the environment variable.
case "$ANGIE_ACME_CHALLENGE" in
http | dns | alpn) ;;
*)
  ngx_err "ANGIE_ACME_CHALLENGE must be one of http, dns, alpn, got: $ANGIE_ACME_CHALLENGE"
  exit 1
  ;;
esac

case "$ANGIE_ACME_HTTP_PORT" in
'' | *[!0-9]*)
  ngx_err "ANGIE_ACME_HTTP_PORT must be a decimal port number, got: $ANGIE_ACME_HTTP_PORT"
  exit 1
  ;;
# Length is cut before arithmetic: `[ -lt ]` cannot compare a number wider
# than the machine word, prints `out of range`, treats the test as false, and
# the value would slip past the range check.
??????*)
  ngx_err "ANGIE_ACME_HTTP_PORT out of range 1-65535: $ANGIE_ACME_HTTP_PORT"
  exit 1
  ;;
esac
if [ "$ANGIE_ACME_HTTP_PORT" -lt 1 ] || [ "$ANGIE_ACME_HTTP_PORT" -gt 65535 ]; then
  ngx_err "ANGIE_ACME_HTTP_PORT out of range 1-65535: $ANGIE_ACME_HTTP_PORT"
  exit 1
fi

# A privileged port under a non-root master is refused as image policy, not as
# an impossibility: binding it depends on the runtime (Docker 20.10+ sets
# net.ipv4.ip_unprivileged_port_start=0, Kubernetes and plain runc do not).
# Where bind fails, angie's own message blames missing superuser rights and
# points to the wrong fix; publish port 80 by port mapping instead.
if ! is_root && [ "$ANGIE_ACME_HTTP_PORT" -lt 1024 ]; then
  ngx_err "ANGIE_ACME_HTTP_PORT must be 1024 or above for a non-root master, got: $ANGIE_ACME_HTTP_PORT"
  exit 1
fi

# Matching the built-in listener port is load-bearing, so a mismatch is said
# out loud. On a port nobody listens on the module opens a dedicated listener
# that drops everything but a live token, the http -> https redirect included.
# Not an error: a listener on that port may come from /etc/angie/custom, which
# the toggle cannot see.
if [ "$ANGIE_ACME_HTTP_PORT" -ne "$ANGIE_HTTP_PORT" ]; then
  ngx_warning "ANGIE_ACME_HTTP_PORT is ${ANGIE_ACME_HTTP_PORT}, not the built-in listener port ${ANGIE_HTTP_PORT}; the ACME module will open a dedicated listener"
fi

if [ -z "$ANGIE_ACME_DIRECTORY" ]; then
  acme_client="# Set ANGIE_ACME_DIRECTORY or declare acme_client in custom configuration."
else
  # The CA directory URL is substituted into a directive. The set is a subset
  # of URL characters without space, newline, semicolon, braces, quotes,
  # dollar, backslash and ampersand; the ampersand is dropped for sed, where it
  # means the whole match in a replacement. ACME directory URLs never use it.
  case "$ANGIE_ACME_DIRECTORY" in
  *[!A-Za-z0-9._~:/?#@%+=-]*)
    ngx_err "ANGIE_ACME_DIRECTORY has unsupported characters (allowed: A-Za-z0-9 . _ ~ : / ? # @ % + = -): $ANGIE_ACME_DIRECTORY"
    exit 1
    ;;
  https://?*) ;;
  *)
    # The allowed set includes '#': a value led by it would comment out the
    # directive's ';' and fail startup with an opaque parse error.
    ngx_err "ANGIE_ACME_DIRECTORY must be an https:// URL, got: $ANGIE_ACME_DIRECTORY"
    exit 1
    ;;
  esac

  acme_client="acme_client ${ANGIE_ACME_CLIENT} ${ANGIE_ACME_DIRECTORY} challenge=${ANGIE_ACME_CHALLENGE}"

  if [ -n "$ANGIE_ACME_EMAIL" ]; then
    case "$ANGIE_ACME_EMAIL" in
    *[!A-Za-z0-9._%+@-]*)
      ngx_err "ANGIE_ACME_EMAIL has unsupported characters (allowed: A-Za-z0-9 . _ % + @ -): $ANGIE_ACME_EMAIL"
      exit 1
      ;;
    esac

    acme_client="${acme_client} email=${ANGIE_ACME_EMAIL}"
  fi

  acme_client="${acme_client};"
fi

# Account keys and certificates land here; a link planted on a shared /data
# would redirect them outside the data mount.
if [ -L "$ANGIE_DATA_DIR/acme" ]; then
  ngx_err "$ANGIE_DATA_DIR/acme is a symbolic link; refusing to store ACME keys through it"
  exit 1
fi

# Render the active config from the pristine template every start (same
# pattern as 35-real-ip.sh and 40-status-api.sh). The validated charsets above
# keep the '|' delimiter safe.
acme_conf="${HTTP_CONF_AVAILABLE_DIR}/080-acme.conf"
sed \
  -e "s|%%ACME_HTTP_PORT%%|${ANGIE_ACME_HTTP_PORT}|g" \
  -e "s|%%ACME_CLIENT%%|${acme_client}|g" \
  "${acme_conf}.template" >"$acme_conf"

if [ -z "$ANGIE_ACME_DIRECTORY" ]; then
  acme_summary="ACME paths configured (state /data/acme, http challenge port ${ANGIE_ACME_HTTP_PORT}); declare acme_client yourself under /etc/angie/custom/http-conf.d"
else
  acme_summary="ACME client '${ANGIE_ACME_CLIENT}' configured: ${ANGIE_ACME_DIRECTORY}, challenge=${ANGIE_ACME_CHALLENGE}, state /data/acme"
fi

ngx_ctl httpconf en 080-acme.conf &&
  ngx_info "$acme_summary"
