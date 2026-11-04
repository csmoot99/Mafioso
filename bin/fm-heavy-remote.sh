#!/usr/bin/env bash
# fm-heavy-remote.sh - run one approved portable test command on a remote host
# over SSH instead of this machine's heavy slot. bin/fm-heavy.sh --remote calls
# it; it is not a user command.
#
# usage: fm-heavy-remote.sh --host <ssh alias> --timeout <seconds> --sample <file>
#          --state-dir <dir> -- <command> [args...]
#
# The command must be a repository-relative portable command run from the
# repository root, and the working tree must be clean: the candidate is exactly
# the committed HEAD. The job:
#   1. exports HEAD as a git bundle (history included, because the suites clone
#      the repository) and ships it, a manifest and bin/fm-heavy-remote-runner.py
#      in one ssh stream; the runner verifies both digests, checks out and
#      verifies the exact sha, and launches the command detached in its own
#      process group under ~/.fm-heavy-remote/<job> on the host;
#   2. waits for the runner's durable result.json (the completion record);
#   3. collects result.json and run.log into <state-dir>/<job>/, checks the job id,
#      candidate sha, command and bundle digests and the run.log checksum, and
#      relays run.log on stdout;
#   4. removes the host's scratch and anything the job still owns.
# A job counts as passed only when every check holds and the command exited 0. The
# job's stages are written to the --sample file for bin/fm-heavy.sh's record.
#
# Nothing started: when the host is unreachable, the tree is dirty, an earlier
# job is still running there or the host cannot prepare the job, the sample gets
# fallback=<reason> and the exit status is 0, so the caller runs the command
# locally under its normal slot. A signalled script ends cancelled instead.
#
# Outcomes (outcome= in the sample; exit status in parentheses):
#   pass (0), failed (the command's own status), timeout (124: the host killed the
#   job's own process group at --timeout), rejected (65: wrong sha, command or
#   bundle digest, wrong or replayed job, missing or partial artifacts, or a check
#   that did not finish; never a pass), lost (70: the job's supervisor died
#   without a result), unknown (75: the connection was lost and the job could not
#   be reached again within FM_HEAVY_REMOTE_RECONNECT_TRIES attempts, so whether
#   it ran is unknown; also a finished job whose result stayed unreachable after
#   that many tries; the host's scratch and the open record are kept and no retry
#   is made), cancelled
#   (128+n: this script was signalled and stopped only its own job; a signal
#   before the outcome is recorded replaces any other outcome, even once every
#   check has held; 143 when the job was stopped on the host, whatever status the
#   command itself exited with).
# After a lost connection the job is reconciled against its record on the host
# before anything else happens: a job found running or done is waited for and
# collected, never run again.
#
# Open records: <state-dir>/unknown-<host>/<job>.json is written before anything
# reaches the host and removed only once the host's scratch is gone or nothing was
# launched, so an open record means the host may still hold that job. Before a new
# job is admitted, every open record for the host is reconciled over SSH from the
# job's result.json, started marker and owned process group:
#   running     no second job starts; fallback=unknown-job-running. A job whose
#               supervisor is gone is stopped first, since nothing else would stop
#               it, and its record closes on the next request.
#   finished    its result is collected for its own record only, never as a pass
#               for the new candidate; its scratch is removed and the record closes
#               into <state-dir>/<job>/reconciled.json (job, candidate, outcome and
#               reconciled_at). outcome is pass, failed, timeout, cancelled,
#               rejected, lost, or absent when the job never arrived. A signal
#               while its result is collected or checked leaves the record open.
#   unreachable the record stays; fallback=unreachable.
#
# Environment (all optional): FM_HEAVY_REMOTE_RECONNECT_TRIES (5),
# FM_HEAVY_REMOTE_RECONNECT_SLEEP (3 s).
set -u
set -o pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host=; timeout_s=; sample=; state_dir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) host=${2:-}; shift 2 || break ;;
    --timeout) timeout_s=${2:-}; shift 2 || break ;;
    --sample) sample=${2:-}; shift 2 || break ;;
    --state-dir) state_dir=${2:-}; shift 2 || break ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ -n "$host" ] && [ -n "$sample" ] && [ -n "$state_dir" ] && [ "$#" -gt 0 ] || {
  echo "fm-heavy-remote.sh: usage error (see the header)" >&2; exit 2; }
