ARG DEBIAN_BASE_IMAGE=debian:trixie-slim

FROM ${DEBIAN_BASE_IMAGE}

# Mirror arguments
ARG DEBIAN_MIRROR="http://mirror.selectel.ru/debian"
ARG DEBIAN_SECURITY_MIRROR="http://mirror.selectel.ru/debian-security"
# The angie signing key and source list
ARG ANGIE_SIGNING_KEY_URL="https://angie.software/keys/angie-signing.gpg"
ARG ANGIE_SIGNING_KEY="/usr/share/keyrings/angie-signing.gpg"
ARG ANGIE_SOURCE_LIST="/etc/apt/sources.list.d/angie.sources"
# Helper script for angie control
ARG ANGIE_CTL_REPO="https://github.com/6RUN0/angie-ctl.git"
ARG ANGIE_CTL_COMMIT="4cc390317462da580d3e63907c68f775de879048"
ARG ANGIE_CTL="/usr/local/bin/angie-ctl"

# The angie web server https://angie.software
# with the modules:
# + https://github.com/google/ngx_brotli
# + https://github.com/leev/ngx_http_geoip2_module
# + https://github.com/owasp-modsecurity/ModSecurity-nginx
# + https://github.com/yaoweibin/ngx_http_substitutions_filter_module
RUN \
  set -eux; \
  # Configure apt to use a local mirror
  apt_mirror() { \
  sed -i \
  -e "s|http://deb\.debian\.org/debian-security|$3|g" \
  -e "s|http://deb\.debian\.org/debian|$2|g" \
  "$1"; \
  }; \
  # Helper function to clone a specific git commit
  # x_git_clone <repo_url> <commit_hash>
  x_git_clone() { \
  git init -b main .; \
  git remote add origin "$1";\
  git fetch --depth 1 origin "$2"; \
  git checkout -b "x-git-clone-$2" FETCH_HEAD; \
  }; \
  [ -w "/etc/apt/sources.list.d/debian.sources" ] && \
  apt_mirror "/etc/apt/sources.list.d/debian.sources" "${DEBIAN_MIRROR}" "${DEBIAN_SECURITY_MIRROR}"; \
  [ -w "/etc/apt/sources.list" ] && \
  apt_mirror "/etc/apt/sources.list" "${DEBIAN_MIRROR}" "${DEBIAN_SECURITY_MIRROR}"; \
  # Install build dependencies
  apt-get update; \
  apt-get full-upgrade -y; \
  saved_apt_mark="$(apt-mark showmanual)"; \
  apt-get install -y --no-install-recommends --no-install-suggests \
  ca-certificates \
  curl \
  git \
  ; \
  apt-mark auto '.*' > /dev/null; \
  [ -z "$saved_apt_mark" ] || apt-mark manual "$saved_apt_mark" > /dev/null; \
  curl -fsSL -o "${ANGIE_SIGNING_KEY}" "${ANGIE_SIGNING_KEY_URL}"; \
  { \
  echo "Types: deb"; \
  echo "URIs: https://download.angie.software/angie/$(. /etc/os-release && echo "$ID/$VERSION_ID")"; \
  echo "Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")"; \
  echo "Components: main"; \
  echo "Signed-By: ${ANGIE_SIGNING_KEY}"; \
  } > "${ANGIE_SOURCE_LIST}"; \
  apt-get update; \
  apt-get install -y --no-install-recommends --no-install-suggests \
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
  tmp_angie_ctl=$(mktemp -d); \
  cd "${tmp_angie_ctl}"; \
  x_git_clone "${ANGIE_CTL_REPO}" "${ANGIE_CTL_COMMIT}"; \
  mv angie-ctl.sh "${ANGIE_CTL}"; \
  chmod +x "${ANGIE_CTL}"; \
  # Remove build dependencies and cleanup
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
  apt-get autoclean -y; \
  rm -rf \
  "${tmp_angie_ctl}" \
  /var/cache/apt/archives/* \
  /var/lib/apt/lists/* \
  /var/log/alternatives.log \
  /var/log/apt* \
  /var/log/dpkg.log \
  ;

COPY rootfs/ /

VOLUME /etc/angie/custom

EXPOSE 80

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]

CMD ["angie", "-g", "daemon off;"]
