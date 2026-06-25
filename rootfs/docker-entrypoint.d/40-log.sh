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

# Clear any geoip2 log format left active by a previous run before selecting a
# log below. That format references $geoip2_country_code, a variable that only
# exists while the geoip2 module + map (025-geoip2.conf) are active; angie
# validates the variables of EVERY declared log_format, used or not, so an
# orphaned geoip2 format on a persistent /etc/angie volume fails `angie -t` for
# the whole config. This script runs before 50-geoip2, which re-enables these
# when geoip2 is genuinely up. Disable the access_log before its format
# definition; angie-ctl validates on disable and leaves the change in place on
# failure (the intermediate test still sees the other snippet), so guard with
# `|| true` and let the clean state settle after both calls.
angie-ctl httpconf dis 040-log-logfmt-with-geoip2.conf >/dev/null 2>&1 || true
angie-ctl httpconf dis 030-log-format-logfmt-with-geoip2.conf >/dev/null 2>&1 || true

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