case "$timeout_s" in ''|*[!0-9]*|0*) echo "fm-heavy-remote.sh: --timeout must be a positive integer" >&2; exit 2 ;; esac
id="$(date +%s)-$$-$RANDOM"

tries=${FM_HEAVY_REMOTE_RECONNECT_TRIES:-5}
pause=${FM_HEAVY_REMOTE_RECONNECT_SLEEP:-3}
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
rdir=.fm-heavy-remote/$id
runner="python3 $rdir/runner.py"
jdir=$state_dir/$id
open_records=$state_dir/unknown-$host
record=$open_records/$id.json
stage=$(mktemp -d)
sig=; bg=; blocked=
trap 'rm -rf "$stage"' EXIT
trap 'sig=1; [ -z "$bg" ] || kill "$bg" 2>/dev/null' HUP
trap 'sig=2; [ -z "$bg" ] || kill "$bg" 2>/dev/null' INT
trap 'sig=15; [ -z "$bg" ] || kill "$bg" 2>/dev/null' TERM

emit() { printf '%s=%s\n' "$1" "$2" >> "$sample"; }
rssh() { "${SSH[@]}" "$host" "$@" </dev/null; }
rrun() { rssh "$runner $1 $rdir ${2:-}"; }  # <runner action> [argument]
fallback() {  # <reason>: nothing was started; the caller runs the command locally
  rmdir "$jdir" 2>/dev/null
  rm -f "$record"
  [ -z "$sig" ] || finish cancelled $((128 + sig))  # a signalled job never runs, here or locally
  emit fallback "$1"
  echo "fm-heavy-remote: not running on $host ($1); running locally" >&2
  exit 0
}
# Run an ssh step in the background so a signal reaches the trap at once.
bgssh() {  # <outfile> args...
  local out=$1
  shift
  rssh "$@" > "$out" 2>>"$stage/ssh.err" &
  bg=$!
  wait "$bg"
  local rc=$?
  bg=
  return "$rc"
}
# The shell test for a job that began on the host. The runner writes started only
# after the whole stream arrived, so without it runner.py may be cut short; a
# cleanup cut short can leave started behind without the runner.
began() { printf '[ -f %s/started ] && [ -f %s/runner.py ]' "$rdir" "$rdir"; }
# Reconcile with the job's record on the host: print its state, or "unreachable".
job_state() {  # [runner action, default status]
  local n=0 out
  while [ "$n" -lt "$tries" ]; do
    [ -z "$sig" ] || { echo cancelled; return; }
    out=$(rssh "if $(began); then $runner ${1:-status} $rdir; else echo absent; fi" 2>>"$stage/ssh.err") \
      && { printf '%s\n' "$out"; return; }
    n=$((n + 1))
    [ "$n" -ge "$tries" ] || sleep "$pause"
  done
  echo unreachable
}
finish() {  # <outcome> <exit status>; once this script is signalled, always cancelled
  if [ -n "$sig" ]; then
    [ ! -e "$record" ] || cleanup_remote
    set -- cancelled $((128 + sig))
  fi
  emit outcome "$1"
  emit job "$id"
  exit "$2"
}
cleanup_remote() {
  if rssh "if $(began); then $runner cleanup $rdir; else rm -rf $rdir; fi" >/dev/null 2>>"$stage/ssh.err"; then
    rm -f "$record"
  else
    echo "fm-heavy-remote: could not remove $host:~/$rdir" >&2
  fi
}
# Fetch from the host's job directory into the local one. Status 0: fetched; 1: the
# host answered but the files are missing or incomplete; 255: the host could not be
# reached within the reconnect attempts (or this script was signalled).
collect() {  # <file...>
  local n=0 rc
  while :; do
    bgssh "$stage/collect.tar" "cd $rdir && tar -cf - $*"
    rc=$?
    [ "$rc" -ne 0 ] || { tar -xf "$stage/collect.tar" -C "$jdir" "$@" 2>/dev/null && return 0 || return 1; }
    [ -z "$sig" ] || return 255
    [ "$rc" -eq 255 ] || return 1
    n=$((n + 1))
    [ "$n" -lt "$tries" ] || return 255
    sleep "$pause"
  done
}
result_problem() {  # status 0 only when the collected result holds every check; otherwise print why
  local want
  jq -e --arg id "$id" --arg sha "$sha" --arg cs "$cmd_sha" --arg bs "$bundle_sha" '
    .schema == "fm-heavy-remote.v1" and .id == $id and .sha == $sha and .command_sha256 == $cs
    and .bundle_sha256 == $bs and (.outcome | IN("exited", "timeout", "cancelled"))
    and (.exit_code | type) == "number" and (.artifacts["run.log"] | type) == "object"' \
    "$jdir/result.json" >/dev/null 2>&1 || { echo "wrong candidate, command, job or malformed envelope"; return 1; }
  want=$(jq -r '.artifacts["run.log"] | "\(.bytes) \(.sha256)"' "$jdir/result.json")
  [ "$(wc -c < "$jdir/run.log") $(sha256sum "$jdir/run.log" | cut -d' ' -f1)" = "$want" ] \
    || { echo "run.log does not match its recorded size and checksum"; return 1; }
}
result_outcome() {
  jq -r 'if .outcome == "exited" then (if .exit_code == 0 then "pass" else "failed" end) else .outcome end' "$jdir/result.json"
}
# Settle one open record. The locals stand in for the new job's while the helpers
# above work on the earlier one. Status 0: nothing of it remains on the host;
# otherwise $blocked is why the new job may not start there.
reconcile_job() {  # <open record>
  local record=$1 id rdir runner jdir sha cmd_sha bundle_sha state outcome rc
  id=$(basename "$record" .json)
  rdir=.fm-heavy-remote/$id
  runner="python3 $rdir/runner.py"
  jdir=$state_dir/$id
  sha=$(jq -r .sha "$record" 2>/dev/null)
  cmd_sha=$(jq -r .command_sha256 "$record" 2>/dev/null)
  bundle_sha=$(jq -r .bundle_sha256 "$record" 2>/dev/null)
  mkdir -p "$jdir"
  state=$(job_state reconcile)
  case "$state" in
    running|preparing) blocked=unknown-job-running; return 1 ;;
    orphaned)
      rrun cancel >/dev/null 2>>"$stage/ssh.err"
      blocked=unknown-job-running
      return 1
      ;;
    done)
      collect result.json run.log
      rc=$?
      if [ "$rc" -eq 255 ] || [ -n "$sig" ]; then blocked=unreachable; return 1; fi
      outcome=rejected
      if [ "$rc" -eq 0 ] && result_problem >/dev/null; then outcome=$(result_outcome); fi
      [ -z "$sig" ] || { blocked=unreachable; return 1; }
      ;;
    lost) collect run.log; outcome=lost ;;
    absent) outcome=absent ;;
    *) blocked=unreachable; return 1 ;;
  esac
  [ -e "$jdir/reconciled.json" ] || jq -c --arg outcome "$outcome" --argjson at "$(date +%s)" \
    '{job: .id, candidate: .sha, outcome: $outcome, reconciled_at: $at}' "$record" > "$jdir/reconciled.json"
  echo "fm-heavy-remote: earlier job $id on $host ended $outcome (kept in $jdir)" >&2
  cleanup_remote
  [ ! -e "$record" ] || { blocked=unreachable; return 1; }
}

