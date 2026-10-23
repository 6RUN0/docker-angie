# check=skip=SecretsUsedInArgOrEnv
# ANGIE_SIGNING_KEY_URL / ANGIE_SIGNING_KEY are a public signing-key URL and the
# keyring path baked into the image, not secrets; the BuildKit check only flags
# the "KEY" substring heuristically, so skip it for this build.
ARG ALPINE_BASE_IMAGE=alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

# Base is pinned via the ARG default (alpine:3.24, by digest); hadolint < 2.13
# does not resolve ARG defaults and false-flags DL3006 on this FROM.
# hadolint ignore=DL3006
FROM ${ALPINE_BASE_IMAGE} AS runtime

# Package mirrors. /etc/apk/repositories is written from these values, not
# patched from the base image's copy: the build args alone define the sources,
# and an unreachable URL fails the first apk. https works from the first apk:
# the base ships ca-certificates-bundle (debian-slim does not, see its
# Dockerfile). Package integrity rests on the apk index signature, not the
# transport. Override at build time, e.g.
# --build-arg ALPINE_MIRROR=https://mirror.example.org/alpine
ARG ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
# /alpine/v<branch>/main is appended. The signing key has its own URL: it lives
# on another host that package mirrors usually do not carry, and its digest
# below is checked wherever it came from.
ARG ANGIE_MIRROR="https://download.angie.software/angie"
ARG ANGIE_SIGNING_KEY_URL="https://angie.software/keys/angie-signing.rsa"
ARG ANGIE_SIGNING_KEY="/etc/apk/keys/angie-signing.rsa"
# Without the digest the build trusts whatever the URL serves: package
# signatures and the ANGIE_VERSION pin are checked against the key already
# accepted. A vendor key rotation must fail the build loudly; get the new value
# with: curl -fsSL "https://angie.software/keys/angie-signing.rsa" | sha256sum
ARG ANGIE_SIGNING_KEY_SHA256="180802f4ce816e61d9f9e325566b10f4e6c175215dddcb1aaf2185c4ab01e376"
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
# DL3018: tini and CA certificates track the base distro; angie and
# its modules ARE pinned to ${ANGIE_VERSION} via apk's fuzzy `=~` operator, which
# locks the upstream version while tolerating Alpine packaging revisions (-rN).
# DL3047: wget without a progress bar is fine in a build layer.
# hadolint ignore=DL3018,DL3047
RUN \
  set -eux; \
  # Verify the key before it lands in /etc/apk/keys: files there are trusted,
  # and apk would accept a forged one before the first apk add.
  tmp_signing_key=$(mktemp); \
  wget -O "${tmp_signing_key}" "${ANGIE_SIGNING_KEY_URL}"; \
  signing_key_sha256="$(sha256sum "${tmp_signing_key}")"; \
  [ "${signing_key_sha256%% *}" = "${ANGIE_SIGNING_KEY_SHA256}" ] || \
  { echo "signing key sha256 mismatch for ${ANGIE_SIGNING_KEY_URL}" >&2; exit 1; }; \
  mv "${tmp_signing_key}" "${ANGIE_SIGNING_KEY}"; \
  chmod 0644 "${ANGIE_SIGNING_KEY}"; \
  # The base image's branches (main, plus community for tini) and the Angie
  # repository, all on the mirrors above. The @angie tag means a package comes
  # from the Angie repository only when requested with the tag, so it cannot
  # shadow musl, openssl, pcre2 or tini from the distro. Values go through
  # printf %s: busybox echo would expand a `\` inside them.
  alpine_branch="v$(cut -d'.' -f1,2 /etc/alpine-release)"; \
  { \
  printf '%s/%s/main\n' "${ALPINE_MIRROR}" "${alpine_branch}"; \
  printf '%s/%s/community\n' "${ALPINE_MIRROR}" "${alpine_branch}"; \
  printf '@angie %s/alpine/%s/main\n' "${ANGIE_MIRROR}" "${alpine_branch}"; \
  } > /etc/apk/repositories; \
  apk upgrade --no-cache; \
  apk add --no-cache \
  "angie@angie=~${ANGIE_VERSION}" \
  "angie-module-brotli@angie=~${ANGIE_VERSION}" \
  "angie-module-geoip2@angie=~${ANGIE_VERSION}" \
  "angie-module-modsecurity@angie=~${ANGIE_VERSION}" \
  "angie-module-subs@angie=~${ANGIE_VERSION}" \
  "angie-module-zstd@angie=~${ANGIE_VERSION}" \
  "angie-console-light@angie=~${ANGIE_CONSOLE_VERSION}" \
  ca-certificates \
  tini \
  ; \
  ln -sf /dev/stdout /var/log/angie/access.log; \
  ln -sf /dev/stderr /var/log/angie/error.log;

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
  # fix: no such file helps the runtime uid and root has no password, but a
  # future base image must not bring one that does. alpine:3.24 has none; the
  # line keeps both Dockerfiles in step.
  find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod a-s {} +

# Labels that hold for every target. The ones carrying IMAGE_VERSION/VCS_REF
# sit at the end of each final stage, so a new commit leaves this stage cached.
# The base image ARG is redeclared without a value: it inherits the pre-FROM
# one.
ARG ALPINE_BASE_IMAGE

LABEL org.opencontainers.image.source="https://github.com/6RUN0/docker-angie" \
      org.opencontainers.image.url="https://github.com/6RUN0/docker-angie" \
      org.opencontainers.image.documentation="https://github.com/6RUN0/docker-angie/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="${ALPINE_BASE_IMAGE}" \
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
  addgroup -g "${APP_GID}" "${APP_GROUP}"; \
  adduser -D -H -u "${APP_UID}" -G "${APP_GROUP}" -s /sbin/nologin "${APP_USER}"; \
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
