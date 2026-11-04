#!/usr/bin/env bash
# fm-heavy.sh - run one heavy command on this machine's shared test slot and
# record where its time went.
#
# usage: fm-heavy.sh --class test|build|e2e|image [--task <id>] [--project <name>] -- <command> [args...]
#
# The command runs exactly as workers ran it by hand before this wrapper:
#   flock -o /tmp/fm-heavy.lock systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 <command>
# The wrapper's exit status is the command's, so 137 still means the memory
# cap killed it. One heavy command at a time per slot, under the 6 GB cap with
# no swap, is the standing rule for this PC; the wrapper never raises either.
#
# Slots: config/host-test-slots in the root Firstmate home holds one positive
# integer, the number of heavy commands this machine admits at once. Absent
# means 1, which is the blocking single lock above. A larger number tries slot
# locks /tmp/fm-heavy.lock, /tmp/fm-heavy.lock.2, ... and retries every two
# seconds while all are held. A malformed file refuses the run instead of
# guessing. This is the host limit only: coding agents per project are
# config/project-capacity, and workers inside one test run are each project's
# own runner flag (docs/configuration.md "Heavy commands and concurrency").
#
# Record: when the command finishes, one JSON line is appended to
# state/heavy-jobs.jsonl in the root Firstmate home (shared by every local home,
# like the lock). Fields: task, project, class, cmd (the command's first word),
# requested_at, started_at, ended_at (epoch seconds), wait_s (requested to
# started, the time spent waiting for the slot), run_s, exit, slot, and
# peak_memory_bytes and cpu_usec read from the job's own systemd scope
# (cgroup memory.peak and cpu.stat usage_usec). Any value that is not available
# is null, never an estimate; --task and --project are null when not given.
#
# bin/fm-heavy-summary.sh summarizes the log. Linux with flock and systemd-run
# only; elsewhere the wrapper exits 69 without running anything.
#
# Environment: FM_HOME selects the home (the root home is used for the log and
# config); FM_HEAVY_LOCK overrides the slot lock path for tests.
#
# Exit status: the command's, or 2 on a usage or configuration error, or 69
# when flock or systemd-run is missing.
set -u
export LC_ALL=C

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
MEMORY_MAX=6G

# Innermost stage: runs inside the systemd scope, so /proc/self/cgroup names the
# scope. Counters are trusted only when that cgroup is the scope created for this
# job; the file is read after the command ends and before the scope is removed.
if [ "${1:-}" = --stage-scoped ]; then
  shift
  "$@"
  rc=$?
  cg=$(sed -n 's/^0:://p' /proc/self/cgroup 2>/dev/null)
  peak=; cpu=
  case "$cg" in
    */"$_FMH_UNIT".scope)
      peak=$(cat "/sys/fs/cgroup$cg/memory.peak" 2>/dev/null)
      cpu=$(awk '$1 == "usage_usec" { print $2 }' "/sys/fs/cgroup$cg/cpu.stat" 2>/dev/null)
      ;;
  esac
  printf 'peak=%s\ncpu=%s\n' "$peak" "$cpu" > "$_FMH_SAMPLE"
  exit "$rc"
fi

