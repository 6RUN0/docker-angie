#!/bin/sh -eu

. /docker-entrypoint-common.sh

export LC_ALL=C
ME=$(basename "$0")
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ceildiv() {
  num=$1
  div=$2
  echo $(((num + div - 1) / div))
}

get_cpuset() {
  cpusetroot=$1
  cpusetfile=$2
  ncpu=0
  [ -f "$cpusetroot/$cpusetfile" ] || return 1
  for token in $(tr ',' ' ' <"$cpusetroot/$cpusetfile"); do
    case "$token" in
    *-*)
      # Inclusive range "start-end"; count with arithmetic, without spawning
      # seq or relying on word splitting.
      ncpu=$((ncpu + ${token#*-} - ${token%-*} + 1))
      ;;
    *)
      ncpu=$((ncpu + 1))
      ;;
    esac
  done
  # Same guard as get_quota and get_quota_v2: the minimum of the candidates is
  # taken below, so a non-positive value would win and yield
  # `worker_processes 0;`, which `angie -t` accepts and the master runs with no
  # workers at all. Hardening against input the kernel does not produce.
  [ "$ncpu" -gt 0 ] || return 1
  echo "$ncpu"
}

get_quota() {
  cpuroot=$1
  ncpu=0
  [ -f "$cpuroot/cpu.cfs_quota_us" ] || return 1
  [ -f "$cpuroot/cpu.cfs_period_us" ] || return 1
  cfs_quota=$(cat "$cpuroot/cpu.cfs_quota_us")
  cfs_period=$(cat "$cpuroot/cpu.cfs_period_us")
  [ "$cfs_quota" = "-1" ] && return 1
  [ "$cfs_period" = "0" ] && return 1
  ncpu=$(ceildiv "$cfs_quota" "$cfs_period")
  [ "$ncpu" -gt 0 ] || return 1
  echo "$ncpu"
}

get_quota_v2() {
  cpuroot=$1
  ncpu=0
  [ -f "$cpuroot/cpu.max" ] || return 1
  cfs_quota=$(cut -d' ' -f 1 <"$cpuroot/cpu.max")
  cfs_period=$(cut -d' ' -f 2 <"$cpuroot/cpu.max")
  [ "$cfs_quota" = "max" ] && return 1
  [ "$cfs_period" = "0" ] && return 1
  ncpu=$(ceildiv "$cfs_quota" "$cfs_period")
  [ "$ncpu" -gt 0 ] || return 1
  echo "$ncpu"
}

# cgroup parsing reads two /proc files, both passed as parameters so the test
# suite can run these functions on fixtures: a v1 hierarchy cannot be
# reproduced on a v2 host, and /proc/self cannot be replaced in a container.
#
# A mountinfo line: `id parent maj:min root mountpoint options ... - type
# source superoptions`. v1 controllers are comma-separated in the superoptions
# (`rw,cpu,cpuacct`) and are matched there, not as a substring of the whole
# line: a named hierarchy's mountpoint (`name=systemd`) may contain anything.
# Splitting on spaces is safe, the kernel prints a space in a path as \040.
#
# Prints `root mountpoint` of the v1 hierarchy carrying controller $1.
find_cgroup_v1_mount() { # controller mountinfo
  [ -r "$2" ] || return 1
  while read -r _ _ _ root mountpoint rest; do
    case " $rest " in
    *' - cgroup '*) ;;
    *) continue ;;
    esac
    case ",${rest##* }," in
    *",$1,"*)
      echo "$root $mountpoint"
      return 0
      ;;
    esac
  done <"$2"
  return 1
}

# Prints the task path in the v1 hierarchy with controller $1, an empty line
# without such a hierarchy. A /proc/self/cgroup line: `id:controllers:path`.
find_cgroup_v1_path() { # controller cgroupfile
  [ -r "$2" ] || return 1
  while IFS=: read -r _ controllers path; do
    case ",$controllers," in
    *",$1,"*)
      echo "$path"
      return 0
      ;;
    esac
  done <"$2"
  echo
}

