#!/bin/sh -e

. /docker-entrypoint-common.sh

if [ "$1" = "angie" -o "$1" = "angie-debug" ]; then
    if find "/docker-entrypoint.d/" -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null | read v; then
        ngx_notice "/docker-entrypoint.d/ is not empty, will attempt to perform configuration"

        ngx_notice "looking for shell scripts in /docker-entrypoint.d/"
        find "/docker-entrypoint.d/" -follow -type f -print | sort -V | while read -r f; do
            case "$f" in
                *.sh)
                    if [ -x "$f" ]; then
                        ngx_notice "launching $f"
                        "$f"
                    else
                        # warn on shell scripts without exec bit
                        ngx_warning "ignoring $f, not executable"
                    fi
                    ;;
                *) ngx_warning "ignoring $f";;
            esac
        done

        ngx_notice "configuration complete; ready for start up"
    else
        ngx_notice "no files found in /docker-entrypoint.d/, skipping configuration"
    fi
fi

if [ -x "$1" -o -x "$(which $1)" ]; then
	exec "$@"
else
	ngx_err "$1: not executable or not found"
fi
