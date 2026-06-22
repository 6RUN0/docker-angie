# check=skip=SecretsUsedInArgOrEnv
# ANGIE_SIGNING_KEY_URL / ANGIE_SIGNING_KEY are a public signing-key URL and the
# keyring path baked into the image, not secrets; the BuildKit check only flags
# the "KEY" substring heuristically, so skip it for this build.
ARG ALPINE_BASE_IMAGE=alpine:3.22

# Base is pinned via the ARG default (alpine:3.22); hadolint < 2.13 does not
# resolve ARG defaults and false-flags DL3006 on this FROM.
# hadolint ignore=DL3006
FROM ${ALPINE_BASE_IMAGE}

# Angie mirror arguments
ARG ANGIE_SIGNING_KEY_URL="https://angie.software/keys/angie-signing.rsa"
ARG ANGIE_SIGNING_KEY="/etc/apk/keys/angie-signing.rsa"
# Helper script for angie control
ARG ANGIE_CTL_REPO="https://github.com/6RUN0/angie-ctl.git"
ARG ANGIE_CTL_COMMIT="a69c1d102ec99a893a11f08015ea150c1e287482"
ARG ANGIE_CTL="/usr/local/bin/angie-ctl"

# The angie web server https://angie.software
# with the modules:
# + https://github.com/google/ngx_brotli
# + https://github.com/leev/ngx_http_geoip2_module
# + https://github.com/owasp-modsecurity/ModSecurity-nginx
# + https://github.com/yaoweibin/ngx_http_substitutions_filter_module
# DL3018: angie + modules are deliberately unpinned (the image tracks upstream
# security updates, and core/modules must stay on the same current version).
# DL3003: the `cd` into the mktemp angie-ctl clone is scoped to this layer;
# WORKDIR would leak into later instructions. DL3047: wget without a progress
# bar is fine in a build layer.
# hadolint ignore=DL3018,DL3003,DL3047
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

# Validate the baked-in configuration at build time: a broken default config
# fails the build instead of the first container start.
RUN angie -t

VOLUME /etc/angie/custom

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]

CMD ["angie", "-g", "daemon off;"]
