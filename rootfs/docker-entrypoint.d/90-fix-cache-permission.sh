#!/bin/sh -eu

. /docker-entrypoint-common.sh

if [ -z "${CACHE_DIR:-}" ]; then
  exit 0
fi

if [ ! -d "$CACHE_DIR" ]; then
  ngx_warning "$CACHE_DIR not found"
  exit 0
fi

# Only the root-master image has a separate worker user to hand files to; in
# the unprivileged image master and workers already share the runtime uid.
if ! is_root || [ -n "${ANGIE_UNPRIVILEGED:-}" ]; then
  ngx_notice "no separate worker user, skipping chown of $CACHE_DIR"
  exit 0
fi

# Never chown through a link: chown dereferences by default, so a link planted
# in the cache mount would hand an arbitrary root-owned file to the worker.
# A failure warns instead of aborting, like the htpasswd fix: a read-only cache
# mount still serves, only uncached. chown's own error above names the cause.
if find "$CACHE_DIR" ! -type l ! -user angie -exec chown -h angie: '{}' +; then
  ngx_info "Changed ownership of cache dir: $CACHE_DIR"
else
  ngx_warning "could not chown every entry under $CACHE_DIR; the angie worker may be unable to write the cache"
fi
