FROM alpine:3.19

RUN \
    set -eux; \
    echo "https://download.angie.software/angie/alpine/v$(cut -d'.' -f1,2 /etc/alpine-release)/main" >> /etc/apk/repositories; \
    apk upgrade --no-cache; \
    apk add --no-cache --upgrade \
        angie \
        angie-console-light \
        angie-module-brotli \
        tini \
        ; \
    ln -sf /dev/stdout /var/log/angie/access.log; \
    ln -sf /dev/stderr /var/log/angie/error.log;

COPY . /

VOLUME /etc/angie/custom

EXPOSE 80

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]

STOPSIGNAL SIGQUIT

CMD ["angie", "-g", "daemon off;"]
