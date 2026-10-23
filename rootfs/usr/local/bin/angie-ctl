#!/bin/sh

# Simple a2enconf/a2enmod-like helper for Angie
# Works with:
#   /etc/angie/http-conf-available.d  -> http-conf.d
#   /etc/angie/modules-available.d    -> modules.d

set -u

# Single source of truth for the version. The release workflow asserts that a
# pushed tag 'vX.Y.Z' matches this value, so bump it together with the tag.
VERSION=0.1.0

: "${ANGIE_ETC:=/etc/angie}"

# ANGIE_ETC is interpolated into every path; require an absolute base so a
# caller-supplied relative value cannot redirect operations into the CWD.
case "$ANGIE_ETC" in
/*) ;;
*)
  echo "ANGIE_ETC must be an absolute path: $ANGIE_ETC" >&2
  exit 1
  ;;
esac
# A leading slash is not enough: '..' segments or symlink indirection could
# still redirect operations outside the intended tree, so reject traversal
# tokens up front. This matters when the tool is wrapped (sudo/CI) and the
# value comes from a less-trusted caller.
case "$ANGIE_ETC" in
*/../* | */.. | *//*)
  echo "ANGIE_ETC must not contain '..' or '//': $ANGIE_ETC" >&2
  exit 1
  ;;
esac

# Binary used for the post-change configuration test (see run_config_test).
: "${ANGIE_BIN:=angie}"

# Command run by --reload after a successful en/dis/prune batch. A plain
# command line (word-split on whitespace), executed under the same fixed PATH
# as the config test. Override to integrate with a service manager, e.g.
# ANGIE_RELOAD_CMD='systemctl reload angie'.
: "${ANGIE_RELOAD_CMD:=$ANGIE_BIN -s reload}"

# A trusted PATH for the config test and reload, so an inherited/hostile PATH
# cannot redirect $ANGIE_BIN / the reload command to an attacker binary (both
# run as root in the normal deployment). Absolute commands bypass the lookup.
SAFE_PATH=/usr/sbin:/usr/bin:/sbin:/bin

# A literal tab and newline. They are the undo log's field and record
# separators (see do_rollback) and are also rejected by is_safe_name so a
# config name can never corrupt that log. The trailing 'x' guards the newline
# from the command substitution that would otherwise strip it.
TAB=$(printf '\t')
NL=$(printf '\nx')
NL=${NL%x}

print_usage() {
  cat <<EOF
Usage:
  $0 [options] {httpconf|mod} {en|dis|ls|ls-available|ls-enabled|status|prune} [name ...]

Commands:
  en, dis         enable/disable named configs (creates/removes symlinks)
  status          print on/off per name; exit 0 only if all are enabled
  prune           remove every orphaned enabled symlink (no source available)
  ls              list available with [on ]/[off]/[orphan] markers
  ls-available, ls-enabled  list one directory

Options (must be given separately; -nT is not split into -n -T):
  -n, --dry-run   show what en/dis/prune would change, without modifying anything
  -T, --no-test   skip the '$ANGIE_BIN -t' config test that otherwise runs
                  once after a successful en/dis/prune batch
  -r, --reload    reload Angie ('\$ANGIE_RELOAD_CMD') after a successful batch
  --rollback      if the post-batch config test fails, undo this run's changes
                  (cannot be combined with --no-test)
  -V, --version   show the version and exit
  -h, --help, help  show this help and exit

Environment:
  ANGIE_ETC         config root (default /etc/angie; must be absolute)
  ANGIE_BIN         binary for the config test (default angie)
  ANGIE_RELOAD_CMD  reload command for --reload (default '\$ANGIE_BIN -s reload')

Examples:
  $0 httpconf en drupal # resolves drupal or drupal.conf
  $0 httpconf en drupal.conf
  $0 --reload httpconf dis drupal
  $0 --rollback mod en geoip
  $0 httpconf status drupal
  $0 httpconf prune
  $0 httpconf ls
EOF
}

# Error exit: help to stderr, non-zero status.
usage() {
  print_usage >&2
  exit 1
}

