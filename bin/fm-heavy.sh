#!/usr/bin/env bash
# fm-heavy.sh - run one heavy command on this machine's shared test slot and
# record where its time went.
#
# usage: fm-heavy.sh --class test|build|e2e|image [--task <id>] [--project <name>] [--remote] -- <command> [args...]
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
# Remote destination (opt-in): config/heavy-remote approves test and e2e commands
# on one SSH host, which takes one job at a time; build and image always stay
# local, since only the result and log come back. Lines (comments start #):
#   host <ssh alias>                    required, one host
#   command <project> -- <words...>     approval for one project (repeatable)
#   timeout <seconds>                   optional positive integer, default 900
#   offload                             optional presence line
# Command words must match argv exactly (whitespace separates words; no shell
# quoting or expansion). A malformed or unreadable config, including duplicate
# approvals, refuses a job that would offload (--remote, or an approved command
# with offload); every other job warns once and runs locally.
# --remote requires an approval and requests remote first. With offload, an
# approved command automatically tries the host when all local slots are busy;
# otherwise it runs locally. Without offload or --remote the local behavior is
# unchanged. An approved job the host cannot take yet because it is busy,
# unreachable or still running an unknown job waits for a local slot while it
# keeps checking: the remote slot every two seconds, the host itself every
# FM_HEAVY_REMOTE_RECHECK seconds, and it moves to whichever frees first. Any other
# reason, such as an unclean repository root, joins the normal local queue. The
# last reason is recorded in fallback when the job runs locally. Missing runtimes,
# incompatible versions and dependency-install errors on the host fail the remote
# job and never silently retry locally. A signal before starting prevents
# execution anywhere. bin/fm-heavy-remote.sh owns transfer, results and
# unknown-job reconciliation; unknown jobs prevent new remote work until settled.
# Job copies live in state/heavy-remote/<job> in the root home, and open records
# in state/heavy-remote/unknown-<host>.
#
# A remote job's record has the same fields plus: host (the alias, "local" for a
# local run), prepare_s (bundle, transfer and checkout until the job started) and
# collect_s (fetching and checking the result; both null for a local run),
# outcome (pass, failed, timeout, rejected, lost, unknown or cancelled; null for
# a local run), job (the remote job id), candidate (the commit run), and
# fallback (why an approved remote job ran locally). wait_s is the time before
# preparation began; started_at is when the job started on the host and ended_at
# when its completion was seen, both read on this machine's clock; peak_memory_bytes
# is null because no whole-job peak is read remotely, cpu_usec comes from the
# host. Queue wait, preparation, run and collection add up to the job's elapsed
# time, so local and remote runs compare end to end.
#
# Test output: a class test or e2e job, other than a no-mistakes drive call, also
# keeps its combined stdout and stderr in state/heavy-logs/<job>.log in the root
# home, where <job> is the fm-heavy-<pid>-<epoch> unit name. A log holds the last
# 2 MiB, with a marker line when earlier output was dropped; the newest 200 logs
# are kept. Each stream still reaches its own destination, through a pipe rather
# than the caller's descriptor, so a command that checks for a terminal sees none.
# After a non-zero exit the job's failing tests go to the ledger that
# bin/fm-test-failure.sh owns. The ledger step never changes the exit status; a
# process that outlives the command with the output open leaves the log unwritten
# until it exits, and that job's ledger line is "(unparsed)".
#
# bin/fm-heavy-summary.sh summarizes the log. Linux with flock, systemd-run and
# jq only; elsewhere the wrapper exits 69 without running anything.
#
# Environment: FM_HOME selects the home (the root home is used for the log and
# config); FM_HEAVY_LOCK overrides the slot lock path for tests;
# FM_HEAVY_REMOTE_RECHECK is the seconds between host checks for a queued job (30).
#
# Exit status: the command's, 128+n when the wrapper was signalled, 2 on a usage
# or configuration error, or 69 when flock, systemd-run or jq is missing. A remote
# job that did not pass exits with its outcome's status from bin/fm-heavy-remote.sh.
set -u

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REMOTE="$(dirname "$SELF")/fm-heavy-remote.sh"
LEDGER="$(dirname "$SELF")/fm-test-failure.sh"
MEMORY_MAX=6G
LOG_MAX_BYTES=2097152
LOGS_KEPT=200

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

