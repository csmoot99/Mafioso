#!/usr/bin/env bash
# fm-heavy-remote.sh - run one approved portable test command on a remote host
# over SSH instead of this machine's heavy slot. bin/fm-heavy.sh --remote calls
# it; it is not a user command.
#
# usage: fm-heavy-remote.sh --host <ssh alias> --timeout <seconds> --sample <file>
#          --state-dir <dir> --project <name> [--class test|e2e] [--image <ref>] [--host-slots <1-64>]
#          [--service "<name> <image> <port> <memory> [KEY=VALUE...]"]... [--env KEY=VALUE]...
#          -- <command> [args...]
#
# The command must be a repository-relative portable command run from the
# repository root. A clean tree uses HEAD; uncommitted work uses a snapshot
# commit with HEAD as parent, including tracked changes and non-ignored untracked
# files as git add -A would, without changing the real index or working tree.
# snapshot=true in the sample identifies that candidate. The job:
#   1. exports the candidate as a git bundle (history included, because the suites clone
#      the repository) and ships it, a manifest and bin/fm-heavy-remote-runner.py
#      in one ssh stream; the runner verifies both digests, checks out and
#      verifies the exact sha, and launches the command detached in its own
#      process group under ~/.fm-heavy-remote/<job> on the host;
#      Dependency preparation runs inside the supervised group, using a
#      per-project cache; runtime/install failures are collected for local fallback.
#   2. waits for the runner's durable result.json (the completion record);
#   3. collects result.json and run.log into <state-dir>/<job>/, checks the job id,
#      candidate sha, command and bundle digests and the run.log checksum, and
#      relays run.log on stdout;
#   4. removes the host's scratch and anything the job still owns.
# A job counts as passed only when every check holds and the command exited 0. The
# job's stages are written to the --sample file for bin/fm-heavy.sh's record.
#
# The host's own heavy jobs (bin/fm-heavy.sh there) and the jobs sent here share its
# capacity: a job is sent only while a host slot is free and no local job there is
# waiting for it, and neither kind is ever stopped for the other. With --image the
# command runs inside that Linux container image on the host (see the runner).
#
# No project command started: when the host is unreachable or busy, a snapshot cannot be
# created (snapshot-failed), an earlier job is still running there or the host
# cannot prepare the job, the sample gets
# fallback=<reason> and the exit status is 0, so the caller keeps the command in
# its local queue. A verified prepare-failed result adds preparation_step and
# preparation_log (the retained, verified run.log) only after remote cleanup
# succeeds; a refusal before launch may have neither field.
# A command failure, even exit 78, stays failed.
# A signalled script ends cancelled instead.
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
# collected. Local fallback follows only a verified preparation failure and
# successful cleanup; an uncertain result never authorizes another execution.
#
# Open records: <state-dir>/unknown-<host>/<job>.json is written before anything
# reaches the host and removed only once the host's scratch is gone or nothing was
# launched, so an open record means the host may still hold that job. Each record
# includes client_pid and client_start; matching both identifies its live local
# collection owner without mistaking a reused PID for that client.
# Before admission, every record is checked under <state-dir>/<job>/reconcile.lock;
# a competing collector causes fallback=unknown-job-running. After taking the lock,
# the request rechecks record existence and ownership, then queries the remote
# result.json, started marker and owned process group:
#   live owner collection and cleanup stay with that client. Running, preparing,
#               finished, lost or absent jobs do not block another request's
#               capacity check; an orphaned group blocks with unknown-job-running,
#               and an unreachable job blocks with unreachable.
# Without a live owner:
#   running     no new job starts; fallback=unknown-job-running. A job whose
#               supervisor is gone but whose group survives is stopped first,
#               and its record closes on the next request.
#   finished    its result is collected for its own record only, never as a pass
#               for the new candidate; its scratch is removed and the record closes
#               into <state-dir>/<job>/reconciled.json (job, candidate, outcome and
#               reconciled_at). outcome is pass, failed, prepare-failed, timeout, cancelled,
#               rejected, lost, or absent when the job never arrived. A signal
#               while its result is collected or checked leaves the record open.
#   unreachable the record stays; fallback=unreachable.
#
# Environment (all optional): FM_HEAVY_REMOTE_RECONNECT_TRIES (5),
# FM_HEAVY_REMOTE_RECONNECT_SLEEP (3 s).
set -u
set -o pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host=; host_slots=1; timeout_s=; sample=; state_dir=; project=; class="test"; image=; services=(); envs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) project=${2:-}; shift 2 || break ;;
    --class) class=${2:-}; shift 2 || break ;;
    --image) image=${2:-}; shift 2 || break ;;
    --service) services+=("${2:-}"); shift 2 || break ;;
    --env) envs+=("${2:-}"); shift 2 || break ;;
    --host-slots) host_slots=${2:-}; shift 2 || break ;;
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
[[ $host_slots =~ ^[1-9][0-9]?$ ]] && [ "$host_slots" -le 64 ] || { echo "fm-heavy-remote.sh: --host-slots must be 1-64" >&2; exit 2; }
id="$(date +%s)-$$-$RANDOM"
client_start=$(ps -o lstart= -p $$)

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
fallback() {  # <reason>: no project command started; the caller keeps the command in its local queue
  rmdir "$jdir" 2>/dev/null
  rm -f "$record"
  [ -z "$sig" ] || finish cancelled $((128 + sig))  # a signalled job never runs, here or locally
  emit fallback "$1"
  echo "fm-heavy-remote: not running on $host ($1); staying in the local queue" >&2
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
    and .bundle_sha256 == $bs and (.outcome | IN("exited", "timeout", "cancelled", "prepare-failed"))
    and (if .outcome == "prepare-failed" then .exit_code != 0 and (.preparation_step | type) == "string" else true end)
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
# above work on the earlier one. Status 0: nothing remains, or a live driver owns it;
# otherwise $blocked is why the new job may not start there.
reconcile_job() {
  local rc lock_dir
  lock_dir=$state_dir/$(basename "$1" .json)
  mkdir -p "$lock_dir" || { blocked=unreachable; return 1; }
  exec 7>>"$lock_dir/reconcile.lock" || { blocked=unreachable; return 1; }
  if flock -n 7; then
    reconcile_locked_job "$1"
    rc=$?
  else
    blocked=unknown-job-running
    rc=1
  fi
  exec 7>&-
  return "$rc"
}
reconcile_locked_job() {
  local record=$1 id rdir runner jdir sha cmd_sha bundle_sha state outcome rc owner owner_start
  [ -e "$record" ] || return 0
  # Another live driver owns collection. Once it exits, ordinary reconciliation
  # applies, including to unknown jobs. Start time protects against PID reuse.
  owner=$(jq -r '.client_pid // empty' "$record")
  owner_start=$(jq -r '.client_start // empty' "$record")
  id=$(basename "$record" .json)
  rdir=.fm-heavy-remote/$id
  runner="python3 $rdir/runner.py"
  jdir=$state_dir/$id
  sha=$(jq -r .sha "$record" 2>/dev/null)
  cmd_sha=$(jq -r .command_sha256 "$record" 2>/dev/null)
  bundle_sha=$(jq -r .bundle_sha256 "$record" 2>/dev/null)
  mkdir -p "$jdir"
  state=$(job_state reconcile)
  if [[ $owner =~ ^[1-9][0-9]*$ ]] && [ -n "$owner_start" ] &&
    [ "$(ps -o lstart= -p "$owner" 2>/dev/null)" = "$owner_start" ]; then
    case "$state" in
      running|preparing|done|lost|absent) return 0 ;;
      orphaned) blocked=unknown-job-running ;;
      *) blocked=unreachable ;;
    esac
    return 1
  fi
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