# Global options precede the type/command. -h is honored even with no other
# arguments so help is always reachable with a success status.
DRY_RUN=0
NO_TEST=0
RELOAD=0
ROLLBACK=0
while [ $# -gt 0 ]; do
  case "$1" in
  -h | --help | help)
    print_usage
    exit 0
    ;;
  -V | --version)
    echo "angie-ctl $VERSION"
    exit 0
    ;;
  -n | --dry-run)
    DRY_RUN=1
    shift
    ;;
  -T | --no-test)
    NO_TEST=1
    shift
    ;;
  -r | --reload)
    RELOAD=1
    shift
    ;;
  --rollback)
    ROLLBACK=1
    shift
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "Unknown option: $1" >&2
    usage
    ;;
  *)
    break
    ;;
  esac
done

# Rollback is triggered by a failing config test, so it is meaningless without
# one. Reject the contradictory combination up front rather than silently
# ignoring --rollback.
if [ "$ROLLBACK" -eq 1 ] && [ "$NO_TEST" -eq 1 ]; then
  echo "--rollback cannot be combined with --no-test" >&2
  usage
fi

[ $# -ge 2 ] || usage

TYPE=$1
CMD=$2
shift 2

case "$TYPE" in
httpconf | httpconfs | "http-conf" | "http-confs")
  AVAILABLE_DIR="$ANGIE_ETC/http-conf-available.d"
  ENABLED_DIR="$ANGIE_ETC/http-conf.d"
  KIND="http-conf"
  ;;
mod | mods | module | modules)
  AVAILABLE_DIR="$ANGIE_ETC/modules-available.d"
  ENABLED_DIR="$ANGIE_ETC/modules.d"
  KIND="module"
  ;;
*)
  echo "Unknown type: $TYPE" >&2
  usage
  ;;
esac

ensure_dirs() {
  if [ ! -d "$AVAILABLE_DIR" ]; then
    echo "Missing directory: $AVAILABLE_DIR" >&2
    exit 1
  fi
  if [ ! -d "$ENABLED_DIR" ]; then
    echo "Missing directory: $ENABLED_DIR" >&2
    exit 1
  fi
}

# Fail early with an actionable message instead of a raw ln/rm "Permission
# denied" when the enabled directory (normally under /etc) is not writable.
require_writable_enabled() {
  if [ ! -w "$ENABLED_DIR" ]; then
    echo "No write permission for $ENABLED_DIR (try running as root)" >&2
    exit 1
  fi
}

