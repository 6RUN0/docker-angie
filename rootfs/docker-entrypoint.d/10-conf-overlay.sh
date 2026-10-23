#!/bin/sh -e

. /docker-entrypoint-common.sh

# The shipped /etc/angie is a read-only skeleton; the live tree is its copy
# under /data, rebuilt on every start. This gives three properties at once:
# config is writable even on a read-only root, no state of a previous run
# survives a restart (no orphaned symlinks pile up on a persistent volume), and
# an image update reaches the live config without re-creating the volume.
#
# This script runs first: every other toggle edits the copy.
skeleton="/etc/angie"

# Not a *.conf name: angie.conf includes by *.conf masks, so the marker never
# gets parsed as config.
marker_name=".angie-conf-overlay"
marker="$ANGIE_CONF_DIR/$marker_name"
marker_signature="angie-managed-conf-v1"

# Managed files must remain readable by the root image's worker user.
umask 022

# A real write catches a read-only mount that mode-bit checks cannot detect.
# mktemp, not a pid-based name: /data may be shared with another writer that
# could pre-plant a predictable probe path as a link.
if ! mkdir -p "$ANGIE_DATA_DIR" 2>/dev/null ||
  ! probe=$(mktemp "$ANGIE_DATA_DIR/.writable-probe.XXXXXX" 2>/dev/null); then
  ngx_err "$ANGIE_DATA_DIR is not writable by uid $(id -u): the live configuration tree and the temporary files live there. Mount it writable, for example --tmpfs /data or -v angie-data:/data, or run with a uid that owns it."
  exit 1
fi
rm -f "$probe"

# Never follow a consumer-controlled live-tree symlink during cleanup.
if [ -L "$ANGIE_CONF_DIR" ]; then
  ngx_err "$ANGIE_CONF_DIR is a symbolic link; refusing to rebuild configuration through it"
  exit 1
fi

if [ -e "$ANGIE_CONF_DIR" ] && [ ! -d "$ANGIE_CONF_DIR" ]; then
  ngx_err "$ANGIE_CONF_DIR exists but is not a directory"
  exit 1
fi

if [ -L "$ANGIE_TMP_DIR" ]; then
  ngx_err "$ANGIE_TMP_DIR is a symbolic link; refusing to place Angie temporary files outside $ANGIE_DATA_DIR"
  exit 1
fi
if [ -e "$ANGIE_TMP_DIR" ] && [ ! -d "$ANGIE_TMP_DIR" ]; then
  ngx_err "$ANGIE_TMP_DIR exists but is not a directory"
  exit 1
fi

# Only a regular marker with this image's signature authorizes replacement.
# Without this check a volume mounted at /data/conf itself (instead of /data)
# would silently lose its contents on every start.
if [ -d "$ANGIE_CONF_DIR" ] && [ -n "$(ls -A "$ANGIE_CONF_DIR" 2>/dev/null)" ]; then
  if [ -L "$marker" ] || [ ! -f "$marker" ] ||
    [ "$(cat "$marker" 2>/dev/null)" != "$marker_signature" ]; then
    ngx_err "$ANGIE_CONF_DIR is not empty and has no valid $marker_name; refusing to replace consumer data. Mount custom configuration at /etc/angie/custom and mount writable storage at $ANGIE_DATA_DIR."
    exit 1
  fi
fi

mkdir -p "$ANGIE_CONF_DIR" "$ANGIE_TMP_DIR"

# The tree must belong to this run's uid. A directory of another uid on a
# shared volume could carry a planted marker and files the copy below cannot
# remove. stat, not `[ -O ]`, which POSIX sh lacks.
conf_owner=$(stat -c %u "$ANGIE_CONF_DIR")
if [ "$conf_owner" != "$(id -u)" ]; then
  ngx_err "$ANGIE_CONF_DIR belongs to uid $conf_owner, not to uid $(id -u) this container runs as: it was written by another uid and is not rebuilt over. Run with the uid that owns it, give this container a volume of its own (--tmpfs /data or a new -v angie-data:/data), or change the owner from outside: docker run --rm -u 0 -v <volume>:/data --entrypoint chown <image> -R $(id -u):$(id -g) $ANGIE_DATA_DIR"
  exit 1
fi

# After the owner check, so a refused start leaves another uid's data intact.
if is_root && [ -z "${ANGIE_UNPRIVILEGED:-}" ]; then
  # The root master chowns each temp path to the worker on every start and
  # reload, following links. A worker-writable parent would let a compromised
  # worker swap a temp dir for a link to a root file, so the parent is rebuilt
  # root-owned 0755 on each start; temp contents never outlive a run anyway.
  # Contents only: /data/tmp may be a mount point, where rmdir fails with EBUSY.
  for stale in "$ANGIE_TMP_DIR"/* "$ANGIE_TMP_DIR"/.*; do
    case "${stale##*/}" in
    . | .. | '*' | '.*') continue ;; # glob matched nothing
    esac
    rm -rf "$stale"
  done
  chown 0:0 "$ANGIE_TMP_DIR"
  chmod 755 "$ANGIE_TMP_DIR"
fi

# The marker is written BEFORE cleanup and survives it: a copy interrupted
# halfway would otherwise leave an unmarked non-empty tree that the check
# above refuses on every later start.
printf '%s\n' "$marker_signature" >"$marker"

# Keep the mount point itself and replace only its managed contents: /data/conf
# may be a mount point, where `rm -rf` on the directory fails with EBUSY.
for stale in "$ANGIE_CONF_DIR"/* "$ANGIE_CONF_DIR"/.*; do
  case "${stale##*/}" in
  . | .. | "$marker_name" | '*' | '.*') continue ;; # glob matched nothing
  esac
  rm -rf "$stale"
done

# Custom configuration stays mounted at its stable path under /etc: its
# includes are absolute, and a copy would be a second, stale mirror. -R, not
# -a: a non-root process cannot preserve ownership and `cp -a` would complain
# on every file.
for entry in "$skeleton"/*; do
  case "$entry" in
  "$skeleton/custom") continue ;;
  esac
  cp -R "$entry" "$ANGIE_CONF_DIR/"
done

# Fail early when the root image's angie workers cannot reach the live tree,
# e.g. a bind-mounted /data whose parents lack search permission.
chmod 755 "$ANGIE_CONF_DIR"
if is_root && [ -z "${ANGIE_UNPRIVILEGED:-}" ] &&
  ! su -s /bin/sh angie -c "test -r '$ANGIE_CONF_DIR/angie.conf'"; then
  ngx_err "$ANGIE_CONF_DIR is not readable by the angie worker user; ensure every parent of $ANGIE_CONF_DIR is searchable"
  exit 1
fi

# A kernel without IPv6 (ipv6.disable=1 or no CONFIG_IPV6) cannot create an
# AF_INET6 socket, and `listen [::]:<port>` fails startup with `(97: Address
# family not supported)`. The sign is a missing /proc/net/if_inet6; the
# disable_ipv6 sysctl does not remove it and keeps the line working.
if [ ! -e /proc/net/if_inet6 ]; then
  sed -i "/^[[:space:]]*listen \[::\]:${ANGIE_HTTP_PORT};/d" "$ANGIE_CONF_DIR/http.d/default.conf"
  ngx_notice "IPv6 is unavailable; the built-in listener serves 0.0.0.0:${ANGIE_HTTP_PORT} only"
fi

ngx_info "live configuration tree rebuilt in $ANGIE_CONF_DIR from $skeleton"