class=; task=; project=; remote=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --class) class=${2:-}; shift 2 || break ;;
    --task) task=${2:-}; shift 2 || break ;;
    --project) project=${2:-}; shift 2 || break ;;
    --remote) remote=1; shift ;;
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

# shellcheck source=/dev/null # Isolated in this subshell; linted as its own root.
root=$(. "$(dirname "$SELF")/fm-wake-lib.sh" && fm_firstmate_root_home) || {
  echo "fm-heavy.sh: cannot resolve the root Firstmate home" >&2; exit 2; }
slots=1
if [ -e "$root/config/host-test-slots" ]; then
  read -r -d '' -a tokens < "$root/config/host-test-slots"
  slots=${tokens[*]:-}
  case "$slots" in ''|*[!0-9]*|0*|?????*)
    echo "fm-heavy.sh: config/host-test-slots must hold one positive integer" >&2; exit 2 ;; esac
fi

rhost=; rtimeout=; offload=; approved=; rconf=$root/config/heavy-remote; rproblem=
if [ -n "$remote" ] && [ ! -e "$rconf" ]; then
  echo "fm-heavy.sh: --remote needs $rconf" >&2; exit 2
elif [ -e "$rconf" ] && [ ! -r "$rconf" ]; then
  rproblem="cannot read $rconf"
elif [ -e "$rconf" ]; then
  bad=; approvals=(); request=("$@"); n=0
  while read -r key rest || [ -n "$key" ]; do
    n=$((n + 1))
    case "$key" in
      ''|'#'*) ;;
      host) [ -z "$rhost" ] && [[ $rest =~ ^[A-Za-z0-9._-]+$ ]] && rhost=$rest || bad=${bad:-$n} ;;
      command)
        words=(); read -r -a words <<< "$rest"
        scope=${words[0]:-}
        [[ $scope =~ ^[A-Za-z0-9._-]+$ ]] && [ "${words[1]:-}" = -- ] && [ "${#words[@]}" -gt 2 ] || bad=${bad:-$n}
        signature="$scope:"
        match=1
        [ "$scope" = "$project" ] || match=
        [ "$((${#words[@]} - 2))" -eq "${#request[@]}" ] || match=
        for ((j=2; j<${#words[@]}; j++)); do
          signature+=" ${words[j]}"
          [ "${words[j]}" = "${request[j-2]:-}" ] || match=
        done
        for prior in ${approvals[@]+"${approvals[@]}"}; do [ "$prior" != "$signature" ] || bad=${bad:-$n}; done
        approvals+=("$signature")
        [ -z "$match" ] || approved=1
        ;;
      timeout) [ -z "$rtimeout" ] && [[ $rest =~ ^[1-9][0-9]{0,5}$ ]] && rtimeout=$rest || bad=${bad:-$n} ;;
      offload) [ -z "$offload" ] && [ -z "$rest" ] && offload=1 || bad=${bad:-$n} ;;
      *) bad=${bad:-$n} ;;
    esac
  done < "$rconf"
  if [ -n "$bad" ]; then rproblem="malformed $rconf: invalid line $bad (see --help)"
  elif [ -z "$rhost" ]; then rproblem="malformed $rconf: no host line (see --help)"
  elif [ "${#approvals[@]}" -eq 0 ]; then rproblem="malformed $rconf: no command line (see --help)"
  fi
  case "$class" in build|image) approved= ;; esac
fi
if [ -n "$rproblem" ]; then
  if [ -n "$remote" ] || { [ -n "$offload" ] && [ -n "$approved" ]; }; then
    echo "fm-heavy.sh: $rproblem" >&2; exit 2
  fi
  echo "fm-heavy.sh: warning: $rproblem; running locally" >&2
  offload=; approved=
