#!/bin/sh -eu

. /docker-entrypoint-common.sh

if [ -z "${CACHE_DIR:-}" ]; then
  exit 0
fi

if [ ! -d "$CACHE_DIR" ]; then
  ngx_warning "$CACHE_DIR not found"
  exit 0
fi

find "$CACHE_DIR" \! -user angie -exec chown angie: '{}' +
ngx_info "Changed ownership of cache dir: $CACHE_DIR"
