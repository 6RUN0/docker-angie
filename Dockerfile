FROM alpine:latest

RUN \
    set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache --upgrade \
        nginx \
        nginx-mod-http-brotli \
        nginx-mod-stream \
        tini \
        ; \
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log;

COPY . /

VOLUME /etc/nginx/custom

EXPOSE 80

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
