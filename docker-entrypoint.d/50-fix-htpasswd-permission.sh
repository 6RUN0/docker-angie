#!/bin/sh -

find "/etc/angie" \! -user angie -a -iname "*htpasswd*" -exec chown angie: '{}' +
