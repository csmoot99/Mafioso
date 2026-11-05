#!/usr/bin/env bash
# fm-bearings-rebuild.sh - request a home-local board rebuild after an answer.
#
# Usage: fm-bearings-rebuild.sh [--run]
# config/bearings-rebuild is an optional, trusted Bash script, run from FM_HOME
# with FM_HOME exported. Missing configuration does nothing, silently. --run is
# the detached worker's internal entry point, not another command per answer.
# Requests coalesce: one build at a time, with one more run if answers arrive
# during a build. Each build has a 120-second bound (override with the positive
# integer FM_BEARINGS_REBUILD_TIMEOUT_SECONDS, at most 600). Answer capture never
# waits for the build. Output goes to state/bearings-rebuild/last.log; failures
# also append failures.log and publish a check wake. No live board is inferred:
# the home's configured script must gather fresh inputs and build its own board.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/bearings-rebuild"
[ -f "$CONFIG" ] || exit 0
# Resolve before changing directory for the configured command, including when
# the caller supplied a relative home or config override.
CONFIG="$(cd "${CONFIG%/*}" && pwd)/bearings-rebuild"
FM_HOME="$(cd "$FM_HOME" && pwd)"
case "${1:-}" in ''|--run) ;; *) exit 2 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
umask 077
WORK="$STATE/bearings-rebuild"
mkdir -p "$WORK"
request_lock="$WORK/request.lock"
run_lock="$WORK/run.lock"
trap 'fm_lock_release "$request_lock"; fm_lock_release "$run_lock"' EXIT
trap 'exit 143' TERM INT

failure() {
  local message=$1
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$message" >> "$WORK/failures.log"
  if fm_lock_acquire_wait_max "$FM_WAKE_QUEUE_LOCK" 5; then
    fm_wake_append_locked check bearings-rebuild "$message; output=$WORK/last.log" || true
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
}

if [ "${1:-}" != --run ]; then
  fm_lock_acquire_wait_max "$request_lock" 5 || { failure 'Board rebuild request lock timed out'; exit 0; }
  : > "$WORK/pending"
  # Give the worker its own process group and detached stdio, as in deferred
  # startup checks, so the answer intake's exit cannot reap the bounded build.
  set -m
  nohup bash "$SCRIPT_DIR/fm-bearings-rebuild.sh" --run </dev/null >/dev/null 2>&1 &
  fm_lock_release "$request_lock"
  exit 0
fi

fm_lock_try_acquire "$run_lock" || exit 0
bound=${FM_BEARINGS_REBUILD_TIMEOUT_SECONDS:-120}
case "$bound" in
  ''|*[!0-9]*|0*) failure 'Invalid board rebuild timeout'; exit 0 ;;
esac
if [ "${#bound}" -gt 3 ] || [ "$bound" -gt 600 ]; then
  failure 'Invalid board rebuild timeout'
  exit 0
fi
while :; do
  fm_lock_acquire_wait_max "$request_lock" 5 || { failure 'Board rebuild request lock timed out'; exit 0; }
  if [ ! -e "$WORK/pending" ]; then
    # Release the runner while requests are excluded: a request either reaches
    # this worker's next pass or starts a new worker, never falls between them.
    fm_lock_release "$run_lock"
    fm_lock_release "$request_lock"
    exit 0
  fi
  rm -f "$WORK/pending"
  fm_lock_release "$request_lock"
  rc=0
  (cd "$FM_HOME" && fm_run_timed "$bound" bash "$CONFIG") > "$WORK/last.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || failure "Board rebuild failed (exit $rc); the answer remains recorded"
done
