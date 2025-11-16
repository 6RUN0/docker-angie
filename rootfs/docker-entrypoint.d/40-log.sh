#!/bin/sh -e

. /docker-entrypoint-common.sh

: "${ANGIE_LOG_FORMAT_EXTENDED:=no}"
: "${ANGIE_LOG_FORMAT_LOGFMT:=no}"
: "${ANGIE_LOG_FORMAT_MAIN:=no}"
: "${ANGIE_LOG_FORMAT_MATOMO:=no}"

: "${ANGIE_LOG_EXTENDED:=no}"
: "${ANGIE_LOG_LOGFMT:=yes}" # use logfmt as default log format
: "${ANGIE_LOG_MAIN:=no}"
: "${ANGIE_LOG_MATOMO:=no}"

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
