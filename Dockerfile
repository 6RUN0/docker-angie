FROM alpine:3.22

# The angie web server https://angie.software
# with the modules:
# + https://github.com/google/ngx_brotli
# + https://github.com/owasp-modsecurity/ModSecurity-nginx
# + https://github.com/yaoweibin/ngx_http_substitutions_filter_module
RUN \
  set -eux; \
  wget -O "/etc/apk/keys/angie-signing.rsa" "https://angie.software/keys/angie-signing.rsa"; \
  echo "https://download.angie.software/angie/alpine/v$(cut -d'.' -f1,2 /etc/alpine-release)/main" >> "/etc/apk/repositories"; \
  apk upgrade --no-cache; \
  apk add --no-cache --upgrade \
  angie \
  angie-module-brotli \
  angie-module-geoip2 \
  angie-module-modsecurity \
  angie-module-subs \
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