# Validate the whole configuration once, AFTER a batch of changes is applied.
# Running it per item would spuriously fail on valid intermediate states (e.g.
# a config enabled before the module it needs). On failure it reports but does
# not roll back: a config already broken before this run must not block every
# future operation. Returns non-zero so the caller's exit status reflects it.
# Argument: number of changes actually applied in this run.
run_config_test() {
  changes=$1
  [ "$NO_TEST" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$changes" -gt 0 ] || return 0
  # Resolve and run the test binary under SAFE_PATH so an inherited/hostile
  # PATH cannot redirect '$ANGIE_BIN -t' to an attacker binary (it runs as root
  # in the normal deployment). An absolute ANGIE_BIN bypasses PATH lookup
  # entirely and is honored as-is.
  if ! PATH="$SAFE_PATH" command -v "$ANGIE_BIN" >/dev/null 2>&1; then
    echo "Note: '$ANGIE_BIN' not found in PATH; skipping config test" >&2
    return 0
  fi

  # Stay quiet on success; show the binary's output only when it fails. The
  # caller (finalize_batch) decides and reports whether the failed changes are
  # left in place or rolled back, so don't prejudge that wording here.
  if test_output=$(PATH="$SAFE_PATH" "$ANGIE_BIN" -t 2>&1); then
    return 0
  fi
  echo "Config test failed ('$ANGIE_BIN -t'):" >&2
  printf '%s\n' "$test_output" >&2
  return 1
}

# Reload Angie once, AFTER a batch is applied and the config test passed.
# Skipped unless --reload was given and at least one change was applied.
# Argument: number of changes actually applied in this run.
run_reload() {
  changes=$1
  [ "$RELOAD" -eq 1 ] || return 0
  [ "$changes" -gt 0 ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would reload: $ANGIE_RELOAD_CMD"
    return 0
  fi
  # ANGIE_RELOAD_CMD is a trusted command line; intentional word splitting.
  # shellcheck disable=SC2086
  if PATH="$SAFE_PATH" $ANGIE_RELOAD_CMD; then
    return 0
  fi
  echo "Reload failed ('$ANGIE_RELOAD_CMD')" >&2
  return 1
}

# Undo this run's changes when --rollback is set and the config test failed.
# UNDO_KIND selects the inverse operation; UNDO_LIST is the newline-separated
# record built by the mutating function (this assumes config names contain no
# newline or tab, which holds for real Angie configs and is enforced upstream
# by is_safe_name rejecting path separators and those control characters):
#   created -> one ENABLED_DIR symlink path per line; inverse is rm
#   removed -> "<symlink path>\t<link target>" per line; inverse is ln -s
# The loops read from a here-document, not a pipe, so they run in this shell
# and a failed step can be counted; returns non-zero if any undo step failed.
UNDO_KIND=""
UNDO_LIST=""
do_rollback() {
  rollback_failures=0
  case "$UNDO_KIND" in
  created)
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      if rm -f "$link"; then
        echo "Rolled back enable: ${link##*/}" >&2
      else
        echo "Rollback failed (could not remove $link)" >&2
        rollback_failures=$((rollback_failures + 1))
      fi
    done <<EOF
$UNDO_LIST
EOF
    ;;
  removed)
    while IFS=$TAB read -r link target; do
      [ -n "$link" ] || continue
      if [ -z "$target" ]; then
        echo "Cannot roll back ${link##*/}: unknown link target" >&2
        rollback_failures=$((rollback_failures + 1))
        continue
      fi
      if ln -s "$target" "$link"; then
        echo "Rolled back disable: ${link##*/}" >&2
      else
        echo "Rollback failed (could not recreate $link)" >&2
        rollback_failures=$((rollback_failures + 1))
      fi
    done <<EOF
$UNDO_LIST
EOF
    ;;
  esac
  [ "$rollback_failures" -eq 0 ]
}

# Shared batch tail for the mutating commands: validate once, then either
# reload (on success) or roll back (on failure, if requested). Returns the
# status the caller should fold into its own rc.
finalize_batch() {
  changes=$1
  if run_config_test "$changes"; then
    run_reload "$changes" || return 1
    return 0
  fi
  if [ "$ROLLBACK" -eq 1 ] && [ "$changes" -gt 0 ]; then
    if do_rollback; then
      echo "Rolled back $changes change(s); config restored to its prior state" >&2
    else
      echo "Rollback incomplete; some of this run's changes could not be undone" >&2
    fi
  elif [ "$changes" -gt 0 ]; then
    echo "Changes left in place; fix the config or re-run with --rollback" >&2
  fi
  return 1
}

