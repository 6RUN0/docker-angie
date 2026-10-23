#!/bin/sh -e

. /docker-entrypoint-common.sh

# Workers read auth_basic_user_file at request time. Only the root-master image
# has a separate worker user; in the unprivileged image they share one uid.
if ! is_root || [ -n "${ANGIE_UNPRIVILEGED:-}" ]; then
  ngx_notice "no separate worker user, skipping htpasswd ownership fix"
  exit 0
fi

[ -d /etc/angie/custom ] || exit 0

# The skeleton ships no htpasswd files, so only the custom mount can hold them.
# Links are skipped: chown would follow them to an arbitrary root-owned file.
set -- /etc/angie/custom ! -type l -type f ! -user angie -iname "*htpasswd*"
[ -n "$(find "$@" -print)" ] || exit 0

if find "$@" -exec chown -h angie: '{}' +; then
  ngx_info "Fixed ownership of htpasswd files under /etc/angie/custom"
else
  # A read-only custom mount is the recommended layout; the owner of the mount
  # then has to make the files readable by the angie user. chown's own error
  # above names the cause.
  ngx_warning "could not chown htpasswd files under /etc/angie/custom; make them readable by the angie user"
fi
