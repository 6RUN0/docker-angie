# check=skip=SecretsUsedInArgOrEnv
# ANGIE_SIGNING_KEY_URL / ANGIE_SIGNING_KEY are a public signing-key URL and the
# keyring path baked into the image, not secrets; the BuildKit check only flags
# the "KEY" substring heuristically, so skip it for this build.
ARG DEBIAN_BASE_IMAGE=debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

# Base is pinned via the ARG default (debian:trixie-slim, by digest); hadolint
# < 2.13 does not resolve ARG defaults and false-flags DL3006 on this FROM.
# hadolint ignore=DL3006
FROM ${DEBIAN_BASE_IMAGE} AS runtime

# Package mirrors. The Debian source list is written from these values, not
# patched from the base image's copy: the build args alone define the sources,
# and an unreachable URL fails the first apt-get update.
# Official Debian redirector over http by default, matching Debian's own
# default. apt integrity comes from the repository's GPG signatures, not the
# transport, so http is safe; it also avoids a ca-certificates bootstrap
# chicken-and-egg (the first apt-get update runs before ca-certificates is
# installed, so an https mirror fails with `certificate verify failed`) and
# keeps caching proxies working. Override at build time, e.g.
# --build-arg DEBIAN_MIRROR=http://mirror.example.org/debian
# (see README "Building" for documented alternatives).
ARG DEBIAN_MIRROR="http://deb.debian.org/debian"
ARG DEBIAN_SECURITY_MIRROR="http://deb.debian.org/debian-security"
# /debian/<version> is appended. The signing key has its own URL: it lives on
# another host that package mirrors usually do not carry, and its digest below
# is checked wherever it came from.
ARG ANGIE_MIRROR="https://download.angie.software/angie"
ARG ANGIE_SIGNING_KEY_URL="https://angie.software/keys/angie-signing.gpg"
ARG ANGIE_SIGNING_KEY="/usr/share/keyrings/angie-signing.gpg"
# Without the digest the build trusts whatever the URL serves: package
# signatures and the ANGIE_VERSION pin are checked against the key already
# accepted. A vendor key rotation must fail the build loudly; get the new value
# with: curl -fsSL "https://angie.software/keys/angie-signing.gpg" | sha256sum
ARG ANGIE_SIGNING_KEY_SHA256="06ef4d35c4f3cf1dfa2dc37751bdd51a95a5fb64390ac11f60587e06183ebfe7"
ARG ANGIE_SOURCE_LIST="/etc/apt/sources.list.d/angie.sources"
# Angie version pinned into the image. Bump via the upstream-check workflow PR;
# release tags (vX.Y.Z-buildN) must match this value (enforced in release.yml).
ARG ANGIE_VERSION=1.12.4
# Console Light has its own release cycle, separate from the server.
ARG ANGIE_CONSOLE_VERSION=1.9.0