# A name must be a single path component: reject empty, '.', '..' and anything
# containing a slash so it cannot escape the managed directories. Also reject
# tab and newline, the undo log's field and record separators, so a name can
# never corrupt rollback (see do_rollback).
is_safe_name() {
  case $1 in
  "" | . | ..) return 1 ;;
  */* | *"$TAB"* | *"$NL"*) return 1 ;;
  *) return 0 ;;
  esac
}

# Resolve name for enabling:
#  - if NAME exists in AVAILABLE_DIR -> use it
#  - else if NAME.conf exists -> use NAME.conf
resolve_name_available() {
  base=$1
  if [ -e "$AVAILABLE_DIR/$base" ]; then
    echo "$base"
    return 0
  fi
  if [ -e "$AVAILABLE_DIR/$base.conf" ]; then
    echo "$base.conf"
    return 0
  fi
  return 1
}

# Resolve name for disabling:
#  - if NAME exists in ENABLED_DIR -> use it
#  - else if NAME.conf exists -> use NAME.conf
# Uses -L as well as -e so a dangling (broken) symlink is still resolvable.
resolve_name_enabled() {
  base=$1
  if [ -e "$ENABLED_DIR/$base" ] || [ -L "$ENABLED_DIR/$base" ]; then
    echo "$base"
    return 0
  fi
  if [ -e "$ENABLED_DIR/$base.conf" ] || [ -L "$ENABLED_DIR/$base.conf" ]; then
    echo "$base.conf"
    return 0
  fi
  return 1
}

do_enable() {
  ensure_dirs
  [ "$DRY_RUN" -eq 1 ] || require_writable_enabled
  [ $# -ge 1 ] || {
    echo "Nothing to enable" >&2
    exit 1
  }

  subdir=${AVAILABLE_DIR##*/}
  rc=0
  changed=0
  UNDO_KIND=created
  UNDO_LIST=""

  for base in "$@"; do
    if ! is_safe_name "$base"; then
      echo "Invalid name: '$base'" >&2
      rc=1
      continue
    fi

    if ! name=$(resolve_name_available "$base"); then
      echo "No such $KIND: '$base' (tried '$base' and '$base.conf' in $AVAILABLE_DIR)" >&2
      rc=1
      continue
    fi

    dst="$ENABLED_DIR/$name"

    # -L catches a dangling symlink that -e would miss; either way it is
    # already present, so report and skip rather than fail in ln.
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      echo "$KIND '$name' already enabled in $ENABLED_DIR" >&2
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] would enable $KIND: $name"
      # Count intended changes so a dry-run preview can also show the reload
      # step; the config test stays skipped (run_config_test guards DRY_RUN).
      changed=$((changed + 1))
      continue
    fi

    if ln -s "../$subdir/$name" "$dst"; then
      echo "Enabled $KIND: $name"
      changed=$((changed + 1))
      UNDO_LIST="$UNDO_LIST$dst$NL"
    else
      rc=1
    fi
  done

  # Validate once, after the whole batch, not per item (see run_config_test),
  # then reload or roll back as requested.
  finalize_batch "$changed" || rc=1

  [ $rc -eq 0 ] || exit $rc
}

do_disable() {
  ensure_dirs
  [ "$DRY_RUN" -eq 1 ] || require_writable_enabled
  [ $# -ge 1 ] || {
    echo "Nothing to disable" >&2
    exit 1
  }

  rc=0
  changed=0
  UNDO_KIND=removed
  UNDO_LIST=""
  for base in "$@"; do
    if ! is_safe_name "$base"; then
      echo "Invalid name: '$base'" >&2
      rc=1
      continue
    fi

    if ! name=$(resolve_name_enabled "$base"); then
      echo "$KIND '$base' is not enabled (tried '$base' and '$base.conf' in $ENABLED_DIR)" >&2
      rc=1
      continue
    fi

    dst="$ENABLED_DIR/$name"

    # This tool only manages symlinks; refuse to delete a real config file
    # that was placed in the enabled directory by other means.
    if [ ! -L "$dst" ]; then
      echo "$KIND '$name' is not a managed symlink, refusing to remove" >&2
      rc=1
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] would disable $KIND: $name"
      changed=$((changed + 1))
      continue
    fi

    # Capture the link target before removal so --rollback can recreate it.
    # An empty target (a race, or an odd filesystem) cannot be recreated, so
    # warn and omit it from the undo log rather than record a broken entry.
    link_target=$(readlink "$dst")
    if rm -f "$dst"; then
      echo "Disabled $KIND: $name"
      changed=$((changed + 1))
      if [ -n "$link_target" ]; then
        UNDO_LIST="$UNDO_LIST$dst$TAB$link_target$NL"
      else
        echo "$KIND '$name': empty link target, disable will not be undoable" >&2
      fi
    else
      rc=1
    fi
  done

  # Disabling can also break config (a module a config still needs); validate
  # once after the batch, same policy as enable, then reload/roll back.
  finalize_batch "$changed" || rc=1

  [ $rc -eq 0 ] || exit $rc
}