# Eligibility: the candidate is the committed HEAD of a clean repository root.
top=$(git rev-parse --show-toplevel 2>/dev/null) || fallback not-a-git-repository
[ "$(pwd -P)" = "$(cd "$top" && pwd -P)" ] || fallback not-repository-root
[ -z "$(git status --porcelain 2>/dev/null)" ] || fallback dirty-tree
sha=$(git rev-parse HEAD) || fallback not-a-git-repository
rssh true >/dev/null 2>"$stage/ssh.err" || fallback unreachable
mkdir -p "$jdir" "$open_records" || fallback state-unwritable

for open in "$open_records"/*.json; do
  [ -e "$open" ] || continue
  reconcile_job "$open" && continue
  [ -z "$sig" ] || finish cancelled $((128 + sig))
  fallback "$blocked"
done

emit candidate "$sha"
prepare_began=$(date +%s)
emit wait_until "$prepare_began"
cmd_sha=$(printf '%s\0' "$@" | sha256sum | cut -d' ' -f1)
git bundle create "$stage/src.bundle" HEAD >/dev/null 2>&1 || fallback bundle-failed
bundle_sha=$(sha256sum "$stage/src.bundle" | cut -d' ' -f1)
argv=$(printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]') || fallback manifest-failed
jq -n --arg id "$id" --arg sha "$sha" --arg cs "$cmd_sha" --arg bs "$bundle_sha" --argjson t "$timeout_s" \
  --argjson argv "$argv" '{id: $id, sha: $sha, command_sha256: $cs, bundle_sha256: $bs, timeout_s: $t, argv: $argv}' \
  > "$stage/manifest.json" || fallback manifest-failed
cp "$SELF_DIR/fm-heavy-remote-runner.py" "$stage/runner.py"
cp "$stage/manifest.json" "$record" || fallback state-unwritable

tar -cf - -C "$stage" runner.py manifest.json src.bundle \
  | "${SSH[@]}" "$host" "mkdir -p $rdir && tar -xf - -C $rdir && $runner start $rdir" \
    > "$stage/start.out" 2>>"$stage/ssh.err"
rc=$?
if [ "$rc" -ne 0 ]; then
  if [ -n "$sig" ]; then  # signalled while starting: the job may be running
    rrun cancel >/dev/null 2>>"$stage/ssh.err"
    cleanup_remote
    finish cancelled $((128 + sig))
  elif [ "$rc" -eq 255 ] || [ "$rc" -eq 11 ]; then  # the job may have started without the runner saying so
    case $(job_state) in
      absent)  # a dropped transfer can leave part of the job directory behind
        cleanup_remote
        [ ! -e "$record" ] || finish unknown 75
        fallback transfer-failed
        ;;
      unreachable) emit prepare_s "$(($(date +%s) - prepare_began))"; finish unknown 75 ;;
    esac
  else  # the runner refused, or mkdir, tar or python failed: nothing was launched
    cleanup_remote
    fallback prepare-failed
  fi
fi
started=$(date +%s)
emit started "$started"
emit prepare_s "$((started - prepare_began))"

# Wait for the durable completion record. A lost connection is reconciled against
# the job's record, never answered with a second run.
deadline=$((started + timeout_s + 60))
state=running
while :; do
  [ -z "$sig" ] || break
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then  # the host's own timeout should have fired
    rrun cancel >/dev/null 2>>"$stage/ssh.err"
    state=$(job_state)
    case "$state" in done|lost|absent) ;; *) state=unreachable ;; esac
    break
  fi
  if bgssh "$stage/wait.out" "$runner wait $rdir $((deadline - now))"; then
    state=$(<"$stage/wait.out")
  else
    [ -z "$sig" ] || break
    state=$(job_state)
  fi
  case "$state" in running|preparing) ;; *) break ;; esac
done
ended=$(date +%s)

if [ -n "$sig" ]; then
  rrun cancel >/dev/null 2>>"$stage/ssh.err"
  cleanup_remote
  finish cancelled $((128 + sig))
fi
[ "$state" != unreachable ] || finish unknown 75
emit ended "$ended"  # the completion was seen

collect_began=$(date +%s)
collected=1
files=(result.json run.log)
if [ "$state" != "done" ]; then files=(run.log); fi
collect "${files[@]}"
crc=$?
if [ "$crc" -eq 255 ]; then  # the result stays on the host and its record stays open
  emit collect_s "$(($(date +%s) - collect_began))"
  if [ -n "$sig" ]; then
    cleanup_remote
    finish cancelled $((128 + sig))
  fi
  finish unknown 75
fi
[ "$crc" -eq 0 ] || collected=
emit collect_s "$(($(date +%s) - collect_began))"
[ ! -s "$jdir/run.log" ] || cat "$jdir/run.log"

reject() {  # <why>: collected evidence failed a check
  echo "fm-heavy-remote: result rejected: $1 (kept in $jdir)" >&2
  cleanup_remote
  finish rejected 65
}
if [ "$state" = lost ] || [ "$state" = absent ]; then
  echo "fm-heavy-remote: the job on $host ended without a result" >&2
  cleanup_remote
  finish lost 70
fi
[ -n "$collected" ] || reject "result or log missing or incomplete"
why=$(result_problem) || reject "${why:-the checks did not finish}"
emit cpu "$(jq -r '.cpu_usec' "$jdir/result.json")"
cleanup_remote

outcome=$(result_outcome)
code=$(jq -r '.exit_code' "$jdir/result.json")
case "$outcome" in
  timeout) code=124 ;;
  cancelled) code=143 ;;
esac
finish "$outcome" "$code"
