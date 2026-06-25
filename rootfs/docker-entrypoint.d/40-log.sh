#!/bin/sh -e

. /docker-entrypoint-common.sh

skip_toggle_unless_writable

: "${ANGIE_LOG_FORMAT_EXTENDED:=no}"
: "${ANGIE_LOG_FORMAT_LOGFMT:=no}"
: "${ANGIE_LOG_FORMAT_MAIN:=no}"
: "${ANGIE_LOG_FORMAT_MATOMO:=no}"

: "${ANGIE_LOG_EXTENDED:=no}"
: "${ANGIE_LOG_LOGFMT:=yes}" # use logfmt as default log format
: "${ANGIE_LOG_MAIN:=no}"
: "${ANGIE_LOG_MATOMO:=no}"

# Reset log state before reselecting: clear every access_log selection and
# every log-format definition left active by a previous run. On a persistent
# /etc/angie volume these symlinks survive container recreation, so without this
# a format/log whose ANGIE_LOG_* variable was removed would stay active. It also
# clears the geoip2 log format, which references $geoip2_country_code: angie
# validates the variables of EVERY declared log_format, so leaving it active once
# geoip2 is no longer up would fail the final `angie -t` (see
# docker-entrypoint.sh). The geoip2 format/log is re-enabled only when geoip2 is
# genuinely up.
reset_httpconf '040-log-*.conf' '030-log-format-*.conf'

case "${ANGIE_LOG_FORMAT_EXTENDED}" in
yes | on | 1 | true | enable | enabled)
  enable_log_format "extended"
  ;;
esac

case "${ANGIE_LOG_FORMAT_LOGFMT}" in
yes | on | 1 | true | enable | enabled)
  enable_log_format "logfmt"
  ;;
esac

case "${ANGIE_LOG_FORMAT_MAIN}" in
yes | on | 1 | true | enable | enabled)
  enable_log_format "main"
  ;;
esac

case "${ANGIE_LOG_FORMAT_MATOMO}" in
yes | on | 1 | true | enable | enabled)
  enable_log_format "matomo"
  ;;
esac

case "${ANGIE_LOG_EXTENDED}" in
yes | on | 1 | true | enable | enabled)
  enable_log "extended"
  exit 0
  ;;
esac

case "${ANGIE_LOG_LOGFMT}" in
yes | on | 1 | true | enable | enabled)
  enable_log "logfmt"
  exit 0
  ;;
esac

case "${ANGIE_LOG_MAIN}" in
yes | on | 1 | true | enable | enabled)
  enable_log "main"
  exit 0
  ;;
esac

case "${ANGIE_LOG_MATOMO}" in
yes | on | 1 | true | enable | enabled)
  enable_log "matomo"
  exit 0
  ;;
esac