# Eligibility: only repository roots; dirty roots use a private snapshot index.
top=$(git rev-parse --show-toplevel 2>/dev/null) || fallback not-a-git-repository
[ "$(pwd -P)" = "$(cd "$top" && pwd -P)" ] || fallback not-repository-root
sha=$(git rev-parse HEAD) || fallback not-a-git-repository
bundle_revs=(HEAD)
status=$(GIT_OPTIONAL_LOCKS=0 git status --porcelain --untracked-files=all 2>/dev/null) || fallback snapshot-failed
if [ -n "$status" ]; then
  # Copy the real index so staged additions (including tracked ignored files)
  # have exactly the same meaning as git add -A, but never refresh that index.
  index=$(git rev-parse --git-path index) || fallback snapshot-failed
  cp "$index" "$stage/index" || fallback snapshot-failed
  GIT_INDEX_FILE="$stage/index" git add -A || fallback snapshot-failed
  tree=$(GIT_INDEX_FILE="$stage/index" git write-tree) || fallback snapshot-failed
  sha=$(printf '%s\n' 'Snapshot of uncommitted work for remote tests' |
    git -c user.name=Firstmate -c user.email=firstmate@localhost commit-tree "$tree" -p "$sha") || fallback snapshot-failed
  bundle_revs+=("$sha")
  emit snapshot true
