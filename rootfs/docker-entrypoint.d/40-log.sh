#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_LOG_FORMAT_EXTENDED:=no}"
: "${ANGIE_LOG_FORMAT_JSON:=no}"
: "${ANGIE_LOG_FORMAT_LOGFMT:=no}"
: "${ANGIE_LOG_FORMAT_MAIN:=no}"
: "${ANGIE_LOG_FORMAT_MATOMO:=no}"

# No ANGIE_LOG_* is on by default. The default json format is picked at the
# tail when nothing else is chosen: the chain below stops at the first match,
# so a variable defaulting to `yes` would beat any operator choice later in
# the chain.
: "${ANGIE_LOG_EXTENDED:=no}"
: "${ANGIE_LOG_JSON:=no}"
: "${ANGIE_LOG_LOGFMT:=no}"
: "${ANGIE_LOG_MAIN:=no}"
: "${ANGIE_LOG_MATOMO:=no}"

# Reset log state before reselecting: clear every access_log selection and every
# log-format definition, including the pair the skeleton ships enabled (see
# Dockerfile); otherwise a selection would add a second access_log instead of
# replacing it. It also clears the geoip2 log formats, which reference
# $_stock_geoip2_country_code: angie validates the variables of EVERY declared
# log_format, so leaving one active once geoip2 is no longer up would fail the
# final `angie -t` (see docker-entrypoint.sh). 50-geoip2.sh re-enables them only
# when geoip2 is genuinely up.
reset_httpconf '040-log-*.conf' '030-log-format-*.conf'

case "${ANGIE_LOG_FORMAT_EXTENDED}" in
yes | on | 1 | true | enable | enabled)
  enable_log_format "extended"
  ;;
esac

case "${ANGIE_LOG_FORMAT_JSON}" in
yes | on | 1 | true | enable | enabled)
  enable_log_format "json"
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

case "${ANGIE_LOG_JSON}" in
yes | on | 1 | true | enable | enabled)
  enable_log "json"
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

# Nothing chosen: the default applies. An access log is always active, since
# exactly one 040-log-* snippet carries the access_log; without it requests
# would not be logged at all.
enable_log "json"
