#!/bin/sh -e

. /docker-entrypoint-common.sh

if ! is_root; then
  ngx_notice "not running as root, skipping htpasswd ownership fix"
  exit 0
fi

find "/etc/angie" \! -user angie -a -iname "*htpasswd*" -exec chown angie: '{}' +
ngx_info "Fixed ownership of htpasswd files under /etc/angie"
