#!/bin/sh -e

find "/etc/angie" \! -user angie -a -iname "*htpasswd*" -exec chown angie: '{}' +
