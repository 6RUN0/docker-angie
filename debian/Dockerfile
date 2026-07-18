# check=skip=SecretsUsedInArgOrEnv
# ANGIE_SIGNING_KEY_URL / ANGIE_SIGNING_KEY are a public signing-key URL and the
# keyring path baked into the image, not secrets; the BuildKit check only flags
# the "KEY" substring heuristically, so skip it for this build.
ARG DEBIAN_BASE_IMAGE=debian:trixie-slim

# Base is pinned via the ARG default (debian:trixie-slim); hadolint < 2.13 does
# not resolve ARG defaults and false-flags DL3006 on this FROM.
# hadolint ignore=DL3006
FROM ${DEBIAN_BASE_IMAGE}

# Mirror arguments
# Official Debian redirector over http by default, matching Debian's own
# default. apt integrity comes from the repository's GPG signatures, not the
# transport, so http is safe; it also avoids a ca-certificates bootstrap
# chicken-and-egg (the first apt-get update runs before ca-certificates is
# installed, so an https mirror would fail TLS verification on the slim base)
# and keeps caching proxies working. Override at build time, e.g.
# --build-arg DEBIAN_MIRROR=http://mirror.example.org/debian
# (see README "Building" for documented alternatives).
ARG DEBIAN_MIRROR="http://deb.debian.org/debian"
ARG DEBIAN_SECURITY_MIRROR="http://deb.debian.org/debian-security"
# The angie signing key and source list
ARG ANGIE_SIGNING_KEY_URL="https://angie.software/keys/angie-signing.gpg"
ARG ANGIE_SIGNING_KEY="/usr/share/keyrings/angie-signing.gpg"
ARG ANGIE_SOURCE_LIST="/etc/apt/sources.list.d/angie.sources"
# Angie version pinned into the image. Bump via the upstream-check workflow PR;
# release tags (vX.Y.Z-buildN) must match this value (enforced in release.yml).
ARG ANGIE_VERSION=1.12.1
# Packaging version (the image tag minus the variant suffix) and source revision,
# stamped into the OCI labels below. Overridden by release.yml; a dev marker for
# local/CI builds.
ARG IMAGE_VERSION=dev
ARG VCS_REF=""
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
# + https://github.com/tokers/zstd-nginx-module
# DL3008: ca-certificates/curl/git/tini/wget are intentionally unpinned (they
# track the base distro); angie and its modules ARE pinned to ${ANGIE_VERSION}:
# the exact Debian version (e.g. 1.11.8-1~trixie) is resolved at build time from
# apt-cache madison, locking the upstream version while tolerating the distro
# revision/suite suffix.
# DL3003: the `cd` into the mktemp angie-ctl clone is scoped to this layer;
# WORKDIR would leak into later instructions. SC1091: `. /etc/os-release` reads
# a build-time file hadolint cannot follow. DL4006: the madison pipe needs no
# pipefail — Debian's /bin/sh is dash (no `set -o pipefail`), and a failing pipe
# yields an empty version that the explicit `[ -n ... ] || exit 1` guard catches.
# hadolint ignore=DL3008,DL3003,SC1091,DL4006
RUN \
  set -eux; \
  # Silence debconf's interactive-frontend fallback chatter during apt. Scoped to
  # this layer via export (not a persistent ENV) so the runtime image is unaffected.
  export DEBIAN_FRONTEND=noninteractive; \
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
  # Resolve the exact Debian package version for the pinned upstream ANGIE_VERSION
  # (the distro revision/suite suffix is not known ahead of time), then install
  # core and modules locked to that one version.
  angie_pkg_version="$(apt-cache madison angie | awk -v v="${ANGIE_VERSION}" '$3 ~ "^"v"-" {print $3; exit}')"; \
  [ -n "${angie_pkg_version}" ] || { echo "no angie package matching ${ANGIE_VERSION} in the repository" >&2; exit 1; }; \
  apt-get install -y --no-install-recommends --no-install-suggests \
  angie="${angie_pkg_version}" \
  angie-module-brotli="${angie_pkg_version}" \
  angie-module-geoip2="${angie_pkg_version}" \
  angie-module-modsecurity="${angie_pkg_version}" \
  angie-module-subs="${angie_pkg_version}" \
  angie-module-zstd="${angie_pkg_version}" \
  tini \
  wget \
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

# Validate the baked-in configuration at build time: a broken default config
# fails the build instead of the first container start.
RUN angie -t

LABEL org.opencontainers.image.title="Angie Docker image" \
      org.opencontainers.image.description="Angie (an nginx fork) with Brotli, GeoIP2, ModSecurity (WAF), and substitutions modules" \
      org.opencontainers.image.source="https://github.com/6RUN0/docker-angie" \
      org.opencontainers.image.url="https://github.com/6RUN0/docker-angie" \
      org.opencontainers.image.documentation="https://github.com/6RUN0/docker-angie/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      software.angie.version="${ANGIE_VERSION}"

VOLUME /etc/angie/custom

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]

CMD ["angie", "-g", "daemon off;"]