# Prints `root mountpoint` of the unified v2 hierarchy, the last one found; the
# task path in it is the last `0::path` line.
find_cgroup_v2_mount() { # mountinfo
  [ -r "$1" ] || return 1
  found=
  while read -r _ _ _ root mountpoint rest; do
    case " $rest " in
    *' - cgroup2 '*) found="$root $mountpoint" ;;
    esac
  done <"$1"
  [ -n "$found" ] || return 1
  echo "$found"
}

find_cgroup_v2_path() { # cgroupfile
  [ -r "$1" ] || return 1
  path=
  while IFS=: read -r id _ rest; do
    [ "$id" = 0 ] && path=$rest
  done <"$1"
  echo "$path"
}

get_cgroup_v1_path() { # controller mountinfo cgroupfile
  mount=$(find_cgroup_v1_mount "$1" "$2") || return 1
  path=$(find_cgroup_v1_path "$1" "$3") || return 1
  resolve_cgroup_dir "${mount%% *}" "${mount##* }" "$path"
}

get_cgroup_v2_path() { # mountinfo cgroupfile
  mount=$(find_cgroup_v2_mount "$1") || return 1
  path=$(find_cgroup_v2_path "$2") || return 1
  resolve_cgroup_dir "${mount%% *}" "${mount##* }" "$path"
}

# The task's cgroup directory on the filesystem: hierarchy root `/` means the
# task path lies under the mountpoint; a root equal to the task path means the
# container got its own cgroup mounted. For v2 a `/../..` root is printed for
# a cgroup namespace and also means the mountpoint. An empty task path (no
# cgroup file) with root `/` gives the mountpoint itself.
resolve_cgroup_dir() { # root mountpoint path
  case "$1" in
  /) echo "$2$3" ;;
  "$3" | /../*) echo "$2" ;;
  *) return 1 ;;
  esac
}

tune_worker_processes() {
  [ "${ANGIE_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE:-}" ] || return 0

  mountinfo=/proc/self/mountinfo
  cgroupfile=/proc/self/cgroup
  ncpu_online=$(getconf _NPROCESSORS_ONLN)

  cpuset=$(get_cgroup_v1_path cpuset "$mountinfo" "$cgroupfile") &&
    ncpu_cpuset=$(get_cpuset "$cpuset" cpuset.effective_cpus) ||
    ncpu_cpuset=$ncpu_online
  cpu=$(get_cgroup_v1_path cpu "$mountinfo" "$cgroupfile") &&
    ncpu_quota=$(get_quota "$cpu") ||
    ncpu_quota=$ncpu_online
  if cgroup_v2=$(get_cgroup_v2_path "$mountinfo" "$cgroupfile"); then
    ncpu_cpuset_v2=$(get_cpuset "$cgroup_v2" cpuset.cpus.effective) || ncpu_cpuset_v2=$ncpu_online
    ncpu_quota_v2=$(get_quota_v2 "$cgroup_v2") || ncpu_quota_v2=$ncpu_online
  else
    ncpu_cpuset_v2=$ncpu_online
    ncpu_quota_v2=$ncpu_online
  fi

  ncpu=$(printf "%s\n%s\n%s\n%s\n%s\n" \
    "$ncpu_online" \
    "$ncpu_cpuset" \
    "$ncpu_quota" \
    "$ncpu_cpuset_v2" \
    "$ncpu_quota_v2" |
    sort -n |
    head -n 1)

  # Edit the live tree: it is copied afresh on every start, so the substitution
  # always meets the shipped `worker_processes auto;` and never stacks on its
  # own earlier result. The old line stays commented out next to it, showing in
  # /data/conf/angie.conf that the toggle set the value.
  sed -i -r 's/^(worker_processes)(.*)$/# Commented out by '"$ME"' on '"$(date)"'\n#\1\2\n\1 '"$ncpu"';/' "$ANGIE_CONF_DIR/angie.conf"
}

# The toggle runs only when the file itself is executed. Sourced (`. file`) it
# just declares the functions, so the suite can test cgroup parsing on fixtures
# without touching angie.conf.
case "${0##*/}" in
30-tune-worker-processes.sh) tune_worker_processes ;;
esac