elif [ -e "$rconf" ]; then
  if [ -n "$remote" ] && [ -z "$approved" ]; then
    echo "fm-heavy.sh: --remote command/class is not approved for this project" >&2; exit 2
  fi
  rtimeout=${rtimeout:-900}
fi

lock=${FM_HEAVY_LOCK:-/tmp/fm-heavy.lock}
log="$root/state/heavy-jobs.jsonl"
cmd=$(basename -- "$1")
requested=$(date +%s)
unit="fm-heavy-$$-$requested"
sample=$(mktemp)
trap 'rm -f "$sample"' EXIT
mkdir -p "$root/state"
slot=; started=; signal=; waiter=; host=; fallback=
sget() { sed -n "s/^$1=//p" "$sample" 2>/dev/null | tail -1; }
command_line=$*
logs="$root/state/heavy-logs"
joblog=
case "$class:$cmd" in
  test:no-mistakes) ;;  # a pipeline drive call, not a test run
  test:*|e2e:*) mkdir -p "$logs" && joblog="$logs/$unit.log" ;;
esac

record() {  # <exit status, empty when the command never started>
  local now peak cpu ended='' run_s='' wait_s began
  now=$(date +%s)
  if [ -n "$host" ]; then  # a remote job: the stage times come from its driver
    started=$(sget started)
    ended=$(sget ended)
    began=$(sget wait_until)
    wait_s=$((${began:-$now} - requested))
    [ -z "$started" ] || [ -z "$ended" ] || run_s=$((ended - started))
  else
    wait_s=$((${started:-$now} - requested))
    if [ -n "$started" ]; then
      ended=$now
      run_s=$((now - started))
    fi
  fi
  peak=$(sget peak)
  cpu=$(sget cpu)
  jq -nc --arg task "$task" --arg project "$project" --arg class "$class" --arg cmd "$cmd" \
    --arg req "$requested" --arg start "$started" --arg end "$ended" --arg wait "$wait_s" \
    --arg run "$run_s" --arg rc "$1" --arg slot "${started:+$slot}" --arg peak "$peak" --arg cpu "$cpu" \
    --arg host "${host:-local}" --arg prep "$(sget prepare_s)" --arg coll "$(sget collect_s)" \
    --arg outcome "$(sget outcome)" --arg job "$(sget job)" --arg cand "$(sget candidate)" \
    --arg fallback "$fallback" '
    def num: if test("^[0-9]+$") then tonumber else null end;
    def str: if . == "" then null else . end;
    {task: ($task | str), project: ($project | str), class: $class, cmd: $cmd,
     requested_at: ($req | num), started_at: ($start | num), ended_at: ($end | num),
     wait_s: ($wait | num), run_s: ($run | num), exit: ($rc | num), slot: ($slot | num),
     peak_memory_bytes: ($peak | num), cpu_usec: ($cpu | num),
     host: $host, prepare_s: ($prep | num), collect_s: ($coll | num), outcome: ($outcome | str),
     job: ($job | str), candidate: ($cand | str), fallback: ($fallback | str)}' >> "$log"
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

# Runs a job keeping its output in the job log. The readers are started before the
# scope exists, so they stay out of its memory record and survive it being stopped;
# they ignore stop signals so the command's last output still gets through. The
# wait covers the normal case, where they finish with the command, and gives up on
# a process that keeps the output open.
run_captured() {  # <command> [args...]
  local keeper rc tries=0
  [ -n "$joblog" ] || { "$@" 8>&- 9>&-; return; }
  exec 7> >(
    exec 2>/dev/null 8>&- 9>&-
    trap '' HUP INT TERM
    tail -c "$LOG_MAX_BYTES" > "$joblog" || exec cat > /dev/null
    [ "$(wc -c < "$joblog")" -lt "$LOG_MAX_BYTES" ] || sed -i '1c [fm-heavy: earlier output dropped]' "$joblog"
  )
  keeper=$!
  exec 5> >(trap '' HUP INT TERM; exec tee /dev/fd/7 8>&- 9>&-)
  exec 6> >(trap '' HUP INT TERM; exec tee /dev/fd/7 >&2 5>&- 8>&- 9>&-)
  "$@" >&5 2>&6 5>&- 6>&- 7>&- 8>&- 9>&-
  rc=$?
  exec 5>&- 6>&- 7>&-
  while kill -0 "$keeper" 2>/dev/null && [ "$tries" -lt 100 ]; do
    sleep 0.02
    tries=$((tries + 1))
  done
  return "$rc"
}

finish() {  # <exit status>
  record "$1"
  if [ -n "$joblog" ]; then
    [ "$1" = 0 ] || timeout 10 "$LEDGER" capture --log "$joblog" --job "$unit" --task "$task" \
      --project "$project" --class "$class" --command "$command_line" </dev/null >/dev/null 2>&1
    find "$logs" -maxdepth 1 -name '*.log' -printf '%T@ %p\n' | sort -rn | tail -n "+$((LOGS_KEPT + 1))" \
      | cut -d' ' -f2- | xargs -r -d '\n' rm -f
  fi
  exit "$1"
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

# Try local slots without waiting before automatic offload. Keep the acquired
# descriptor through execution so another caller cannot steal the free slot.
try_local() {
  local i=1 slot_lock
  while [ "$i" -le "$slots" ]; do
    slot_lock=$lock; [ "$i" -gt 1 ] && slot_lock=$lock.$i
    exec 9>>"$slot_lock" || { echo "fm-heavy.sh: cannot open $slot_lock" >&2; exit 2; }
    if interruptible flock -n 9; then slot=$i; return 0; fi
    exec 9>&-
    i=$((i + 1))
  done
  return 1
}

# The host takes one job at a time, under its own descriptor lock. Returns only
# when the job did not run there, with the reason in $fallback.
remote_recheck=0
try_remote() {
  exec 8>>"$lock.remote.$rhost" || { echo "fm-heavy.sh: cannot open $lock.remote.$rhost" >&2; exit 2; }
  if flock -n 8; then
    started=$(date +%s)  # signals now belong to the driver
    run_captured "$REMOTE" --host "$rhost" --timeout "$rtimeout" --sample "$sample" \
      --project "$project" --class "$class" --state-dir "$root/state/heavy-remote" -- "$@"
    rc=$?
    fallback=$(sget fallback)
    if [ -z "$fallback" ]; then
      host=$rhost
      [ -z "$signal" ] || rc=$((128 + signal))
      finish "$rc"
    fi
    started=; : > "$sample"
    [ -z "$signal" ] || on_signal "$signal"
    remote_recheck=$((SECONDS + ${FM_HEAVY_REMOTE_RECHECK:-30}))
  else
    fallback=destination-busy
  fi
  exec 8>&-
}

if [ -z "$remote" ] && [ -n "$offload" ] && [ -n "$approved" ]; then
  try_local || remote=1
fi
[ -z "$remote" ] || try_remote "$@"

# A job the host may still take polls both destinations; every other job keeps
# the blocking single-slot path and its signal handling, and multiple slots retry.
while [ -z "$slot" ]; do
  case "$remote:$fallback" in
    1:destination-busy|1:unreachable|1:unknown-job-running)
      try_local && break
      [ "$SECONDS" -lt "$remote_recheck" ] || try_remote "$@"
      interruptible sleep 2
      ;;
    *)
      if [ "$slots" -eq 1 ]; then
        exec 9>>"$lock" || { echo "fm-heavy.sh: cannot open $lock" >&2; exit 2; }
        interruptible flock 9 && slot=1
      else
        try_local || interruptible sleep 2
      fi
      ;;
  esac
done

# The command stays in the foreground so it keeps stdin and default signal
# handling. run_captured closes the lock descriptor in the command, so a process
# it leaves running (a daemon it auto-starts) cannot keep the slot held after it exits.
started=$(date +%s)
run_captured systemd-run --user --scope -q -p "MemoryMax=$MEMORY_MAX" -p MemorySwapMax=0 \
  --unit="$unit" "$SELF" --stage-scoped "$unit" "$sample" "$@"
rc=$?
[ -z "$signal" ] || rc=$((128 + signal))
finish "$rc"