do_list_available() {
  ensure_dirs
  for f in "$AVAILABLE_DIR"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done
}

do_list_enabled() {
  ensure_dirs
  for f in "$ENABLED_DIR"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done
}

do_list() {
  ensure_dirs
  for f in "$AVAILABLE_DIR"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name=${f##*/}
    if [ -e "$ENABLED_DIR/$name" ] || [ -L "$ENABLED_DIR/$name" ]; then
      printf ' [on ] %s\n' "$name"
    else
      printf ' [off] %s\n' "$name"
    fi
  done

  # Second pass: enabled entries with no matching source in AVAILABLE_DIR.
  # These are active in Angie yet invisible in the first pass, so surface
  # them explicitly rather than letting them go unnoticed.
  for f in "$ENABLED_DIR"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name=${f##*/}
    if [ ! -e "$AVAILABLE_DIR/$name" ] && [ ! -L "$AVAILABLE_DIR/$name" ]; then
      printf ' [orphan] %s\n' "$name"
    fi
  done
}

# Report on/off per name. Exit status is 0 only when every queried name is
# enabled, so callers can gate on it: `angie-ctl mod status geoip && ...`.
do_status() {
  ensure_dirs
  [ $# -ge 1 ] || {
    echo "Nothing to query" >&2
    exit 1
  }

  rc=0
  for base in "$@"; do
    if ! is_safe_name "$base"; then
      echo "Invalid name: '$base'" >&2
      rc=1
      continue
    fi

    if name=$(resolve_name_enabled "$base"); then
      printf '[on ] %s\n' "$name"
    else
      # Fall back to the available name for nicer output when present.
      name=$(resolve_name_available "$base") || name=$base
      printf '[off] %s\n' "$name"
      rc=1
    fi
  done

  exit $rc
}

# Remove every orphaned enabled symlink (active in Angie but with no source in
# AVAILABLE_DIR, i.e. the [orphan] entries from `ls`). Only symlinks are
# touched, same guard as do_disable. Goes through the shared batch tail so it
# honors --dry-run/--no-test/--reload/--rollback like en/dis.
do_prune() {
  ensure_dirs
  [ "$DRY_RUN" -eq 1 ] || require_writable_enabled

  rc=0
  changed=0
  UNDO_KIND=removed
  UNDO_LIST=""
  for f in "$ENABLED_DIR"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name=${f##*/}

    # Skip entries that still have a source: those are managed, not orphaned.
    if [ -e "$AVAILABLE_DIR/$name" ] || [ -L "$AVAILABLE_DIR/$name" ]; then
      continue
    fi

    dst="$ENABLED_DIR/$name"
    if [ ! -L "$dst" ]; then
      echo "$KIND '$name' is orphaned but not a symlink, skipping" >&2
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "[dry-run] would prune $KIND: $name"
      changed=$((changed + 1))
      continue
    fi

    link_target=$(readlink "$dst")
    if rm -f "$dst"; then
      echo "Pruned $KIND: $name"
      changed=$((changed + 1))
      if [ -n "$link_target" ]; then
        UNDO_LIST="$UNDO_LIST$dst$TAB$link_target$NL"
      else
        echo "$KIND '$name': empty link target, prune will not be undoable" >&2
      fi
    else
      rc=1
    fi
  done

  finalize_batch "$changed" || rc=1

  [ $rc -eq 0 ] || exit $rc
}

case "$CMD" in
enable | en) do_enable "$@" ;;
disable | dis) do_disable "$@" ;;
status | stat) do_status "$@" ;;
prune)
  [ $# -eq 0 ] || {
    echo "prune takes no names (it removes all orphans)" >&2
    usage
  }
  do_prune
  ;;
list | ls) do_list ;;
"ls-available" | "list-available") do_list_available ;;
"ls-enabled" | "list-enabled") do_list_enabled ;;
*)
  echo "Unknown command: $CMD" >&2
  usage
  ;;
esac
