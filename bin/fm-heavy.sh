#!/usr/bin/env bash
# fm-heavy.sh - run one heavy command on this machine's shared test slot and
# record where its time went.
#
# usage: fm-heavy.sh --class test|build|e2e|image [--task <id>] [--project <name>] -- <command> [args...]
#
# The command runs exactly as workers ran it by hand before this wrapper:
#   flock -o /tmp/fm-heavy.lock systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 <command>
# The wrapper's exit status is the command's. 137 means the memory cap killed
# the command itself; when the cap kills one of its child processes, systemd
# stops the whole scope, so the status is usually 143 instead. One heavy command
# at a time per slot, under the 6 GB cap with no swap, is the standing rule for
# this PC; the wrapper never raises either.
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
# Record: each job appends one JSON line to state/heavy-jobs.jsonl in the root
# Firstmate home (shared by every local home, like the lock). Fields: task,
# project, class, cmd (the command's first word), requested_at, started_at,
# ended_at (epoch seconds), wait_s (requested to started, the time spent waiting
# for the slot), run_s, exit, slot, and peak_memory_bytes and cpu_usec read from
# the job's own systemd scope (cgroup memory.peak and cpu.stat usage_usec). Any
# value that is not available is null, never an estimate; --task and --project
# are null when not given.
#
# Killed jobs: TERM, INT or HUP still leaves a record; SIGKILL cannot. A running
# job is recorded once its scope ends, with exit 128+n. The command stops only if
# the signal reaches it too, as a process-group signal does; one sent to the
# wrapper alone takes effect when the command ends. A job signalled while queued
# never runs: wait_s is its wait so far, and started_at, ended_at, run_s, exit
# and slot are null.
#
# bin/fm-heavy-summary.sh summarizes the log. Linux with flock and systemd-run
# only; elsewhere the wrapper exits 69 without running anything.
#
# Environment: FM_HOME selects the home (the root home is used for the log and
# config); FM_HEAVY_LOCK overrides the slot lock path for tests.
#
# Exit status: the command's, 128+n when the wrapper was signalled, 2 on a usage
# or configuration error, or 69 when flock, systemd-run or jq is missing.
set -u

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
MEMORY_MAX=6G

# Scope stage: runs inside the systemd scope, so /proc/self/cgroup names the
# scope. Counters are trusted only when that cgroup is the scope created for this
# job; the file is read after the command ends and before the scope is removed.
# A stop signal for the whole scope must not end this stage before that read, and
# the command does not inherit these handlers.
if [ "${1:-}" = --stage-scoped ]; then
  unit=$2 sample=$3
  shift 3
  trap : HUP INT TERM
  "$@"
  rc=$?
  cg=$(sed -n 's/^0:://p' /proc/self/cgroup 2>/dev/null)
  peak=; cpu=
  case "$cg" in
    */"$unit".scope)
      peak=$(cat "/sys/fs/cgroup$cg/memory.peak" 2>/dev/null)
      cpu=$(awk '$1 == "usage_usec" { print $2 }' "/sys/fs/cgroup$cg/cpu.stat" 2>/dev/null)
      ;;
  esac
  printf 'peak=%s\ncpu=%s\n' "$peak" "$cpu" > "$sample"
  exit "$rc"
fi

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

class=; task=; project=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --class) class=${2:-}; shift 2 || break ;;
    --task) task=${2:-}; shift 2 || break ;;
    --project) project=${2:-}; shift 2 || break ;;
    --) shift; break ;;
    *) break ;;
  esac
done
case "$class" in test|build|e2e|image) ;; *)
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
  read -r -d '' -a tokens < "$root/config/host-test-slots"
  slots=${tokens[*]:-}
  case "$slots" in ''|*[!0-9]*|0*|?????*)
    echo "fm-heavy.sh: config/host-test-slots must hold one positive integer" >&2; exit 2 ;; esac
fi

lock=${FM_HEAVY_LOCK:-/tmp/fm-heavy.lock}
log="$root/state/heavy-jobs.jsonl"
cmd=$(basename -- "$1")
requested=$(date +%s)
unit="fm-heavy-$$-$requested"
sample=$(mktemp)
trap 'rm -f "$sample"' EXIT
mkdir -p "$root/state"
slot=; started=; signal=; waiter=

record() {  # <exit status, empty when the command never started>
  local now peak cpu ended='' run_s='' wait_s
  now=$(date +%s)
  wait_s=$((${started:-$now} - requested))
  if [ -n "$started" ]; then
    ended=$now
    run_s=$((now - started))
  fi
  peak=$(sed -n 's/^peak=//p' "$sample" 2>/dev/null)
  cpu=$(sed -n 's/^cpu=//p' "$sample" 2>/dev/null)
  jq -nc --arg task "$task" --arg project "$project" --arg class "$class" --arg cmd "$cmd" \
    --arg req "$requested" --arg start "$started" --arg end "$ended" --arg wait "$wait_s" \
    --arg run "$run_s" --arg rc "$1" --arg slot "${started:+$slot}" --arg peak "$peak" --arg cpu "$cpu" '
    def num: if test("^[0-9]+$") then tonumber else null end;
    def str: if . == "" then null else . end;
    {task: ($task | str), project: ($project | str), class: $class, cmd: $cmd,
     requested_at: ($req | num), started_at: ($start | num), ended_at: ($end | num),
     wait_s: ($wait | num), run_s: ($run | num), exit: ($rc | num), slot: ($slot | num),
     peak_memory_bytes: ($peak | num), cpu_usec: ($cpu | num)}' >> "$log"
}

# A foreground command would hold a trap back until it returned, so the steps of
# the queue run in the background and this shell waits on them.
interruptible() {
  local rc
  "$@" &
  waiter=$!
  wait "$waiter"
  rc=$?
  waiter=
  return "$rc"
}

# While the command runs, bash holds this handler until the scope ends, and the
# main flow below records the job.
on_signal() {  # <signal number>
  signal=$1
  [ -z "$started" ] || return
  trap '' HUP INT TERM
  [ -z "$waiter" ] || kill "$waiter" 2>/dev/null
  record ""
  exit $((128 + signal))
}
trap 'on_signal 1' HUP
trap 'on_signal 2' INT
trap 'on_signal 15' TERM

# This shell holds the lock on descriptor 9 for the life of the job.
nb=(); [ "$slots" -gt 1 ] && nb=(-n)
while [ -z "$slot" ]; do
  i=1
  while [ -z "$slot" ] && [ "$i" -le "$slots" ]; do
    slot_lock=$lock; [ "$i" -gt 1 ] && slot_lock=$lock.$i
    exec 9>>"$slot_lock" || { echo "fm-heavy.sh: cannot open $slot_lock" >&2; exit 2; }
    interruptible flock ${nb[@]+"${nb[@]}"} 9 && slot=$i
    i=$((i + 1))
  done
  [ -n "$slot" ] || interruptible sleep 2
done

# The command stays in the foreground so it keeps stdin and default signal
# handling. 9>&-: the lock descriptor is closed in the command, so a process it
# leaves running (a daemon it auto-starts) cannot keep the slot held after it exits.
started=$(date +%s)
systemd-run --user --scope -q -p "MemoryMax=$MEMORY_MAX" -p MemorySwapMax=0 \
  --unit="$unit" "$SELF" --stage-scoped "$unit" "$sample" "$@" 9>&-
rc=$?
[ -z "$signal" ] || rc=$((128 + signal))
record "$rc"
exit "$rc"
