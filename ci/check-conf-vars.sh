#!/bin/sh
# Require the $_stock_ prefix on every variable the shipped angie config
# declares (map, geo, split_clients, geoip2, time_format, set,
# auth_request_set).
#
# Usage: sh ci/check-conf-vars.sh [file...]
#   Without arguments checks the shipped tree; run from the repository root.
#
# The prefix exists because a name collision here is silent: custom/http-conf.d
# is included after the image tree, the last declaration wins and `angie -t`
# succeeds. A consumer who takes a name from a stock recipe in the docs breaks
# an image feature without a single log line.
#
# time_format is held to the prefix too, although a duplicate there is fatal: an
# exemption list of one name would outlive the memory of why it is there.
#
# Out of scope:
#   - the consumer tree and the suite fixtures: names there are the consumer's;
#   - uses. A renamed declaration with a stale use is caught by angie itself
#     (`unknown "name" variable` is an emerg at startup, and the entrypoint runs
#     `angie -t` on every start);
#   - log format names: their own namespace, with their own angie_ prefix;
#   - a declaration that is not the first token of its line. The parser compares
#     the first token, so a one-line `if ($arg_x) { set $leak 1; }` passes. The
#     shipped tree has none; set inside if is written on its own line.
set -eu

if [ "$#" -gt 0 ]; then
  files=$*
else
  # find, not a glob: a file in a new subdirectory would otherwise drop out of
  # the check silently. -type f skips the active http-conf.d symlinks into
  # -available.d, which would report every declaration there twice. Templates
  # are included on purpose: $_stock_geoip2_country_code lives in a .template.
  files=$(find rootfs rootfs-unprivileged -path '*/etc/angie/*' -type f \
    \( -name '*.conf' -o -name '*.conf.template' \) 2>/dev/null | LC_ALL=C sort) || true
fi

# An empty list is a check that did not run, not "no violations".
test -n "$files" || {
  echo "conf-vars: empty file list, run from the repository root" >&2
  exit 2
}

rc=0
# The number of parsed declarations is printed next to the violations and
# asserted by the suite: a parser that stopped matching the tree (a moved
# directory, new syntax) finds nothing and looks exactly like a green run.
# shellcheck disable=SC2086 # the list is split into words on purpose
out=$(LC_ALL=C awk '
  function seen(name) { total++; if (name !~ /^\$_stock_/) bad(name) }
  function bad(name) { printf "BAD %s:%d: %s\n", FILENAME, FNR, name }
  # A declaration header broken across lines cannot be parsed. Skipping it is
  # not an option: a skip looks exactly like a clean file.
  function unparsed() {
    printf "%s:%d: declaration not parsed, put it on one line\n", \
      FILENAME, FNR > "/dev/stderr"
    halt = 1
  }
  FNR == 1 { in_geoip2 = 0 }
  /^[[:space:]]*#/ { next }
  # geoip2 body: every line declares a variable with its first token. The flag
  # keeps a log_format continuation that starts with a dollar from passing for
  # a declaration.
  $1 == "geoip2" { in_geoip2 = 1; next }
  in_geoip2 && $1 == "}" { in_geoip2 = 0; next }
  in_geoip2 && $1 ~ /^\$/ { seen($1); next }
  # map, geo, split_clients: the target is the last variable before the brace.
  # One rule covers `geo $x {` and `geo $remote_addr $x {`. Compared as a
  # token, not a line prefix, or map_hash_bucket_size would pass for a
  # declaration.
  $1 == "map" || $1 == "geo" || $1 == "split_clients" {
    # index, not /{/: a bare brace in an ERE is undefined, and busybox awk
    # rejects it (bad regex).
    if (index($0, "{") == 0) { unparsed(); next }
    target = ""
    for (i = 2; i <= NF; i++) {
      if ($i == "{") break
      if ($i ~ /^\$/) target = $i
    }
    if (target != "") seen(target)
    next
  }
  # time_format and the set family: the target is the second token.
  $1 == "time_format" || $1 == "set" || $1 == "auth_request_set" {
    if ($0 !~ /;/) { unparsed(); next }
    seen($2)
    next
  }
  END {
    if (halt) exit 2
    printf "TOTAL %d\n", total
  }
' $files) || rc=$?

# Any non-zero awk status is a check that did not run, not only the declared 2:
# an awk that rejects the program itself exits with its own code and no TOTAL
# line, and such a run finds no violations.
total=$(printf '%s\n' "$out" | sed -n 's/^TOTAL //p')
test "$rc" -eq 0 && test -n "$total" || {
  echo "conf-vars: check did not run (awk exited with status $rc)" >&2
  exit 2
}

hits=$(printf '%s\n' "$out" | sed -n 's/^BAD //p')

if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  echo "conf-vars: the variables above are declared without the \$_stock_ prefix" >&2
  exit 1
fi

echo "conf-vars: $total declarations, all prefixed with \$_stock_"