fi
[ -z "$sig" ] || finish cancelled $((128 + sig))
rssh true >/dev/null 2>"$stage/ssh.err" || fallback unreachable
mkdir -p "$jdir" "$open_records" || fallback state-unwritable

for open in "$open_records"/*.json; do
  [ -e "$open" ] || continue
  reconcile_job "$open" && continue
  [ -z "$sig" ] || finish cancelled $((128 + sig))
  fallback "$blocked"
done
# The host's own heavy jobs come first; the runner checks capacity and native waiters.
"${SSH[@]}" "$host" "python3 - busy $host_slots" < "$SELF_DIR/fm-heavy-remote-runner.py" >/dev/null 2>>"$stage/ssh.err"
case $? in 0) ;; 12) fallback destination-busy ;; *) fallback unreachable ;; esac

emit candidate "$sha"
prepare_began=$(date +%s)
emit wait_until "$prepare_began"
cmd_sha=$(printf '%s\0' "$@" | sha256sum | cut -d' ' -f1)
# HEAD gives clone an advertised ref; the extra revision includes the snapshot
# objects in its pack without creating any ref for that unreferenced commit.
git bundle create "$stage/src.bundle" "${bundle_revs[@]}" >/dev/null 2>&1 || fallback bundle-failed
bundle_sha=$(sha256sum "$stage/src.bundle" | cut -d' ' -f1)
argv=$(printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]') || fallback manifest-failed
pairs='map(capture("^(?<key>[^=]+)=(?<value>.*)$")) | from_entries'
svcs=$(printf '%s\0' ${services[@]+"${services[@]}"} | jq -Rsc "split(\"\\u0000\")[:-1] | map(select(. != \"\") | split(\" \")
  | {name: .[0], image: .[1], port: (.[2] | tonumber), memory: .[3], env: (.[4:] | $pairs)})") || fallback manifest-failed
jenv=$(printf '%s\0' ${envs[@]+"${envs[@]}"} | jq -Rsc "split(\"\\u0000\")[:-1] | $pairs") || fallback manifest-failed
jq -n --arg id "$id" --arg sha "$sha" --arg cs "$cmd_sha" --arg bs "$bundle_sha" --argjson t "$timeout_s" \
  --argjson slots "$host_slots" --argjson client_pid "$$" --arg client_start "$client_start" \
  --arg project "$project" --arg class "$class" --arg image "$image" --argjson services "$svcs" --argjson env "$jenv" \
  --argjson argv "$argv" '{host_slots: $slots, client_pid: $client_pid, client_start: $client_start, project: $project, class: $class, image: $image, services: $services, env: $env, id: $id, sha: $sha, command_sha256: $cs, bundle_sha256: $bs, timeout_s: $t, argv: $argv}' \
  > "$stage/manifest.json" || fallback manifest-failed
cp "$SELF_DIR/fm-heavy-remote-runner.py" "$stage/runner.py"
if ! cp "$stage/manifest.json" "$record.tmp" || ! mv "$record.tmp" "$record"; then fallback state-unwritable; fi
[ -z "$sig" ] || finish cancelled $((128 + sig))

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
  elif [ "$rc" -eq 12 ]; then  # the host's slot was taken or awaited meanwhile: nothing was launched
    cleanup_remote
    fallback destination-busy
  elif [ "$rc" -eq 13 ]; then  # the job and its services would not fit the host's docker memory
    cleanup_remote
    fallback services-do-not-fit
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
if [ "$outcome" = prepare-failed ]; then
  [ ! -e "$record" ] || finish unknown 75
  emit preparation_step "$(jq -r .preparation_step "$jdir/result.json")"
  emit preparation_log "$jdir/run.log"
  fallback prepare-failed
fi
case "$outcome" in
  timeout) code=124 ;;
  cancelled) code=143 ;;
esac
finish "$outcome" "$code"