# The angie web server https://angie.software
# with the modules:
# + https://github.com/google/ngx_brotli
# + https://github.com/leev/ngx_http_geoip2_module
# + https://github.com/owasp-modsecurity/ModSecurity-nginx
# + https://github.com/yaoweibin/ngx_http_substitutions_filter_module
# + https://github.com/tokers/zstd-nginx-module
# DL3008: ca-certificates/curl/tini/wget are intentionally unpinned (they
# track the base distro); angie and its modules ARE pinned to ${ANGIE_VERSION}:
# the exact Debian version (e.g. 1.11.8-1~trixie) is resolved at build time from
# apt-cache madison, locking the upstream version while tolerating the distro
# revision/suite suffix.
# SC1091: `. /etc/os-release` reads a build-time file hadolint cannot follow.
# DL4006: the pipes need no pipefail - a failing madison pipe yields an empty
# version that the explicit `[ -n ... ] || exit 1` guard catches, and for
# `apt-cache policy | awk` awk treats empty input as a failure itself.
# SC2086: the apt-mark list is word-split on purpose, see that line.
# hadolint ignore=DL3008,SC1091,DL4006,SC2086
RUN \
  set -eux; \
  # Silence debconf's interactive-frontend fallback chatter during apt. Scoped to
  # this layer via export (not a persistent ENV) so the runtime image is unaffected.
  export DEBIAN_FRONTEND=noninteractive; \
  . /etc/os-release; \
  # Debian sources: the base image's suites (release, -updates, -security) on
  # the mirrors above. The file takes the base image's file name and replaces
  # it; a legacy sources.list is removed, or deb.debian.org would remain a
  # second source. Values go through printf %s: dash's echo expands `\n` inside
  # a value and would append a field of its own (`Trusted: yes`) to the stanza.
  rm -f /etc/apt/sources.list; \
  { \
  printf 'Types: deb\n'; \
  printf 'URIs: %s\n' "${DEBIAN_MIRROR}"; \
  printf 'Suites: %s %s-updates\n' "${VERSION_CODENAME}" "${VERSION_CODENAME}"; \
  printf 'Components: main\n'; \
  printf 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg\n'; \
  printf '\n'; \
  printf 'Types: deb\n'; \
  printf 'URIs: %s\n' "${DEBIAN_SECURITY_MIRROR}"; \
  printf 'Suites: %s-security\n' "${VERSION_CODENAME}"; \
  printf 'Components: main\n'; \
  printf 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg\n'; \
  } > /etc/apt/sources.list.d/debian.sources; \
  # Without Error-Mode=any an unreachable or TLS-failing mirror leaves update at
  # exit 0 with only W: lines, and the build fails later at install, with code
  # 100 and no mirror name in the error.
  apt_update() { apt-get update -o APT::Update::Error-Mode=any; }; \
  # Install build dependencies
  apt_update; \
  apt-get full-upgrade -y; \
  saved_apt_mark="$(apt-mark showmanual)"; \
  apt-get install -y --no-install-recommends --no-install-suggests \
  ca-certificates \
  curl \
  ; \
  # Marking everything auto also hits ca-certificates, so it is installed again
  # below with the runtime packages and survives the purge.
  apt-mark auto '.*' > /dev/null; \
  # Unquoted: the list is one package per line, and quoted it would be a single
  # name (`E: Unable to locate package`, code 100).
  [ -z "$saved_apt_mark" ] || apt-mark manual $saved_apt_mark > /dev/null; \
  # Verify the key before Signed-By refers to it: from then on apt would accept
  # a forged one at the next apt-get update.
  tmp_signing_key=$(mktemp); \
  curl -fsSL -o "${tmp_signing_key}" "${ANGIE_SIGNING_KEY_URL}"; \
  signing_key_sha256="$(sha256sum "${tmp_signing_key}")"; \
  [ "${signing_key_sha256%% *}" = "${ANGIE_SIGNING_KEY_SHA256}" ] || \
  { echo "signing key sha256 mismatch for ${ANGIE_SIGNING_KEY_URL}" >&2; exit 1; }; \
  mv "${tmp_signing_key}" "${ANGIE_SIGNING_KEY}"; \
  chmod 0644 "${ANGIE_SIGNING_KEY}"; \
  { \
  printf 'Types: deb\n'; \
  printf 'URIs: %s/%s/%s\n' "${ANGIE_MIRROR}" "${ID}" "${VERSION_ID}"; \
  printf 'Suites: %s\n' "${VERSION_CODENAME}"; \
  printf 'Components: main\n'; \
  printf 'Signed-By: %s\n' "${ANGIE_SIGNING_KEY}"; \
  } > "${ANGIE_SOURCE_LIST}"; \
  # The Angie repository serves only angie* packages: everything else from it
  # gets priority -1, so it cannot shadow a distro package (openssl, curl, tini)
  # with a higher version. Matched by mirror host, not by the Release Origin
  # field, which the repository writes itself. apt compares origin against the
  # host without a port, so a numeric port is cut or the pin would match nothing.
  angie_mirror_host="${ANGIE_MIRROR#*://}"; \
  angie_mirror_host="${angie_mirror_host%%/*}"; \
  case "${angie_mirror_host}" in \[*\]:*) angie_mirror_host="${angie_mirror_host%:*}" ;; \[*\] | *:*[!0-9]*) ;; *:*) angie_mirror_host="${angie_mirror_host%:*}" ;; esac; \
  { \
  printf 'Package: *\n'; \
  printf 'Pin: origin %s\n' "${angie_mirror_host}"; \
  printf 'Pin-Priority: -1\n'; \
  printf '\n'; \
  printf 'Package: angie*\n'; \
  printf 'Pin: origin %s\n' "${angie_mirror_host}"; \
  printf 'Pin-Priority: 500\n'; \
  } > /etc/apt/preferences.d/angie; \
  apt_update; \
  # A pin that matches nothing is silent and would leave the Angie repository
  # at 500 for every package. Every source with this origin must sit at -1, and
  # at least one must exist.
  apt-cache policy | awk -v h="${angie_mirror_host}" '/^ *-?[0-9]+ /{p=$1} $1 == "origin" && $2 == h {n++; if (p != "-1") bad=1} END {exit !(n && !bad)}' || \
  { echo "apt pin 'origin ${angie_mirror_host}' does not hold the Angie repository at priority -1" >&2; exit 1; }; \
  # Resolve the exact Debian package version for the pinned upstream ANGIE_VERSION
  # (the distro revision/suite suffix is not known ahead of time), then install
  # core and modules locked to that one version. The prefix is compared as a
  # string, not a regex, where the dots would match any character.
  angie_pkg_version="$(apt-cache madison angie | awk -v v="${ANGIE_VERSION}" 'index($3, v "-") == 1 {print $3; exit}')"; \
  [ -n "${angie_pkg_version}" ] || { echo "no angie package matching ${ANGIE_VERSION} in the repository" >&2; exit 1; }; \
  console_pkg_version="$(apt-cache madison angie-console-light | awk -v v="${ANGIE_CONSOLE_VERSION}" 'index($3, v "-") == 1 {print $3; exit}')"; \
  [ -n "${console_pkg_version}" ] || { echo "no console package matching ${ANGIE_CONSOLE_VERSION} in the repository" >&2; exit 1; }; \
  apt-get install -y --no-install-recommends --no-install-suggests \
  angie="${angie_pkg_version}" \
  angie-module-brotli="${angie_pkg_version}" \
  angie-module-geoip2="${angie_pkg_version}" \
  angie-module-modsecurity="${angie_pkg_version}" \
  angie-module-subs="${angie_pkg_version}" \
  angie-module-zstd="${angie_pkg_version}" \
  angie-console-light="${console_pkg_version}" \
  ca-certificates \
  tini \
  wget \
  ; \
  ln -sf /dev/stdout /var/log/angie/access.log; \
  ln -sf /dev/stderr /var/log/angie/error.log; \
  # Remove build dependencies and cleanup
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
  apt-get autoclean -y; \
  rm -rf \
  /var/cache/apt/archives/* \
  /var/lib/apt/lists/* \
  /var/log/alternatives.log \
  /var/log/apt* \
  /var/log/dpkg.log \
  ;

COPY rootfs/ /

# Validate the baked-in configuration at build time: a broken default config
# fails the build instead of the first container start.
# /data is the only writable location: the live config tree (copied by
# 10-conf-overlay.sh) and the five temp paths of 010-common.conf. It must exist
# before this test, not only before the first start. One RUN, so the temp dirs
# each `angie -t` leaves in /data/tmp never land in a layer.
RUN set -eux; \
  # Root-owned 0755: workers must not write next to the temp paths the root
  # master chowns (see 10-conf-overlay.sh). The unprivileged stage opens it up.
  mkdir -p /data/tmp; \
  chmod 755 /data /data/tmp; \
  # The default access log is enabled here, before ANGIE_ETC is set, so it lands
  # in the skeleton: /etc/angie must be a working config on its own
  # (`docker run --entrypoint angie`), and the format must match the 40-log.sh
  # default.
  angie-ctl --no-test httpconf en 030-log-format-json.conf 040-log-json.conf; \
  # Test the skeleton itself; the runtime copy under /data/conf is tested by the
  # entrypoint on every start.
  angie -p /etc/angie -c angie.conf -t; \
  # The root `angie -t` left 0700 temp dirs behind; drop them so the runtime
  # creates its own.
  rm -rf /data/tmp/*; \
  # Strip setuid/setgid image-wide (CIS Docker Benchmark 4.8). Hardening, not a
  # fix: the shadow and util-linux binaries that carry the bits give the runtime
  # uid nothing and root has no password, but a future base image must not
  # bring one that does.
  find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod a-s {} +

# Labels that hold for every target. The ones carrying IMAGE_VERSION/VCS_REF
# sit at the end of each final stage, so a new commit leaves this stage cached.
# The base image ARG is redeclared without a value: it inherits the pre-FROM
# one.
ARG DEBIAN_BASE_IMAGE

LABEL org.opencontainers.image.source="https://github.com/6RUN0/docker-angie" \
      org.opencontainers.image.url="https://github.com/6RUN0/docker-angie" \
      org.opencontainers.image.documentation="https://github.com/6RUN0/docker-angie/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="${DEBIAN_BASE_IMAGE}" \
      software.angie.version="${ANGIE_VERSION}"

# Mount /data explicitly when using --read-only. No anonymous volumes: a VOLUME
# on /data or /etc/angie/custom would create one per run without its own -v,
# and they would pile up.
#
# angie-ctl takes the tree root from ANGIE_ETC and runs ANGIE_BIN for its tests,
# so `docker exec <container> angie-ctl ...` edits and tests the live tree, not
# the skeleton. Declared AFTER the build-time angie-ctl call above, which must
# land in /etc/angie. With `pid off` there is no `angie -s reload`; HUP to pid 1
# reaches the master through tini.
ENV ANGIE_ETC=/data/conf \
    ANGIE_BIN=/usr/local/bin/angie-runtime \
    ANGIE_RELOAD_CMD="kill -HUP 1"

# Graceful stop instead of fast: SIGTERM, docker's default, makes angie cut
# responses midway. SIGQUIT closes listeners, finishes open requests and exits
# 0; tini forwards it to the master. worker_shutdown_timeout in angie.conf caps
# long connections below stop_grace_period.
STOPSIGNAL SIGQUIT
ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]

# -p and -c point angie at the live tree under /data; /etc/angie is read-only.
# The relative -c resolves against the prefix, which lets the same tree work
# from both places. They live in CMD, not in the entrypoint, so its `angie -t`
# tests exactly the argument set that is exec'ed.
CMD ["angie", "-p", "/data/conf", "-c", "angie.conf", "-g", "daemon off;"]

# Rootless target (--target unprivileged): shares the read-only skeleton and
# /data runtime layout. Only the listener (8080) and process identity differ
# from the standard target. Docker cannot drop an EXPOSE a stage inherits, so
# runtime declares none.
FROM runtime AS unprivileged

# Identity of the dedicated unprivileged user. uid/gid default to 65532
# (distroless "nonroot") - high enough not to collide with a host's first user.
# Override at build, e.g. --build-arg APP_UID=1234 --build-arg APP_GID=1234.
ARG APP_USER=app
ARG APP_GROUP=app
ARG APP_UID=65532
ARG APP_GID=65532

# The overlay replaces http.d/default.conf (listener on 8080, bindable without
# privileges) and conf.d/05-worker-user.conf (no `user` directive: a non-root
# master cannot switch users and angie would warn on every start).
COPY rootfs-unprivileged/ /

RUN set -eux; \
  # Dedicated unprivileged user owned by this image (not the angie package user),
  # with a fixed uid/gid (see the APP_* build args) so the runtime identity is
  # deterministic and stable across base/package updates and easy to pin via k8s
  # runAsUser/runAsGroup.
  groupadd -g "${APP_GID}" "${APP_GROUP}"; \
  useradd -l -u "${APP_UID}" -g "${APP_GROUP}" -M -N -s /usr/sbin/nologin "${APP_USER}"; \
  # Any `docker run --user` must create /data/conf and its temp dirs. The
  # runtime stage keeps /data root-owned 0755 for the root master of the
  # standard target; here the master and workers share one uid, so a
  # world-writable sticky /data adds no escalation.
  chmod 1777 /data /data/tmp; \
  # Re-test the skeleton with the overlay applied.
  angie -p /etc/angie -c angie.conf -t; \
  # Validation runs as root; runtime users must create their own temp dirs.
  rm -rf /data/tmp/*

# Mark the rootless variant for the shared entrypoint: ANGIE_UNPRIVILEGED lifts
# the "default image requires root" guard, selects port 8080 and skips the
# worker-user steps (chown, readability checks as angie). Both variants toggle
# features in the writable live tree.
ENV ANGIE_UNPRIVILEGED=1

EXPOSE 8080

# Same probe as the standard target (see its HEALTHCHECK comment), on port 8080.
# The shell form is required here: `|| exit 1` needs a shell. DL3025 does not
# tell HEALTHCHECK apart from ENTRYPOINT/CMD, where exec form does matter.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD http_proxy= HTTP_PROXY= wget -q --tries=1 \
    --header='Host: healthz-catchall.invalid' \
    -O /dev/null http://127.0.0.1:8080/healthz || exit 1

# Default to the dedicated unprivileged user (uid/gid 65532 by default); override
# the runtime uid freely with `docker run --user`. Numeric, not a name: kubelet
# with runAsNonRoot rejects a named USER (`image has non-numeric user`).
USER ${APP_UID}:${APP_GID}

# Packaging version (the image tag minus the variant suffix) and source revision,
# stamped into the OCI labels below. Overridden by release.yml; a dev marker for
# local/CI builds. Declared last, so a new VCS_REF per commit invalidates only
# the label layer instead of the stages above.
ARG IMAGE_VERSION=dev
ARG VCS_REF=""

LABEL org.opencontainers.image.title="Angie Docker image (unprivileged)" \
      org.opencontainers.image.description="Rootless Angie (an nginx fork) on port 8080 with Brotli, Zstandard, GeoIP2, ModSecurity (WAF), and substitutions modules" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

# Standard target, the root master on port 80. Last in the file, so a build
# without --target produces it.
FROM runtime AS standard

EXPOSE 80

# The Host header is required: the built-in vhost carries no default_server so
# a consumer can declare one, and without the name the probe would hit the
# consumer's catch-all and go green on a foreign answer. The proxy is cleared:
# the probe inherits the container env, and with http_proxy set wget would go
# to the proxy instead of 127.0.0.1. --tries=1 stops GNU wget (Debian) from
# retrying 444 up to 20 times; busybox accepts it silently.
# The shell form is required here: `|| exit 1` needs a shell. DL3025 does not
# tell HEALTHCHECK apart from ENTRYPOINT/CMD, where exec form does matter.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD http_proxy= HTTP_PROXY= wget -q --tries=1 \
    --header='Host: healthz-catchall.invalid' \
    -O /dev/null http://127.0.0.1/healthz || exit 1

# Same as in the unprivileged stage: declared last, so a new VCS_REF per commit
# invalidates only the label layer.
ARG IMAGE_VERSION=dev
ARG VCS_REF=""

LABEL org.opencontainers.image.title="Angie Docker image" \
      org.opencontainers.image.description="Angie (an nginx fork) with Brotli, Zstandard, GeoIP2, ModSecurity (WAF), and substitutions modules" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"
