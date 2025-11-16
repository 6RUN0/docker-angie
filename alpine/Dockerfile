ARG ALPINE_BASE_IMAGE=alpine:3.22

FROM ${ALPINE_BASE_IMAGE}

# Angie mirror arguments
ARG ANGIE_SIGNING_KEY_URL="https://angie.software/keys/angie-signing.rsa"
ARG ANGIE_SIGNING_KEY="/etc/apk/keys/angie-signing.rsa"
# Helper script for angie control
ARG ANGIE_CTL_REPO="https://github.com/6RUN0/angie-ctl.git"
ARG ANGIE_CTL_COMMIT="cf55b243cc2b6f8b6e8b69d2815bfcc861da38e3"
ARG ANGIE_CTL="/usr/local/bin/angie-ctl"

# The angie web server https://angie.software
# with the modules:
# + https://github.com/google/ngx_brotli
# + https://github.com/leev/ngx_http_geoip2_module
# + https://github.com/owasp-modsecurity/ModSecurity-nginx
# + https://github.com/yaoweibin/ngx_http_substitutions_filter_module
RUN \
  set -eux; \
  wget -O "${ANGIE_SIGNING_KEY}" "${ANGIE_SIGNING_KEY_URL}"; \
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
  ln -sf /dev/stderr /var/log/angie/error.log; \
  # Install angie-ctl helper script
  apk add --no-cache --update --virtual .install-dependencies \
  git \
  ; \
  # Helper function to clone a specific git commit
  # x_git_clone <repo_url> <commit_hash>
  x_git_clone() { \
  git init -b main .; \
  git remote add origin "$1";\
  git fetch --depth 1 origin "$2"; \
  git checkout -b "x-git-clone-$2" FETCH_HEAD; \
  }; \
  tmp_angie_ctl=$(mktemp -d); \
  cd "${tmp_angie_ctl}"; \
  x_git_clone "${ANGIE_CTL_REPO}" "${ANGIE_CTL_COMMIT}"; \
  mv angie-ctl.sh "${ANGIE_CTL}"; \
  chmod +x "${ANGIE_CTL}"; \
  apk del --purge --no-network .install-dependencies; \
  rm -rf "${tmp_angie_ctl}";

COPY rootfs/ /

VOLUME /etc/angie/custom

EXPOSE 80

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]

CMD ["angie", "-g", "daemon off;"]