# Middle stage: holds the slot lock. Its first act is the start marker, which
# is also how the outer loop tells "command ran" from "slot was busy".
if [ "${1:-}" = --stage-locked ]; then
  shift 2
  started=$(date +%s)
  printf '%s\n' "$started" > "$_FMH_STARTED"
  systemd-run --user --scope -q -p "MemoryMax=$MEMORY_MAX" -p MemorySwapMax=0 \
    --unit="$_FMH_UNIT" "$SELF" --stage-scoped "$@"
  rc=$?
  ended=$(date +%s)
  peak=$(sed -n 's/^peak=//p' "$_FMH_SAMPLE" 2>/dev/null)
  cpu=$(sed -n 's/^cpu=//p' "$_FMH_SAMPLE" 2>/dev/null)
  # shellcheck disable=SC2153 # _FMH_SLOT is set in the environment by the outer loop
  jq -nc --arg task "$_FMH_TASK" --arg project "$_FMH_PROJECT" --arg class "$_FMH_CLASS" \
    --arg cmd "$(basename -- "$1")" --arg req "$_FMH_REQUESTED" --arg start "$started" \
    --arg end "$ended" --arg rc "$rc" --arg slot "$_FMH_SLOT" --arg peak "$peak" --arg cpu "$cpu" '
    def num: if test("^[0-9]+$") then tonumber else null end;
    def str: if . == "" then null else . end;
    {task: ($task | str), project: ($project | str), class: $class, cmd: $cmd,
     requested_at: ($req | num), started_at: ($start | num), ended_at: ($end | num),
     wait_s: (($start | num) - ($req | num)), run_s: (($end | num) - ($start | num)),
     exit: ($rc | num), slot: ($slot | num),
     peak_memory_bytes: ($peak | num), cpu_usec: ($cpu | num)}' >> "$_FMH_LOG"
  exit "$rc"
fi

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

_FMH_CLASS=; _FMH_TASK=; _FMH_PROJECT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --class) _FMH_CLASS=${2:-}; shift 2 || break ;;
    --task) _FMH_TASK=${2:-}; shift 2 || break ;;
    --project) _FMH_PROJECT=${2:-}; shift 2 || break ;;
    --) shift; break ;;
    *) break ;;
  esac
done
case "$_FMH_CLASS" in test|build|e2e|image) ;; *)
  echo "fm-heavy.sh: --class must be test, build, e2e or image" >&2; exit 2 ;;
esac
[ "$#" -gt 0 ] || { echo "fm-heavy.sh: no command after --" >&2; exit 2; }
for tool in flock systemd-run jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "fm-heavy.sh: $tool is required" >&2; exit 69; }
done

# shellcheck source=bin/fm-wake-lib.sh
root=$(. "$(dirname "$SELF")/fm-wake-lib.sh" && fm_firstmate_root_home) || {
  echo "fm-heavy.sh: cannot resolve the root Firstmate home" >&2; exit 2; }
slots=1
if [ -e "$root/config/host-test-slots" ]; then
  slots=$(tr -d '[:space:]' < "$root/config/host-test-slots")
  case "$slots" in ''|*[!0-9]*|0|?????*)
    echo "fm-heavy.sh: config/host-test-slots must hold one positive integer" >&2; exit 2 ;; esac
fi

lock=${FM_HEAVY_LOCK:-/tmp/fm-heavy.lock}
_FMH_REQUESTED=$(date +%s)
_FMH_STARTED=$(mktemp) _FMH_SAMPLE=$(mktemp)
trap 'rm -f "$_FMH_STARTED" "$_FMH_SAMPLE"' EXIT
_FMH_UNIT="fm-heavy-$$-$_FMH_REQUESTED"
_FMH_LOG="$root/state/heavy-jobs.jsonl"
export _FMH_REQUESTED _FMH_STARTED _FMH_SAMPLE _FMH_UNIT _FMH_LOG _FMH_TASK _FMH_PROJECT _FMH_CLASS
mkdir -p "$root/state"

# -o: the lock descriptor is closed in the command, so a process it leaves
# running (a daemon it auto-starts) cannot keep the slot held after it exits.
nb=(); [ "$slots" -gt 1 ] && nb=(-n -E 99)
while :; do
  i=1
  while [ "$i" -le "$slots" ]; do
    slot_lock=$lock; [ "$i" -gt 1 ] && slot_lock=$lock.$i
    : > "$_FMH_STARTED"
    _FMH_SLOT=$i flock ${nb[@]+"${nb[@]}"} -o "$slot_lock" "$SELF" --stage-locked -- "$@"
    rc=$?
    if [ "$rc" -ne 99 ] || [ -s "$_FMH_STARTED" ]; then exit "$rc"; fi
    i=$((i + 1))
  done
  sleep 2
done
