#!/usr/bin/env bash
# Behavioral coverage for the SSH destination of bin/fm-heavy.sh (--remote),
# bin/fm-heavy-remote.sh and bin/fm-heavy-remote-runner.py. A fake ssh runs the
# "remote" command on this machine under a private HOME, so the real client, the
# real runner and a real job process group all execute, with disposable
# repositories, processes and data only. The fake can drop a connection before or
# after a command runs, or tamper with what the host holds before it is collected.
# Every failure case must leave the wrapper's status non-zero and the record's
# outcome something other than pass; a local run never happens behind a job that
# may still be running.
# shellcheck disable=SC2016,SC2029 # single-quoted scripts expand inside their own shells, and the fake ssh command is built here
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-heavy-remote)
HEAVY="$ROOT/bin/fm-heavy.sh"
RUNNER="$ROOT/bin/fm-heavy-remote-runner.py"
SUMMARY="$ROOT/bin/fm-heavy-summary.sh"

for tool in flock jq python3 git tar sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "# skip: $tool is not installed"; exit 0; }
done
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.invalid
export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.invalid
export FM_HEAVY_REMOTE_RECONNECT_SLEEP=0.1 FM_HEAVY_REMOTE_RECONNECT_TRIES=3

# The fake ssh: skips ssh's options and the host, then runs the command string in
# $FAKE_SSH_HOME, as a login would. Rules in $FAKE_SSH_CTL/rules/* misbehave:
#   line 1  drop (fail 255 without running), after (run, then fail 255), pre (run
#           the rest of the file as a script in the host's home first) or partial
#           (run that script, then fail 255 without running the command; both
#           scripts see the command string in $CMD and the runner in $RUNNER_SRC)
#   line 2  an extended regex the command string must match
#   line 3  how many matching calls still misbehave (-1 for all)
# Every command string is appended to $FAKE_SSH_CTL/log.
make_fake_ssh() {  # <fakebin>
  cat > "$1/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
cmd="$*"
printf '%s\n' "$cmd" >> "$FAKE_SSH_CTL/log"
mode=
for rule in "$FAKE_SSH_CTL"/rules/*; do
  [ -f "$rule" ] || continue
  left=$(sed -n 3p "$rule")
  [ "$left" != 0 ] || continue
  printf '%s' "$cmd" | grep -Eq "$(sed -n 2p "$rule")" || continue
  [ "$left" -lt 0 ] || sed -i "3s/.*/$((left - 1))/" "$rule"
  mode=$(sed -n 1p "$rule")
  case "$mode" in pre|partial) (cd "$FAKE_SSH_HOME" && HOME="$FAKE_SSH_HOME" CMD="$cmd" bash -c "$(sed -n '4,$p' "$rule")") ;; esac
  break
done
[ "$mode" != drop ] && [ "$mode" != partial ] || exit 255
cd "$FAKE_SSH_HOME" && HOME="$FAKE_SSH_HOME" bash -c "$cmd"
rc=$?
[ "$mode" != after ] || exit 255
exit "$rc"
SH
  chmod +x "$1/ssh"
}

make_unscoped_systemd_run() {  # <fakebin>
  cat > "$1/systemd-run" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in --user|--scope|-q) shift ;; -p) shift 2 ;; --unit=*) shift ;; *) break ;; esac; done
exec "$@"
SH
  chmod +x "$1/systemd-run"
}

# rule <name> <mode> <regex> <count> [script]: misbehave on matching remote calls.
rule() {
  mkdir -p "$CTL/rules"
  printf '%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "${5:-}" > "$CTL/rules/$1"
}

# setup <name> <job script body> [config timeout]: a home, a clean repository
# whose committed t/job.sh is the approved command, and the fake host.
setup() {
  local name=$1 fakebin
  CASE=$TMP_ROOT/$name
  HOME_FM=$CASE/home
  REPO=$CASE/repo
  CTL=$CASE/ctl
  REMOTE_HOME=$CASE/host
  LOCK=$CASE/slot.lock
  export FM_HEAVY_HOST_LOCK=$CASE/host.lock  # the host's own slot, shared with its local jobs
  LOG=$HOME_FM/state/heavy-jobs.jsonl
  mkdir -p "$HOME_FM/state" "$HOME_FM/config" "$CTL/rules" "$REMOTE_HOME" "$REPO/t"
  fakebin=$(fm_fakebin "$CASE")
  make_fake_ssh "$fakebin"
  make_unscoped_systemd_run "$fakebin"
  FAKEBIN=$fakebin
  printf '%s\n' '# approved for these tests only' 'host fake-mac' 'command p -- bash t/job.sh' "timeout ${3:-30}" \
    > "$HOME_FM/config/heavy-remote"
  printf '%s\n' "$2" > "$REPO/t/job.sh"
  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m candidate
  SHA=$(git -C "$REPO" rev-parse HEAD)
}

# heavy [args before --]: run the wrapper from the repository root.
heavy() {
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" \
    FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" RUNNER_SRC="$RUNNER" "$HEAVY" --class test --task t --project p "$@" -- bash t/job.sh) 3>&- 4>&-
}

last_record() { tail -1 "$LOG"; }
expect_record() {  # <jq filter> <message>
  last_record | jq -e "$1" >/dev/null || fail "$2: $(last_record)"
}
# Nothing of the job may survive on the host.
expect_host_clean() {  # <message>
  [ -z "$(ls -A "$REMOTE_HOME/.fm-heavy-remote" 2>/dev/null)" ] || fail "$1: $(ls "$REMOTE_HOME/.fm-heavy-remote")"
}
pid_alive() { kill -0 "$1" 2>/dev/null; }
wait_gone() {  # <pid>
  local n=0
  while pid_alive "$1"; do
    n=$((n + 1))
    [ "$n" -le 50 ] || return 1
    sleep 0.1
  done
}

test_pass_and_record() {
  local out
  setup pass 'git rev-parse HEAD'
  out=$(heavy --remote 2>&1) || fail "a passing remote job must exit 0: $out"
  assert_contains "$out" "$SHA" "the job ran on the exact candidate and its output reached stdout"
  expect_record ".host == \"fake-mac\" and .outcome == \"pass\" and .exit == 0 and .candidate == \"$SHA\"
    and .snapshot == false and .fallback == null and .slot == null and (.job | type) == \"string\"
    and (.prepare_s | type) == \"number\" and (.collect_s | type) == \"number\"
    and (.wait_s | type) == \"number\" and (.run_s | type) == \"number\"
    and .started_at >= .requested_at and .ended_at >= .started_at
    and .peak_memory_bytes == null and (.cpu_usec | type) == \"number\"" "remote record"
  expect_host_clean "scratch must be removed after a collected result"
  [ -z "$(ls -A "$HOME_FM/state/heavy-remote/unknown-fake-mac")" ] || fail "a finished job must leave no open record"
  assert_present "$HOME_FM/state/heavy-remote/$(last_record | jq -r .job)/result.json" "the result copy is kept locally"
  pass "fm-heavy --remote: the exact candidate runs on the host and the record has every stage"
}

# Fingerprint working files and Git control files, including raw index, refs,
# HEAD and stash reflogs. New objects are allowed; no existing control file is.
source_fingerprint() {
  python3 - "$REPO" <<'PYCODE'
import hashlib, os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
gitdir = pathlib.Path(subprocess.check_output(
    ["git", "-C", str(root), "rev-parse", "--absolute-git-dir"], text=True).strip())
for label, base in [("work", root), ("git", gitdir)]:
    for directory, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d != (".git" if label == "work" else "objects"))
        for name in sorted(files):
            path = pathlib.Path(directory) / name
            data = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
            print(label, path.relative_to(base), path.lstat().st_mode, hashlib.sha256(data).hexdigest())
PYCODE
}

test_dirty_snapshot() {
  setup snapshot 'test "$(cat tracked)" = modified && test ! -e deleted && test "$(cat new)" = untracked && test ! -e .env && git rev-parse HEAD && git rev-parse HEAD^'
  printf 'original\n' > "$REPO/tracked"
  printf 'delete me\n' > "$REPO/deleted"
  printf '.env\n' > "$REPO/.gitignore"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm 'snapshot fixtures'
  SHA=$(git -C "$REPO" rev-parse HEAD)
  echo stash > "$REPO/tracked"
  git -C "$REPO" stash push -qm 'preserve stash'
  echo staged > "$REPO/tracked"
  git -C "$REPO" add tracked
  echo modified > "$REPO/tracked"
  rm "$REPO/deleted"
  echo untracked > "$REPO/new"
  echo secret > "$REPO/.env"
  source_fingerprint > "$CASE/before"
  local out candidate
  out=$(heavy --remote 2>&1) || fail "snapshot run: $out"
  expect_record '.host == "fake-mac" and .snapshot == true and .outcome == "pass"' "snapshot record"
  candidate=$(last_record | jq -r .candidate)
  [ "$candidate" != "$SHA" ] || fail "dirty candidate must differ from HEAD"
  assert_contains "$out" "$candidate" "snapshot candidate ran"
  assert_contains "$out" "$SHA" "snapshot parent is HEAD"
  source_fingerprint > "$CASE/after"
  cmp "$CASE/before" "$CASE/after" || fail "snapshot changed source files or Git control files"
  expect_host_clean "snapshot scratch removed"
  pass "fm-heavy --remote: snapshot contains current files, excludes ignored files and preserves source state"
}

test_hidden_untracked_snapshot() {
  setup hidden-untracked 'test "$(cat new)" = untracked && git rev-parse HEAD'
  git -C "$REPO" config status.showUntrackedFiles no
  echo untracked > "$REPO/new"
  [ -z "$(git -C "$REPO" status --porcelain)" ] || fail "fixture must hide untracked files from default status"
  source_fingerprint > "$CASE/before"
  local out candidate
  out=$(heavy --remote 2>&1) || fail "hidden untracked snapshot run: $out"
  expect_record '.host == "fake-mac" and .snapshot == true and .outcome == "pass"' "hidden untracked snapshot record"
  candidate=$(last_record | jq -r .candidate)
  [ "$candidate" != "$SHA" ] || fail "untracked candidate must differ from HEAD"
  assert_contains "$out" "$candidate" "untracked snapshot candidate ran"
  source_fingerprint > "$CASE/after"
  cmp "$CASE/before" "$CASE/after" || fail "untracked snapshot changed source state"
  expect_host_clean "untracked snapshot scratch removed"
  pass "fm-heavy --remote: untracked-only trees are snapshotted when Git status hides untracked files"
}

test_snapshot_failure() {
  local step
  export REAL_GIT
  REAL_GIT=$(command -v git)
  for step in add write-tree commit-tree; do
    setup "snapshot-fail-$step" 'echo local'
    echo dirty > "$REPO/new"
    cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do [ "$arg" != "$SNAPSHOT_FAIL" ] || exit 1; done
exec "$REAL_GIT" "$@"
SH
    chmod +x "$FAKEBIN/git"
    source_fingerprint > "$CASE/before"
    SNAPSHOT_FAIL=$step heavy --remote >"$CASE/out" 2>&1 || fail "$step fallback"
    expect_record '.host == "local" and .fallback == "snapshot-failed" and .candidate == null' "$step fallback record"
    [ ! -s "$CTL/log" ] || fail "$step failure must send nothing"
    source_fingerprint > "$CASE/after"
    cmp "$CASE/before" "$CASE/after" || fail "$step failure changed source state"
  done
  pass "fm-heavy --remote: snapshot failures stay local without sending content or changing source state"
}

test_snapshot_bundle_failure() {
  local mode rc
  export REAL_GIT
  REAL_GIT=$(command -v git)
  for mode in failure signal; do
    setup "snapshot-bundle-$mode" 'echo ran'
    echo dirty > "$REPO/new"
    cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = bundle ]; then
  [ "$SNAPSHOT_BUNDLE" != signal ] || kill -TERM "$PPID"
  exit 1
fi
exec "$REAL_GIT" "$@"
SH
    chmod +x "$FAKEBIN/git"
    source_fingerprint > "$CASE/before"
    SNAPSHOT_BUNDLE=$mode heavy --remote >"$CASE/out" 2>&1
    rc=$?
    if [ "$mode" = signal ]; then
      expect_code 143 "$rc" "signal during snapshot bundle"
      expect_record '.outcome == "cancelled"' "snapshot cancellation"
    else
      expect_code 0 "$rc" "bundle failure falls back locally"
      expect_record '.fallback == "bundle-failed" and .host == "local"' "snapshot bundle fallback"
    fi
    if grep -q 'runner.py start' "$CTL/log"; then fail "failed snapshot bundle must send no job"; fi
    source_fingerprint > "$CASE/after"
    cmp "$CASE/before" "$CASE/after" || fail "$mode changed source files or Git control files"
  done
  pass "fm-heavy --remote: bundle failures and signals preserve source state"
}

test_off_by_default_and_refusals() {
  setup refuse 'echo hi'
  heavy >/dev/null 2>&1 || fail "without --remote the command runs locally"
  expect_record '.host == "local" and .prepare_s == null and .collect_s == null and .outcome == null
    and .job == null and .fallback == null and .slot == 1 and .exit == 0' "local record"
  [ ! -s "$CTL/log" ] || fail "without --remote nothing may reach the host"
  : > "$LOG"
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" "$HEAVY" --class test --project p --remote -- bash other.sh) 2>/dev/null
  expect_code 2 "$?" "a command that is not the approved one"
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" "$HEAVY" --class image --project p --remote -- bash t/job.sh) 2>/dev/null
  expect_code 2 "$?" "image stays local"
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" "$HEAVY" --class build --project p --remote -- bash t/job.sh) 2>/dev/null
  expect_code 2 "$?" "build stays local"
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" "$HEAVY" --class test --remote -- bash t/job.sh) 2>/dev/null
  expect_code 2 "$?" "a job with no project has no approval"
  rm "$HOME_FM/config/heavy-remote"
  heavy --remote >/dev/null 2>&1; expect_code 2 "$?" "no config"
  local bad
  for bad in 'host a\n' 'host a\ncommand p -- bash t/job.sh\nhost b\n' 'host a b\ncommand p -- bash t/job.sh\n' \
    'host a\ncommand p -- bash t/job.sh\ncommand p -- bash t/job.sh\n' 'host a\ncommand p -- bash t/job.sh\ntimeout 0\n' \
    'host a\ncommand p -- bash t/job.sh\nsurprise 1\n' 'host a\ncommand p -- bash t/job.sh\nsurprise 1' \
    'host a\ncommand p -- bash t/job.sh\ntimeout 0'; do
    # shellcheck disable=SC2059 # the cases are printf formats
    printf "$bad" > "$HOME_FM/config/heavy-remote"
    heavy --remote >/dev/null 2>&1; expect_code 2 "$?" "malformed config: $bad"
  done
  [ ! -s "$LOG" ] || fail "a refused run must write no record"
  [ ! -s "$CTL/log" ] || fail "a refused run must not reach the host"
  pass "fm-heavy --remote: off unless asked, and only the one approved command from a valid config"
}

test_fallbacks_run_locally() {
  setup fallback "echo ran >> $TMP_ROOT/fallback/ran"
  rule down drop . -1
  heavy --remote >/dev/null 2>&1 || fail "an unreachable host must fall back to a local run"
  expect_record '.host == "local" and .fallback == "unreachable" and .exit == 0 and .slot == 1 and .outcome == null' "unreachable fallback"
  [ "$(wc -l < "$CASE/ran")" -eq 1 ] || fail "the fallback must run the command once"
  rm "$CTL/rules/down"

  # The destination takes one job at a time; a second request does not queue behind it.
  flock -o "$LOCK.remote.fake-mac" sleep 5 &
  local holder=$! n=0
  until ! flock -n "$LOCK.remote.fake-mac" true; do n=$((n + 1)); [ "$n" -le 50 ] || fail "holder never took the lock"; sleep 0.1; done
  heavy --remote >/dev/null 2>&1 || fail "a busy destination must fall back to a local run"
  expect_record '.host == "local" and .fallback == "destination-busy"' "busy fallback"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

  # The host cannot prepare the job (its scratch root is a file): nothing ran there.
  rule noprep pre 'runner.py start' 1 'rm -rf .fm-heavy-remote; : > .fm-heavy-remote'
  heavy --remote >/dev/null 2>&1 || fail "a host that cannot prepare the job must fall back to a local run"
  expect_record '.host == "local" and .fallback == "prepare-failed"' "prepare-failed fallback"
  pass "fm-heavy --remote: an unreachable, busy or ineligible destination runs the command locally and says why"
}

test_prelaunch_refusal_does_not_reserve_a_slot() {
  local real_git failed_dir
  setup prelaunch-refusal "echo run >> '$TMP_ROOT/prelaunch-refusal/runs'"
  printf 'host fake-mac\nproject p\nhost-slots 2\n' > "$HOME_FM/config/heavy-remote"
  real_git=$(command -v git)
  cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${3:-}" = checkout ]; then
  printf '%s\n' "$2" > "$FAKE_SSH_CTL/failed-checkout"
  exit 1
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$FAKEBIN/git"
  rule cleanup drop 'runner.py cleanup' -1
  hold_host
  FM_TEST_REAL_GIT="$real_git" heavy --remote >"$CASE/first.out" 2>&1 5>&- || fail "a refused checkout falls back locally"
  expect_record '.host == "local" and .fallback == "prepare-failed" and .exit == 0' "checkout refusal fallback"
  assert_present "$CTL/failed-checkout" "the remote checkout actually failed"
  failed_dir=$(cat "$CTL/failed-checkout")
  failed_dir=${failed_dir%/work}
  assert_present "$failed_dir/started" "the refused transfer remains when follow-up cleanup is unavailable"
  assert_absent "$failed_dir/owner.json" "a failed checkout launches no supervisor"
  assert_grep 'runner.py cleanup' "$CTL/log" "the client attempted the unavailable follow-up cleanup"
  [ -z "$(ls -A "$HOME_FM/state/heavy-remote/unknown-fake-mac")" ] || fail "the definite refusal leaves no client recovery record"
  HOME="$REMOTE_HOME" python3 "$RUNNER" busy 2 >/dev/null
  expect_code 0 "$?" "failed preparation leaves the extra slot available without follow-up cleanup"
  ! flock -n "$FM_HEAVY_HOST_LOCK" true || fail "the native job still occupies the original slot"
  rm "$FAKEBIN/git" "$CTL/rules/cleanup"
  heavy --remote >"$CASE/second.out" 2>&1 5>&- || fail "the next job uses the freed remote capacity"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "remote admission after checkout refusal"
  [ "$(wc -l < "$CASE/runs")" -eq 2 ] || fail "the fallback and next remote job each run once"
  ! flock -n "$FM_HEAVY_HOST_LOCK" true || fail "the native job survives the remote recovery"
  release_host
  HOME="$REMOTE_HOME" python3 "$RUNNER" cleanup "$failed_dir" >/dev/null
  expect_host_clean "the refused scratch can be removed independently"
  pass "fm-heavy: checkout refusal preserves capacity when follow-up cleanup is unavailable"
}

test_failed_command() {
  setup failed 'echo broke >&2; exit 7'
  heavy --remote >"$CASE/out" 2>&1; expect_code 7 "$?" "the command's own status passes through"
  assert_grep broke "$CASE/out" "the command's output is relayed"
  expect_record '.outcome == "failed" and .exit == 7 and .host == "fake-mac"' "failed record"
  expect_host_clean "a failed job's scratch is removed too"
  assert_grep broke "$HOME_FM/state/heavy-remote/$(last_record | jq -r .job)/run.log" "the failure log is kept locally"
  pass "fm-heavy --remote: a failing command is a failure with its own status, log kept"
}

test_timeout_cancels_only_the_jobs_processes() {
  local foreign
  setup timeout 'sleep 300 & echo $! > "$HOME/child.pid"; sleep 300' 2
  sleep 300 &
  foreign=$!
  heavy --remote >/dev/null 2>&1; expect_code 124 "$?" "a timed-out job"
  expect_record '.outcome == "timeout" and .exit == 124' "timeout record"
  wait_gone "$(cat "$REMOTE_HOME/child.pid")" || fail "the job's own process must be stopped at the timeout"
  pid_alive "$foreign" || fail "a process the job does not own must survive"
  kill "$foreign" 2>/dev/null; wait "$foreign" 2>/dev/null
  expect_host_clean "scratch after a timeout"
  pass "fm-heavy --remote: a timeout stops the job's own process group and nothing else"
}

test_owned_processes_are_cleaned() {
  setup owned 'sleep 300 & echo $! > "$HOME/child.pid"'
  heavy --remote >/dev/null 2>&1 || fail "the job itself exited 0"
  wait_gone "$(cat "$REMOTE_HOME/child.pid")" || fail "a process the job left running must be stopped"
  pass "fm-heavy --remote: a process the job leaves behind is stopped with it"
}

test_killed_job_is_never_green() {
  setup killed 'kill -9 $$'
  heavy --remote >/dev/null 2>&1; expect_code 137 "$?" "a job killed from outside"
  expect_record '.outcome == "failed" and .exit == 137' "killed job record"

  # The job kills its own supervisor, so no result is ever published.
  setup lost 'sleep 300 & echo $! > "$HOME/child.pid"; sleep 1; kill -9 $PPID; sleep 300'
  heavy --remote >/dev/null 2>&1; expect_code 70 "$?" "a supervisor that died without a result"
  expect_record '.outcome == "lost" and .exit == 70' "lost job record"
  expect_host_clean "scratch after a lost job"
  wait_gone "$(cat "$REMOTE_HOME/child.pid")" || fail "a lost job's own processes must be cleaned up"
  pass "fm-heavy --remote: a killed job or a dead supervisor is never a pass, and its processes are cleaned up"
}

test_connection_lost_is_reconciled() {
  # The wait connection drops once: the job is found again in its record and collected.
  setup reconcile 'echo run >> "$HOME/runs"; sleep 1'
  rule wait drop 'runner.py wait' 1
  heavy --remote >/dev/null 2>&1 || fail "a job found again after a dropped wait must still pass"
  expect_record '.outcome == "pass"' "reconciled record"
  [ "$(wc -l < "$REMOTE_HOME/runs")" -eq 1 ] || fail "a reconnect must never run the job a second time"

  # The start succeeds on the host but its answer is lost: the running job is adopted.
  setup lostack 'echo run >> "$HOME/runs"; sleep 1'
  rule start after 'runner.py start' 1
  heavy --remote >/dev/null 2>&1 || fail "a job whose start answer was lost must be adopted, not rerun"
  expect_record '.outcome == "pass"' "adopted record"
  [ "$(wc -l < "$REMOTE_HOME/runs")" -eq 1 ] || fail "an adopted job must run exactly once"

  # The start never reached the host and the host answers again: safe to run locally.
  setup neverran "echo run >> $TMP_ROOT/neverran/runs"
  rule start drop 'runner.py start' 1
  heavy --remote >/dev/null 2>&1 || fail "a start that never arrived must fall back to a local run"
  expect_record '.host == "local" and .fallback == "transfer-failed"' "transfer-failed record"
  [ "$(wc -l < "$TMP_ROOT/neverran/runs")" -eq 1 ] || fail "the fallback runs the command once"
  pass "fm-heavy --remote: a lost connection is reconciled with the job's record, never answered with a second run"
}

test_unreachable_job_is_unknown() {
  setup unknown 'echo run >> "$HOME/runs"; sleep 1'
  rule gone drop 'runner.py (wait|status)' -1
  heavy --remote >"$CASE/out" 2>&1; expect_code 75 "$?" "a job that cannot be reached again"
  expect_record '.outcome == "unknown" and .exit == 75 and .host == "fake-mac" and (.job | type) == "string"
    and .ended_at == null and .run_s == null' "unknown record: completion was never seen"
  assert_present "$REMOTE_HOME/.fm-heavy-remote/$(last_record | jq -r .job)" "an unknown job's scratch is kept for reconciliation"
  assert_present "$HOME_FM/state/heavy-remote/unknown-fake-mac/$(last_record | jq -r .job).json" "an unknown job's record stays open"
  [ "$(wc -l < "$LOG")" -eq 1 ] || fail "an unknown job must not be retried locally: $(cat "$LOG")"
  sleep 2.5
  pass "fm-heavy --remote: a job that cannot be reached is unknown, kept, and never retried"
}

test_bad_results_are_rejected() {
  local case_name
  # Each rule edits what the host holds just before the result is collected.
  for case_name in missing sha partial replay command bundle; do
    setup "reject-$case_name" 'echo output-line'
    case "$case_name" in
      missing) rule t pre 'tar -cf - result.json' 1 'rm -f .fm-heavy-remote/*/result.json' ;;
      sha) rule t pre 'tar -cf - result.json' 1 'f=$(ls .fm-heavy-remote/*/result.json); jq ".sha=\"0000000000000000000000000000000000000000\"" "$f" > "$f.n" && mv "$f.n" "$f"' ;;
      partial) rule t pre 'tar -cf - result.json' 1 ': > .fm-heavy-remote/*/run.log' ;;
      command) rule t pre 'tar -cf - result.json' 1 'f=$(ls .fm-heavy-remote/*/result.json); jq ".command_sha256=\"0\"" "$f" > "$f.n" && mv "$f.n" "$f"' ;;
      bundle) rule t pre 'tar -cf - result.json' 1 'f=$(ls .fm-heavy-remote/*/result.json); jq ".bundle_sha256=\"0\"" "$f" > "$f.n" && mv "$f.n" "$f"' ;;
      replay) mkdir -p "$CASE/old"; rule t pre 'tar -cf - result.json' 1 'f=$(ls .fm-heavy-remote/*/result.json); jq ".id=\"1-1-1\"" "$f" > "$f.n" && mv "$f.n" "$f"' ;;
    esac
    heavy --remote >/dev/null 2>&1
    expect_code 65 "$?" "a $case_name result"
    expect_record '.outcome == "rejected" and .exit == 65' "$case_name record"
    expect_host_clean "scratch after a rejected $case_name result"
  done
  pass "fm-heavy --remote: a missing, wrong-candidate, wrong-command, partial or replayed result is rejected, never green"
}

test_duplicate_delivery() {
  local stage=$TMP_ROOT/dupstage rdir=.fm-heavy-remote/delivered deliver
  setup dupstart 'echo run >> "$HOME/runs"'
  mkdir -p "$stage"
  git -C "$REPO" bundle create "$stage/src.bundle" HEAD >/dev/null 2>&1
  cp "$RUNNER" "$stage/runner.py"
  jq -n --arg sha "$SHA" --arg bs "$(sha256sum "$stage/src.bundle" | cut -d' ' -f1)" \
    --arg cs "$(printf 'bash\0t/job.sh\0' | sha256sum | cut -d' ' -f1)" \
    '{id: "delivered", sha: $sha, command_sha256: $cs, bundle_sha256: $bs, timeout_s: 20, argv: ["bash", "t/job.sh"]}' > "$stage/manifest.json"
  # The one stream the driver sends, delivered twice: the host's started marker refuses the second.
  deliver="mkdir -p $rdir && tar -xf - -C $rdir && python3 $rdir/runner.py start $rdir"
  [ "$(tar -cf - -C "$stage" runner.py manifest.json src.bundle | PATH="$FAKEBIN:$PATH" FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" ssh fake-mac "$deliver")" = started ] \
    || fail "the first delivery must launch the job"
  HOME="$REMOTE_HOME" python3 "$RUNNER" wait "$REMOTE_HOME/$rdir" 20 >/dev/null
  tar -cf - -C "$stage" runner.py manifest.json src.bundle | PATH="$FAKEBIN:$PATH" FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" ssh fake-mac "$deliver" >/dev/null 2>&1
  expect_code 10 "$?" "a second delivery of one job"
  [ "$(wc -l < "$REMOTE_HOME/runs")" -eq 1 ] || fail "a duplicate delivery must not run the job again"
  HOME="$REMOTE_HOME" python3 "$RUNNER" cleanup "$REMOTE_HOME/$rdir"
  pass "fm-heavy --remote: a duplicate delivery is refused by the host's started marker and never runs twice"
}

# unknown_job <name> <job script> <regex of the calls that drop>: leave one job
# unknown, then restore the connection. JOB is its id, JOB_DIR its local directory.
unknown_job() {
  setup "$1" "$2"
  rule gone drop "$3" -1
  heavy --remote >/dev/null 2>&1; expect_code 75 "$?" "the job that ends unknown"
  rm "$CTL/rules/gone"
  JOB=$(last_record | jq -r .job)
  JOB_DIR=$HOME_FM/state/heavy-remote/$JOB
  OPEN=$HOME_FM/state/heavy-remote/unknown-fake-mac/$JOB.json
  assert_present "$OPEN" "an unknown job must leave a durable local record"
}
new_candidate() {  # <job script body>
  printf '%s\n' "$1" > "$REPO/t/job.sh"
  git -C "$REPO" commit -q -am next
}
remote_starts() { grep -c 'runner.py start' "$CTL/log"; }
wait_for() {  # <file>
  local n=0
  until [ -e "$1" ]; do n=$((n + 1)); [ "$n" -le 100 ] || fail "never appeared: $1"; sleep 0.1; done
}

test_unknown_job_blocks_until_reconciled() {
  local first_sha second_sha
  unknown_job longjob 'echo $$ > "$HOME/job.pid"; until [ -e "$HOME/release" ]; do sleep 0.1; done' 'runner.py (wait|status)'
  first_sha=$SHA
  wait_for "$REMOTE_HOME/job.pid"
  new_candidate "echo ran >> $TMP_ROOT/longjob/second; exit 7"
  second_sha=$(git -C "$REPO" rev-parse HEAD)

  # The connection is back and the first job still runs: no second job beside it.
  heavy --remote >/dev/null 2>&1; expect_code 7 "$?" "a request behind a running unknown job runs locally"
  expect_record '.host == "local" and .fallback == "unknown-job-running" and .slot == 1 and .exit == 7' "still-running fallback"
  [ "$(remote_starts)" -eq 1 ] || fail "no second remote job may start while the first runs: $(cat "$CTL/log")"
  [ "$(ls "$REMOTE_HOME/.fm-heavy-remote")" = "$JOB" ] || fail "only the first job may be on the host"
  pid_alive "$(cat "$REMOTE_HOME/job.pid")" || fail "reconciling must leave a running job alone"
  assert_present "$OPEN" "the record stays open while the job runs"

  # The host cannot be reached: the record stays and the request runs locally.
  rule down drop . -1
  heavy --remote >/dev/null 2>&1; expect_code 7 "$?" "a request with the host gone runs locally"
  expect_record '.host == "local" and .fallback == "unreachable"' "unreachable fallback"
  assert_present "$OPEN" "an unreachable job's record stays open"
  rm "$CTL/rules/down"

  # The first job finishes as a pass. The new candidate still fails: the old pass stands for nothing here.
  : > "$REMOTE_HOME/release"
  wait_for "$REMOTE_HOME/.fm-heavy-remote/$JOB/result.json"
  heavy --remote >/dev/null 2>&1; expect_code 7 "$?" "the new candidate's own failure, not the old job's pass"
  expect_record ".host == \"fake-mac\" and .outcome == \"failed\" and .exit == 7 and .candidate == \"$second_sha\" and .job != \"$JOB\"" "the new job's record"
  [ "$(remote_starts)" -eq 2 ] || fail "the new job starts once the first is reconciled: $(cat "$CTL/log")"
  jq -e --arg job "$JOB" --arg sha "$first_sha" '.job == $job and .candidate == $sha and .outcome == "pass"' "$JOB_DIR/reconciled.json" >/dev/null \
    || fail "the closed record must carry the first job's own outcome: $(cat "$JOB_DIR/reconciled.json")"
  jq -e '.exit_code == 0' "$JOB_DIR/result.json" >/dev/null || fail "the finished job's result is collected"
  assert_absent "$OPEN" "the record closes after reconciliation"
  expect_host_clean "a reconciled job's scratch is removed"
  pass "fm-heavy --remote: an unknown job blocks a second job while it runs, then is collected for its own record and cleaned up"
}

test_unknown_job_other_endings() {
  # Collection drops: the result is not lost and the record stays for the next request.
  unknown_job dropped 'echo run' 'runner.py (wait|status)'
  HOME="$REMOTE_HOME" python3 "$RUNNER" wait "$REMOTE_HOME/.fm-heavy-remote/$JOB" 20 >/dev/null
  new_candidate 'echo next'
  rule collect drop 'tar -cf - result.json' -1
  heavy --remote >/dev/null 2>&1 || fail "a dropped collection falls back to a local run"
  expect_record '.host == "local" and .fallback == "unreachable"' "dropped collection fallback"
  assert_present "$OPEN" "a dropped collection leaves the record open"
  assert_present "$REMOTE_HOME/.fm-heavy-remote/$JOB/result.json" "a dropped collection must keep the result on the host"
  rm "$CTL/rules/collect"
  heavy --remote >/dev/null 2>&1 || fail "the next request reconciles and passes"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "the request after a dropped collection"
  jq -e '.outcome == "pass"' "$JOB_DIR/reconciled.json" >/dev/null || fail "the retried collection closes the record: $(cat "$JOB_DIR/reconciled.json")"
  expect_host_clean "scratch after a retried collection"

  # The result fails its checks: it closes as rejected and scratch still goes.
  unknown_job tampered 'echo run' 'runner.py (wait|status)'
  HOME="$REMOTE_HOME" python3 "$RUNNER" wait "$REMOTE_HOME/.fm-heavy-remote/$JOB" 20 >/dev/null
  new_candidate 'echo next'
  rule t pre 'tar -cf - result.json' 1 'f=$(ls .fm-heavy-remote/*/result.json); jq ".sha=\"0000000000000000000000000000000000000000\"" "$f" > "$f.n" && mv "$f.n" "$f"'
  heavy --remote >/dev/null 2>&1 || fail "a rejected old result does not stop the new job"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "the job after a rejected old result"
  jq -e '.outcome == "rejected"' "$JOB_DIR/reconciled.json" >/dev/null || fail "a bad result closes as rejected: $(cat "$JOB_DIR/reconciled.json")"
  assert_absent "$OPEN" "a rejected result closes the record"
  expect_host_clean "scratch after a rejected old result"

  # The job never reached the host: there is nothing to wait for.
  unknown_job neverarrived 'echo run' 'runner.py (start|status)'
  new_candidate 'echo next'
  heavy --remote >/dev/null 2>&1 || fail "the request after a job that never arrived"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "the job after one that never arrived"
  jq -e '.outcome == "absent"' "$JOB_DIR/reconciled.json" >/dev/null || fail "a job that never arrived closes as absent: $(cat "$JOB_DIR/reconciled.json")"
  assert_absent "$OPEN" "a job that never arrived closes its record"

  # The supervisor died and the job's group lives on, so nothing would ever stop it.
  unknown_job orphan 'sleep 300 & echo $! > "$HOME/child.pid"; echo $PPID > "$HOME/supervisor.pid"; sleep 300' 'runner.py (wait|status)'
  wait_for "$REMOTE_HOME/supervisor.pid"
  kill -9 "$(cat "$REMOTE_HOME/supervisor.pid")"
  wait_gone "$(cat "$REMOTE_HOME/supervisor.pid")" || fail "the supervisor must be gone"
  new_candidate 'echo next'
  heavy --remote >/dev/null 2>&1 || fail "a request behind an orphaned group runs locally"
  expect_record '.host == "local" and .fallback == "unknown-job-running"' "orphaned group fallback"
  [ "$(remote_starts)" -eq 1 ] || fail "no second job may start beside an orphaned group: $(cat "$CTL/log")"
  wait_gone "$(cat "$REMOTE_HOME/child.pid")" || fail "the orphaned group must be stopped"
  heavy --remote >/dev/null 2>&1 || fail "the next request closes the record and runs remotely"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "the job after an orphaned group"
  jq -e '.outcome == "lost"' "$JOB_DIR/reconciled.json" >/dev/null || fail "an orphaned job closes as lost: $(cat "$JOB_DIR/reconciled.json")"
  expect_host_clean "scratch after an orphaned job"
  pass "fm-heavy --remote: dropped collections, bad results, jobs that never arrived and orphaned groups all reconcile safely"
}

test_live_client_with_orphaned_group_blocks_admission() {
  local first job open supervisor child
  setup liveorphan 'echo $$ > "$HOME/job.pid"; echo $PPID > "$HOME/supervisor.pid"; sleep 300'
  printf 'host fake-mac\nproject p\nhost-slots 2\n' > "$HOME_FM/config/heavy-remote"
  rule waiting pre 'runner.py wait' -1 'touch "$FAKE_SSH_CTL/waiting"; n=0; until [ -e "$FAKE_SSH_CTL/release" ]; do n=$((n + 1)); [ "$n" -le 200 ] || exit 1; sleep 0.1; done'
  hold_host
  heavy --remote >"$CASE/first.out" 2>&1 5>&- & first=$!
  wait_for "$REMOTE_HOME/supervisor.pid"
  wait_for "$CTL/waiting"
  open=$(echo "$HOME_FM/state/heavy-remote/unknown-fake-mac/"*.json)
  job=$(basename "$open" .json)
  supervisor=$(cat "$REMOTE_HOME/supervisor.pid")
  child=$(cat "$REMOTE_HOME/job.pid")
  kill -9 "$supervisor"
  wait_gone "$supervisor" || fail "the remote supervisor must be gone"
  new_candidate "echo next >> '$CASE/next-runs'"
  heavy --remote >"$CASE/second.out" 2>&1 5>&- || fail "a request behind a live client's orphan runs locally"
  expect_record '.host == "local" and .fallback == "unknown-job-running"' "live client orphan fallback"
  [ "$(remote_starts)" -eq 1 ] || fail "an orphan cannot release capacity for a third heavy job"
  assert_present "$open" "the live client retains its open record"
  assert_absent "$HOME_FM/state/heavy-remote/$job/reconciled.json" "another client cannot settle the owner's record"
  pid_alive "$(jq -r .client_pid "$open")" || fail "the collection owner must still be alive"
  pid_alive "$child" || fail "admission must leave the orphan for its collection owner"
  touch "$CTL/release"
  wait "$first"; expect_code 70 "$?" "the live owner reports its lost supervisor"
  wait_gone "$child" || fail "the owner cleans its orphaned group"
  assert_absent "$open" "the owner closes its own record"
  ! flock -n "$FM_HEAVY_HOST_LOCK" true || fail "the native job still owns its slot"
  release_host
  [ "$(wc -l < "$CASE/next-runs")" -eq 1 ] || fail "the new candidate runs exactly once"
  pass "fm-heavy: a live collection owner cannot hide orphaned work from admission"
}

test_supervisor_loss_after_reconciliation_blocks_admission() {
  local first job open child probe
  setup admissionrace 'echo $$ > "$HOME/job.pid"; echo $PPID > "$HOME/supervisor.pid"; sleep 300'
  printf 'host fake-mac\nproject p\nhost-slots 2\n' > "$HOME_FM/config/heavy-remote"
  rule waiting pre 'runner.py wait' -1 'touch "$FAKE_SSH_CTL/waiting"; n=0; until [ -e "$FAKE_SSH_CTL/release" ]; do n=$((n + 1)); [ "$n" -le 200 ] || exit 1; sleep 0.1; done'
  hold_host
  heavy --remote >"$CASE/first.out" 2>&1 5>&- & first=$!
  wait_for "$REMOTE_HOME/supervisor.pid"
  wait_for "$CTL/waiting"
  open=$(echo "$HOME_FM/state/heavy-remote/unknown-fake-mac/"*.json)
  job=$(basename "$open" .json)
  child=$(cat "$REMOTE_HOME/job.pid")
  new_candidate "echo next >> '$CASE/next-runs'"
  rule reconciled pre 'runner.py reconcile' 1 'touch "$FAKE_SSH_CTL/reconciled"'
  rule dies pre 'python3 - busy 2' 1 \
    '[ -e "$FAKE_SSH_CTL/reconciled" ] || exit 1; state=$(python3 "$RUNNER_SRC" reconcile .fm-heavy-remote/*); [ "$state" = running ] || exit 1; printf "%s\n" "$state" > "$FAKE_SSH_CTL/snapshot"; pid=$(cat "$HOME/supervisor.pid"); kill -9 "$pid"; n=0; while kill -0 "$pid" 2>/dev/null; do n=$((n + 1)); [ "$n" -le 100 ] || exit 1; sleep 0.1; done'
  heavy --remote >"$CASE/second.out" 2>&1 5>&- || fail "a request whose snapshot preceded supervisor death runs locally"
  [ "$(cat "$CTL/snapshot")" = running ] || fail "reconciliation must see the live supervisor before admission"
  expect_record '.host == "local" and .fallback == "destination-busy"' "slot ownership survives the supervisor"
  [ "$(remote_starts)" -eq 1 ] || fail "a released kernel lock cannot admit a third heavy job"
  pid_alive "$(jq -r .client_pid "$open")" || fail "the original client retains collection ownership"
  pid_alive "$child" || fail "the orphan must still be running when admission is refused"
  assert_absent "$HOME_FM/state/heavy-remote/$job/reconciled.json" "admission cannot collect the live client's result"
  HOME="$REMOTE_HOME" python3 "$RUNNER" busy 2 >/dev/null
  expect_code 12 "$?" "busy counts orphaned work under its slot lock"
  probe=$REMOTE_HOME/.fm-heavy-remote/admission-probe
  mkdir -p "$probe"
  git -C "$REPO" bundle create "$probe/src.bundle" HEAD >/dev/null 2>&1
  jq -n --arg sha "$(git -C "$REPO" rev-parse HEAD)" \
    --arg bs "$(sha256sum "$probe/src.bundle" | cut -d' ' -f1)" \
    --arg cs "$(printf 'bash\0t/job.sh\0' | sha256sum | cut -d' ' -f1)" \
    '{id: "admission-probe", host_slots: 2, sha: $sha, command_sha256: $cs, bundle_sha256: $bs, timeout_s: 20, argv: ["bash", "t/job.sh"]}' > "$probe/manifest.json"
  HOME="$REMOTE_HOME" python3 "$RUNNER" start "$probe" >/dev/null 2>&1
  expect_code 12 "$?" "start independently counts orphaned work under its slot lock"
  assert_absent "$probe/started" "refused admission launches nothing"
  rm -rf "$probe"
  touch "$CTL/release"
  wait "$first"; expect_code 70 "$?" "the original client reports its lost supervisor"
  wait_gone "$child" || fail "the original client cleans its orphaned group"
  assert_absent "$open" "the original client closes its record"
  ! flock -n "$FM_HEAVY_HOST_LOCK" true || fail "the native job keeps its slot"
  heavy --remote >"$CASE/third.out" 2>&1 5>&- || fail "the orphan's slot becomes reusable after collection"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "collected slot ownership is reusable"
  ! flock -n "$FM_HEAVY_HOST_LOCK" true || fail "reusing the remote slot leaves the native job running"
  release_host
  [ "$(wc -l < "$CASE/next-runs")" -eq 2 ] || fail "both new requests run exactly once"
  expect_host_clean "collection leaves no orphan scratch"
  pass "fm-heavy: supervisor loss after reconciliation cannot free an occupied slot for remote admission"
}

test_native_admission_waits_for_an_orphaned_group() {
  local first second native supervisor child n=0
  setup nativeorphan 'echo $$ > "$HOME/first.pid"; until [ -e "$HOME/first-release" ]; do sleep 0.1; done'
  printf 'host fake-mac\nproject p\nhost-slots 2\n' > "$HOME_FM/config/heavy-remote"
  rule waiting pre 'runner.py wait' -1 \
    'mkdir -p "$FAKE_SSH_CTL/waiting"; touch "$FAKE_SSH_CTL/waiting/$$"; n=0; until [ -e "$FAKE_SSH_CTL/release" ]; do n=$((n + 1)); [ "$n" -le 300 ] || exit 1; sleep 0.1; done'
  heavy --remote >"$CASE/first.out" 2>&1 & first=$!
  wait_for "$REMOTE_HOME/first.pid"
  new_candidate "$(cat <<'SH'
echo $$ > "$HOME/second.pid"
echo $PPID > "$HOME/supervisor.pid"
python3 - <<'PY'
import os
import subprocess
import time

child = subprocess.Popen(["sleep", "300"], close_fds=True)
with open(os.path.join(os.environ["HOME"], "child.pid"), "w") as handle:
    handle.write(str(child.pid))
while not os.path.exists(os.path.join(os.environ["HOME"], "leader-release")):
    time.sleep(0.1)
PY
SH
)"
  heavy --remote >"$CASE/second.out" 2>&1 & second=$!
  wait_for "$REMOTE_HOME/child.pid"
  wait_for "$CTL/waiting"
  until [ "$(find "$CTL/waiting" -type f | wc -l)" -eq 2 ]; do
    n=$((n + 1)); [ "$n" -le 100 ] || fail "both collection clients must remain waiting"; sleep 0.1
  done
  supervisor=$(cat "$REMOTE_HOME/supervisor.pid")
  child=$(cat "$REMOTE_HOME/child.pid")
  kill -9 "$supervisor"
  wait_gone "$supervisor" || fail "the supervisor using the original lock must be gone"
  ! flock -n "$FM_HEAVY_HOST_LOCK" true || fail "native admission must stay closed while the orphan runs"
  HOME="$REMOTE_HOME" python3 "$RUNNER" busy 2 >/dev/null
  expect_code 12 "$?" "remote admission also counts the original slot's orphan"
  flock "$FM_HEAVY_HOST_LOCK" sh -c 'touch "$0"; until [ -e "$1" ]; do sleep 0.1; done' \
    "$CASE/native-started" "$CASE/native-release" >"$CASE/native.out" 2>&1 & native=$!
  touch "$REMOTE_HOME/leader-release"
  wait_gone "$(cat "$REMOTE_HOME/second.pid")" || fail "the orphaned group leader must exit"
  pid_alive "$child" || fail "a descendant with closed descriptors must still survive"
  ! flock -n "$FM_HEAVY_HOST_LOCK" true || fail "the original lock must outlive the command group's leader"
  assert_absent "$CASE/native-started" "the native caller cannot start a third job beside the descendant"
  touch "$CTL/release"
  wait "$second"; expect_code 70 "$?" "the original client reports its lost supervisor"
  wait_gone "$child" || fail "collection must stop the orphan's remaining descendant"
  wait_for "$CASE/native-started"
  pid_alive "$(cat "$REMOTE_HOME/first.pid")" || fail "the other remote job must keep running"
  HOME="$REMOTE_HOME" python3 "$RUNNER" busy 2 >/dev/null
  expect_code 12 "$?" "the native job and remaining remote job fill capacity"
  touch "$CASE/native-release"
  wait "$native" || fail "the unchanged native caller finishes normally"
  touch "$REMOTE_HOME/first-release"
  wait "$first" || fail "the other remote job completes normally: $(cat "$CASE/first.out")"
  [ "$(remote_starts)" -eq 2 ] || fail "only the two requested remote jobs may start"
  expect_host_clean "both remote jobs release their scratch and kernel locks"
  flock -n "$FM_HEAVY_HOST_LOCK" true || fail "the original kernel lock becomes reusable"
  pass "fm-heavy: native and remote admission wait for orphaned command descendants after supervisor loss"
}

test_abandoned_result_has_one_collector() {
  local first second collections
  unknown_job collectors 'echo original-output' 'runner.py (wait|status)'
  HOME="$REMOTE_HOME" python3 "$RUNNER" wait "$REMOTE_HOME/.fm-heavy-remote/$JOB" 20 >/dev/null
  new_candidate "echo next >> '$CASE/next-runs'"
  printf 'host fake-mac\nproject p\nhost-slots 2\n' > "$HOME_FM/config/heavy-remote"
  rule collecting pre "cd .fm-heavy-remote/$JOB && tar -cf - result.json" -1 \
    'if mkdir "$FAKE_SSH_CTL/collector" 2>/dev/null; then touch "$FAKE_SSH_CTL/collecting"; n=0; until [ -e "$FAKE_SSH_CTL/release" ]; do n=$((n + 1)); [ "$n" -le 200 ] || exit 1; sleep 0.1; done; fi'
  heavy --remote >"$CASE/first.out" 2>&1 & first=$!
  wait_for "$CTL/collecting"
  heavy --remote >"$CASE/second.out" 2>&1 & second=$!
  wait "$second" || fail "a competing collector runs its new candidate locally: $(cat "$CASE/second.out")"
  touch "$CTL/release"
  wait "$first" || fail "the original collector completes: $(cat "$CASE/first.out")"
  collections=$(grep -c "cd .fm-heavy-remote/$JOB && tar -cf - result.json" "$CTL/log")
  [ "$collections" -eq 1 ] || fail "an abandoned result is fetched only once, got $collections"
  jq -e '.outcome == "pass"' "$JOB_DIR/reconciled.json" >/dev/null || fail "the abandoned pass is preserved"
  [ "$(cat "$JOB_DIR/run.log")" = original-output ] || fail "the collected log retains its verified bytes"
  assert_absent "$OPEN" "the collected record closes once"
  expect_host_clean "the sole collector removes the abandoned scratch"
  [ "$(wc -l < "$CASE/next-runs")" -eq 2 ] || fail "both new candidates run exactly once"
  heavy --remote >"$CASE/third.out" 2>&1 || fail "the next request passes after reconciliation"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "reconciliation releases its lock"
  pass "fm-heavy: concurrent lanes serialize abandoned-result collection and preserve the outcome"
}

test_runner_reconcile_ages_out_a_dead_start() {
  local d
  setup deadstart 'true'
  d=$REMOTE_HOME/.fm-heavy-remote/deadstart
  mkdir -p "$d"
  printf '{"timeout_s": 60}' > "$d/manifest.json"
  : > "$d/started"
  [ "$(HOME="$REMOTE_HOME" python3 "$RUNNER" reconcile "$d")" = preparing ] || fail "a recent start may still be in flight"
  touch -d '2 minutes ago' "$d/started"
  [ "$(HOME="$REMOTE_HOME" python3 "$RUNNER" reconcile "$d")" = lost ] || fail "a start with no owner past the job's timeout is dead"
  pass "fm-heavy-remote-runner: a start that died before recording an owner cannot hold the destination for ever"
}

test_runner_refuses_bad_input() {
  local d
  setup runner 'true'
  d=$REMOTE_HOME/.fm-heavy-remote/bad
  mkdir -p "$d"
  git -C "$REPO" bundle create "$d/src.bundle" HEAD >/dev/null 2>&1
  jq -n --arg sha "$SHA" \
    '{id: "bad", sha: $sha, command_sha256: "x", bundle_sha256: "y", timeout_s: 20, argv: ["true"]}' > "$d/manifest.json"
  HOME="$REMOTE_HOME" python3 "$RUNNER" start "$d" >/dev/null 2>&1; expect_code 10 "$?" "a wrong digest"
  [ ! -e "$d/owner.json" ] && [ ! -e "$d/work" ] || fail "a refused start must launch and check out nothing"
  HOME="$REMOTE_HOME" python3 "$RUNNER" status /tmp >/dev/null 2>&1; expect_code 10 "$?" "a directory outside the job root"
  pass "fm-heavy-remote-runner: digest mismatches and foreign directories are refused before anything runs"
}

test_signalled_wrapper_stops_only_its_job() {
  local pid n=0 foreign
  setup signalled 'sleep 1; sleep 300 & echo $! > "$HOME/child.pid"; sleep 300'
  sleep 300 &
  foreign=$!
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" \
    exec setsid env --default-signal=INT "$HEAVY" --class test --project p --remote -- bash t/job.sh >/dev/null 2>&1) &
  pid=$!
  until [ -s "$REMOTE_HOME/child.pid" ]; do n=$((n + 1)); [ "$n" -le 100 ] || fail "the job never started"; sleep 0.1; done
  kill -TERM -- "-$pid"
  wait "$pid"
  expect_code 143 "$?" "a signalled wrapper"
  expect_record '.outcome == "cancelled" and .exit == 143 and .host == "fake-mac"' "cancelled record"
  wait_gone "$(cat "$REMOTE_HOME/child.pid")" || fail "the job's own process must be stopped"
  pid_alive "$foreign" || fail "a process the job does not own must survive"
  kill "$foreign" 2>/dev/null; wait "$foreign" 2>/dev/null
  expect_host_clean "scratch after a cancelled job"
  pass "fm-heavy --remote: a signalled wrapper stops its own job, records it, and leaves the rest alone"
}

test_cancelled_on_host_is_never_green() {
  local pid
  setup hostcancel 'trap "exit 0" TERM; echo $PPID > "$HOME/supervisor.pid"; sleep 300 & wait'
  heavy --remote >/dev/null 2>&1 &
  pid=$!
  wait_for "$REMOTE_HOME/supervisor.pid"
  kill -TERM "$(cat "$REMOTE_HOME/supervisor.pid")"
  wait "$pid"
  expect_code 143 "$?" "a job stopped on the host whose command traps TERM and exits 0"
  expect_record '.outcome == "cancelled" and .exit == 143 and .host == "fake-mac"' "host-cancelled record"
  expect_host_clean "scratch after a job cancelled on the host"

  # A logout signals the supervisor and the command together, so the command can
  # be gone before the supervisor next looks at it.
  setup hostcancelboth 'trap "exit 0" TERM; echo $$ > "$HOME/command.pid"; echo $PPID > "$HOME/supervisor.pid"; sleep 300 & wait'
  heavy --remote >/dev/null 2>&1 &
  pid=$!
  wait_for "$REMOTE_HOME/supervisor.pid"
  kill -TERM "$(cat "$REMOTE_HOME/supervisor.pid")" "$(cat "$REMOTE_HOME/command.pid")"
  wait "$pid"
  expect_code 143 "$?" "a job whose supervisor and command were stopped together"
  expect_record '.outcome == "cancelled" and .exit == 143 and .host == "fake-mac"' "record of a job stopped together"
  expect_host_clean "scratch after a job stopped together"
  pass "fm-heavy --remote: a job cancelled on the host is never green, even when its command exits 0"
}

test_zombie_group_eperm_keeps_the_result() {
  local shim=$TMP_ROOT/macos-killpg
  mkdir -p "$shim"
  # macOS answers EPERM for a group holding only zombies; Linux does not, so every
  # killpg after the SIGKILL answers that way here.
  cat > "$shim/sitecustomize.py" <<'PY'
import os
import signal

real_killpg = os.killpg
killed = []


def killpg(group, sig):
    if killed:
        raise PermissionError(1, "Operation not permitted")
    real_killpg(group, sig)
    if sig == signal.SIGKILL:
        killed.append(group)


os.killpg = killpg
PY
  setup eperm 'trap "" TERM; sleep 300' 1
  PYTHONPATH=$shim heavy --remote >/dev/null 2>&1
  expect_code 124 "$?" "a job that outlives TERM on a host answering EPERM for its zombie group"
  expect_record '.outcome == "timeout" and .exit == 124' "EPERM timeout record"
  expect_host_clean "scratch after an EPERM group"
  pass "fm-heavy-remote-runner: EPERM from a group of zombies means the group is gone, so the result is still published"
}

test_unterminated_config_last_line() {
  setup lastline 'sleep 4' 
  printf 'host fake-mac\ncommand p -- bash t/job.sh\ntimeout 1' > "$HOME_FM/config/heavy-remote"
  heavy --remote >/dev/null 2>&1; expect_code 124 "$?" "an unterminated timeout line must apply"
  expect_record '.outcome == "timeout"' "timeout from the last config line"
  pass "fm-heavy --remote: the last config line counts without a trailing newline"
}

test_signal_during_eligibility_never_runs_locally() {
  local pid n=0
  setup eligibility "echo ran >> $TMP_ROOT/eligibility/ran"
  rule slowprobe pre '^true$' 1 'sleep 3'
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" \
    exec setsid env --default-signal=INT "$HEAVY" --class test --project p --remote -- bash t/job.sh >/dev/null 2>&1) &
  pid=$!
  until [ -s "$CTL/log" ]; do n=$((n + 1)); [ "$n" -le 100 ] || fail "the probe never started"; sleep 0.1; done
  kill -TERM -- "-$pid"
  wait "$pid"
  expect_code 143 "$?" "a job signalled while its destination is being probed"
  expect_record '.outcome == "cancelled" and .exit == 143 and .fallback == null' "cancelled record"
  [ ! -e "$CASE/ran" ] || fail "a signalled job must not run locally"
  [ "$(wc -l < "$LOG")" -eq 1 ] || fail "one record for the one job: $(cat "$LOG")"
  expect_host_clean "nothing may reach the host"
  pass "fm-heavy --remote: a signal while the destination is probed or the bundle made cancels the job instead of running it locally"
}

test_wrapper_only_signal_never_runs_locally() {
  local pid
  setup wrapperonly "echo ran >> $TMP_ROOT/wrapperonly/ran"
  # The host is down, so the driver falls back; only the wrapper hears the signal.
  rule slowprobe partial '^true$' 1 ': > "$HOME/probing"; sleep 1'
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" \
    exec "$HEAVY" --class test --project p --remote -- bash t/job.sh >/dev/null 2>&1) &
  pid=$!
  wait_for "$REMOTE_HOME/probing"
  kill -TERM "$pid"
  wait "$pid"
  expect_code 143 "$?" "a wrapper signalled while its driver falls back"
  expect_record '.host == "local" and .started_at == null and .exit == null and .slot == null' "record of a job that never ran"
  [ ! -e "$CASE/ran" ] || fail "a signalled job must not run locally"
  [ "$(wc -l < "$LOG")" -eq 1 ] || fail "one record for the one job: $(cat "$LOG")"
  pass "fm-heavy --remote: a signal only the wrapper hears still stops a fallback from running locally"
}

# stop_group_at <file>: start the job in its own process group, then TERM the group
# once <file> appears. Returns the wrapper's status.
stop_group_at() {
  local pid
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" \
    exec setsid env --default-signal=INT "$HEAVY" --class test --project p --remote -- bash t/job.sh >/dev/null 2>&1) &
  pid=$!
  wait_for "$1"
  kill -TERM -- "-$pid"
  wait "$pid"
}
# slow_verification: checking run.log leaves $HOME_FM/verifying and takes 3 seconds.
slow_verification() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *run.log*) : > "$FM_HOME/verifying"; sleep 3 ;; esac' \
    "exec $(command -v sha256sum) \"\$@\"" > "$FAKEBIN/sha256sum"
  chmod +x "$FAKEBIN/sha256sum"
}

test_signal_during_collection_is_cancelled() {
  setup collectsignal 'echo output-line'
  rule slowcollect pre 'tar -cf - result.json' 1 ': > "$HOME/collecting"; sleep 3'
  stop_group_at "$REMOTE_HOME/collecting"
  expect_code 143 "$?" "a job signalled during collection"
  expect_record '.outcome == "cancelled" and .exit == 143 and .host == "fake-mac"' "record of a job signalled during collection"
  expect_host_clean "scratch after a signal during collection"

  # The transfer finished but unpacking is still running when the stop arrives.
  setup extractsignal 'echo output-line'
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *collect.tar*) case "$*" in *-xf*) : > "$FM_HOME/extracting"; sleep 3 ;; esac ;; esac' \
    "exec $(command -v tar) \"\$@\"" > "$FAKEBIN/tar"
  chmod +x "$FAKEBIN/tar"
  stop_group_at "$HOME_FM/extracting"
  expect_code 143 "$?" "a job signalled during result extraction"
  expect_record '.outcome == "cancelled" and .exit == 143' "record of a job signalled during result extraction"

  # Everything is collected and the stop arrives while the result is being checked.
  setup verifysignal 'echo output-line'
  slow_verification
  stop_group_at "$HOME_FM/verifying"
  expect_code 143 "$?" "a job signalled during result verification"
  expect_record '.outcome == "cancelled" and .exit == 143' "record of a job signalled during result verification"
  expect_host_clean "scratch after a signal during result verification"

  # Every check held and the stop arrives while the host is being cleaned.
  setup cleanupsignal 'echo output-line'
  rule slowcleanup pre 'runner.py cleanup' 1 ': > "$HOME/cleaning"; sleep 3'
  stop_group_at "$REMOTE_HOME/cleaning"
  expect_code 143 "$?" "a job signalled during the final cleanup"
  expect_record '.outcome == "cancelled" and .exit == 143' "record of a job signalled during the final cleanup"
  assert_absent "$HOME_FM/state/heavy-remote/unknown-fake-mac/$(last_record | jq -r .job).json" "the record closes after a signal during the final cleanup"
  expect_host_clean "scratch after a signal during the final cleanup"
  pass "fm-heavy --remote: a signal from collection to the final cleanup cancels the job instead of judging its result"
}

test_signal_during_reconcile_keeps_the_record() {
  unknown_job reconcilesignal 'echo run' 'runner.py (wait|status)'
  HOME="$REMOTE_HOME" python3 "$RUNNER" wait "$REMOTE_HOME/.fm-heavy-remote/$JOB" 20 >/dev/null
  new_candidate 'echo next'
  slow_verification
  stop_group_at "$HOME_FM/verifying"
  expect_code 143 "$?" "a request signalled while it checks an earlier job"
  expect_record ".outcome == \"cancelled\" and .exit == 143 and .job != \"$JOB\"" "record of a request signalled during reconciliation"
  assert_present "$OPEN" "the earlier job's record stays open"
  assert_absent "$JOB_DIR/reconciled.json" "a stopped check closes nothing"
  [ "$(remote_starts)" -eq 1 ] || fail "a signalled request must not start a new job: $(cat "$CTL/log")"
  pass "fm-heavy --remote: a signal while an earlier job is checked leaves its record open and starts nothing"
}

test_killed_check_is_never_a_pass() {
  setup killedcheck 'echo output-line'
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *"-e --arg id"*) kill -TERM "$PPID" ;; esac' \
    "exec $(command -v jq) \"\$@\"" > "$FAKEBIN/jq"
  chmod +x "$FAKEBIN/jq"
  heavy --remote >/dev/null 2>&1
  expect_code 65 "$?" "a job whose result check was killed"
  expect_record '.outcome == "rejected" and .exit == 65' "record of a job whose result check was killed"
  pass "fm-heavy --remote: a result check that dies on its own rejects the result"
}

test_dropped_collection_is_reconciled() {
  setup collectdrop 'echo output-line'
  # One dropped collection: the finished job is collected on the next attempt.
  rule c drop 'tar -cf - result.json' 1
  heavy --remote >"$CASE/out" 2>&1 || fail "a finished job must survive one dropped collection: $(cat "$CASE/out")"
  assert_contains "$(cat "$CASE/out")" output-line "the log is relayed"
  expect_record '.outcome == "pass" and .exit == 0' "collected after a reconnect"
  assert_present "$HOME_FM/state/heavy-remote/$(last_record | jq -r .job)/result.json" "the result is kept locally"
  expect_host_clean "scratch is removed only after the collection"

  # The host stays unreachable for the collection: the result is kept there, the job unknown.
  setup collectgone 'echo output-line'
  rule c drop 'tar -cf - result.json' -1
  heavy --remote >/dev/null 2>&1; expect_code 75 "$?" "a result that cannot be fetched"
  expect_record '.outcome == "unknown" and .exit == 75' "unknown record"
  assert_present "$REMOTE_HOME/.fm-heavy-remote/$(last_record | jq -r .job)/result.json" "the only copy of the result is kept on the host"
  assert_present "$HOME_FM/state/heavy-remote/unknown-fake-mac/$(last_record | jq -r .job).json" "the record stays open"
  # Back again: the next request collects it for its own record, cleans up and runs.
  rm "$CTL/rules/c"
  heavy --remote >/dev/null 2>&1 || fail "the next request must reconcile and pass"
  expect_record '.outcome == "pass"' "the next job"
  jq -e '.outcome == "pass"' "$HOME_FM/state/heavy-remote/$(jq -r .job "$LOG" | head -1)/reconciled.json" >/dev/null     || fail "the earlier job's result must be collected for its own record"
  expect_host_clean "the earlier job's scratch after reconciliation"
  pass "fm-heavy --remote: a dropped collection is retried, and an unreachable one keeps the result for reconciliation"
}

test_partial_transfer_is_cleaned() {
  local case_name cut
  # The connection dropped mid-transfer, so what reached the host never started.
  for case_name in junk-bundle truncated-runner no-runner; do
    case "$case_name" in
      junk-bundle) cut='cp "$RUNNER_SRC" "$d/runner.py"; echo junk > "$d/src.bundle"' ;;
      truncated-runner) cut='head -c 100 "$RUNNER_SRC" > "$d/runner.py"' ;;
      no-runner) cut=': > "$d/started"' ;;
    esac
    setup "partial-$case_name" "echo ran >> $TMP_ROOT/partial-$case_name/ran"
    rule p partial 'tar -xf' 1 'd=$(printf "%s" "$CMD" | sed -n "s/.*mkdir -p \([^ ]*\) .*/\1/p"); mkdir -p "$d"; '"$cut"
    heavy --remote >/dev/null 2>&1 || fail "$case_name: a transfer that never started falls back to a local run"
    expect_record '.host == "local" and .fallback == "transfer-failed"' "$case_name: transfer-failed fallback"
    [ "$(wc -l < "$CASE/ran")" -eq 1 ] || fail "$case_name: the fallback runs the command once"
    expect_host_clean "$case_name: the partial job directory must be removed"
    [ -z "$(ls -A "$HOME_FM/state/heavy-remote/unknown-fake-mac")" ] || fail "$case_name: no record is left open"
    heavy --remote >/dev/null 2>&1 || fail "$case_name: the next request must run on the host"
    expect_record '.host == "fake-mac" and .outcome == "pass"' "$case_name: the destination stays usable"
  done
  pass "fm-heavy --remote: a transfer cut short leaves nothing on the host and the destination usable"
}

test_summary_compares_hosts() {
  local log=$TMP_ROOT/summary.jsonl out
  cat > "$log" <<'EOF'
{"task":"a","project":"p","class":"test","requested_at":100,"wait_s":1900,"run_s":25,"exit":0,"peak_memory_bytes":null}
{"task":"b","project":"p","class":"test","requested_at":200,"wait_s":0,"run_s":22,"exit":0,"peak_memory_bytes":null,"host":"fm-mac","prepare_s":6,"collect_s":1,"outcome":"pass"}
{"task":"c","project":"p","class":"test","requested_at":300,"wait_s":0,"run_s":24,"exit":0,"peak_memory_bytes":null,"host":"fm-mac","prepare_s":8,"collect_s":1,"outcome":"pass"}
EOF
  out=$("$SUMMARY" --log "$log") || fail "summary failed"
  printf '%s\n' "$out" | awk '$1 == "p" && $2 == "test" && $3 == 1 && $5 == 1900 && $7 == 25 && $12 == "local" && $13 == "unknown" && $14 == "unknown" { ok = 1 } END { exit !ok }' \
    || fail "the local row is wrong: $out"
  printf '%s\n' "$out" | awk '$1 == "p" && $2 == "test" && $3 == 2 && $5 == 0 && $7 == 23 && $12 == "fm-mac" && $13 == 7 && $14 == 1 { ok = 1 } END { exit !ok }' \
    || fail "the remote row is wrong: $out"
  pass "fm-heavy-summary: local and remote jobs get their own rows with preparation and collection time"
}

# Hold a fake local slot only until the calling test releases its descriptor.
hold_local() {
  exec 4>>"$LOCK"
  flock 4
}
release_local() { exec 4>&-; }

observe_local_queue() {
  # Report entry to the blocking local queue without relying on scheduler timing.
  cat > "$FAKEBIN/flock" <<'SH'
#!/usr/bin/env bash
[ "$*" != 9 ] || touch "$FAKE_SSH_CTL/local-waiting"
SH
  printf 'exec %q "$@"\n' "$(command -v flock)" >> "$FAKEBIN/flock"
  chmod +x "$FAKEBIN/flock"
}

test_scoped_offload() {
  local bad out pid
  setup offload 'echo remote-or-local'
  printf 'host fake-mac\ncommand p -- bash t/job.sh\ncommand other -- bash t/other.sh\noffload\n' > "$HOME_FM/config/heavy-remote"
  heavy >/dev/null 2>&1 || fail "a free local slot stays local"
  expect_record '.host == "local" and .fallback == null' "free local slot"
  hold_local
  heavy >/dev/null 2>&1 || fail "a busy local slot offloads an approved project"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "automatic offload"
  release_local
  heavy --class e2e --remote >/dev/null 2>&1 || fail "approved e2e"
  expect_record '.class == "e2e" and .host == "fake-mac"' "e2e record"
  for bad in 'slots 1' 'offload yes' 'offload\noffload' 'command p --' 'command p -- bash t/job.sh' 'command bash t/job.sh'; do
    printf 'host fake-mac\ncommand p -- bash t/job.sh\noffload\n%b\n' "$bad" > "$HOME_FM/config/heavy-remote"
    heavy >/dev/null 2>&1; expect_code 2 "$?" "malformed scoped config $bad"
  done
  # Unapproved commands stay in the local queue without ever contacting SSH.
  setup otherproject 'echo local'
  observe_local_queue
  printf 'host fake-mac\ncommand other -- bash t/job.sh\noffload\n' > "$HOME_FM/config/heavy-remote"
  hold_local
  heavy >"$CASE/out" 2>&1 4>&- & pid=$!
  wait_for "$CTL/local-waiting"
  [ ! -s "$CTL/log" ] || fail "another project's approval may not contact the host"
  [ ! -s "$LOG" ] || fail "the unapproved job must wait for the local slot"
  release_local
  wait "$pid" || fail "other project local run"
  expect_record '.host == "local" and .fallback == null' "approval scoped to another project"
  # A build's output has to exist here, so a busy local slot never offloads one.
  setup buildstays 'echo local'
  observe_local_queue
  printf 'host fake-mac\ncommand p -- bash t/job.sh\noffload\n' > "$HOME_FM/config/heavy-remote"
  hold_local
  heavy --class build >"$CASE/out" 2>&1 4>&- & pid=$!
  wait_for "$CTL/local-waiting"
  [ ! -s "$CTL/log" ] || fail "a build may not contact the host"
  release_local
  wait "$pid" || fail "local build"
  expect_record '.class == "build" and .host == "local" and .fallback == null' "build stays local"
  # A down host records its fallback when the local slot frees first.
  setup autodown 'echo local'
  printf 'host fake-mac\ncommand p -- bash t/job.sh\noffload\n' > "$HOME_FM/config/heavy-remote"
  rule down drop . -1
  hold_local
  heavy >"$CASE/out" 2>&1 4>&- & pid=$!
  wait_for "$CTL/log"
  release_local
  wait "$pid" || fail "down-host fallback"
  expect_record '.host == "local" and .fallback == "unreachable" and .exit == 0' "automatic unreachable fallback"
  pass "fm-heavy: scoped approvals, automatic offload, classes and malformed refusal"
}

test_bad_config_refuses_only_offload() {
  local err conf conf_body
  setup badconf 'echo local-ran'
  conf=$HOME_FM/config/heavy-remote
  printf 'host fake-mac\ncommand p -- bash t/job.sh\noffload\nsurprise 1\n' > "$conf"
  heavy 2>"$CASE/err" >/dev/null; expect_code 2 "$?" "an approved offload command with a malformed config"
  err=$(cat "$CASE/err")
  assert_contains "$err" "malformed $conf: invalid line 4" "the refusal names the file and the bad line"
  [ ! -s "$LOG" ] || fail "a refused offload must write no record"
  for conf_body in 'host fake-mac\ncommand p -- bash t/job.sh\nsurprise 1\n' \
    'host fake-mac\ncommand other -- bash t/job.sh\noffload\nsurprise 1\n'; do
    # shellcheck disable=SC2059 # the cases are printf formats
    printf "$conf_body" > "$conf"
    heavy >"$CASE/out" 2>"$CASE/err" || fail "a job that would not offload runs locally: $(cat "$CASE/err")"
    assert_contains "$(cat "$CASE/out")" local-ran "the local job ran"
    [ "$(grep -c 'fm-heavy.sh: warning' "$CASE/err")" = 1 ] || fail "one warning expected: $(cat "$CASE/err")"
    assert_contains "$(cat "$CASE/err")" "malformed $conf: invalid line" "the warning names the file and problem"
    expect_record '.host == "local" and .exit == 0 and .slot == 1' "local run beside a malformed config"
  done
  heavy --class build >/dev/null 2>&1 || fail "a build runs locally beside a malformed config"
  if [ "$(id -u)" != 0 ]; then
    printf 'host fake-mac\ncommand p -- bash t/job.sh\noffload\n' > "$conf"
    chmod 000 "$conf"
    heavy >/dev/null 2>"$CASE/err" || fail "an unreadable config must not stop local jobs: $(cat "$CASE/err")"
    err=$(cat "$CASE/err")
    assert_contains "$err" "warning: cannot read $conf" "the warning names the unreadable file"
    case "$err" in *--remote*) fail "the warning must not mention --remote when it was not passed: $err" ;; esac
    heavy --remote >/dev/null 2>"$CASE/err"; expect_code 2 "$?" "--remote with an unreadable config"
    assert_contains "$(cat "$CASE/err")" "cannot read $conf" "the --remote refusal names the unreadable file"
    chmod 600 "$conf"
  fi
  [ ! -s "$CTL/log" ] || fail "a bad config must never reach the host"
  pass "fm-heavy: a bad config refuses only offloading jobs; other jobs warn once and run locally"
}

# Report each check of the remote slot, so a test can see a queued job re-check it.
observe_remote_checks() {
  cat > "$FAKEBIN/flock" <<'SH'
#!/usr/bin/env bash
[ "$*" != "-n 8" ] || touch "$FAKE_SSH_CTL/remote-checked"
SH
  printf 'exec %q "$@"\n' "$(command -v flock)" >> "$FAKEBIN/flock"
  chmod +x "$FAKEBIN/flock"
}
hold_remote() {
  exec 3>>"$LOCK.remote.fake-mac"
  flock 3
}
release_remote() { exec 3>&-; }
# Wait until the job has checked the remote slot again after its first look.
wait_for_recheck() {
  wait_for "$CTL/remote-checked"
  rm "$CTL/remote-checked"
  wait_for "$CTL/remote-checked"
}

test_queued_job_moves_to_the_freed_host() {
  local pid
  setup drain 'echo ran >> "$HOME/runs"'
  observe_remote_checks
  printf 'host fake-mac\ncommand p -- bash t/job.sh\noffload\n' > "$HOME_FM/config/heavy-remote"
  hold_local
  hold_remote
  heavy >"$CASE/out" 2>&1 3>&- 4>&- & pid=$!
  wait_for_recheck
  [ ! -s "$LOG" ] || fail "the job must still be queued: $(cat "$LOG")"
  release_remote
  wait_for "$LOG"
  wait "$pid" || fail "a queued job must pass on the freed host: $(cat "$CASE/out")"
  release_local
  expect_record '.host == "fake-mac" and .outcome == "pass" and .fallback == null and .wait_s >= 0' "drained job"
  [ "$(wc -l < "$REMOTE_HOME/runs")" -eq 1 ] || fail "the moved job runs once"

  # A host that was unreachable at admission is tried again while the job queues.
  setup recovered 'echo ran >> "$HOME/runs"'
  printf 'host fake-mac\ncommand p -- bash t/job.sh\noffload\n' > "$HOME_FM/config/heavy-remote"
  rule blip drop '^true$' 1
  hold_local
  FM_HEAVY_REMOTE_RECHECK=0 heavy >"$CASE/out" 2>&1 3>&- 4>&- & pid=$!
  wait_for "$LOG"
  wait "$pid" || fail "a recovered host must take the queued job: $(cat "$CASE/out")"
  release_local
  expect_record '.host == "fake-mac" and .outcome == "pass" and .fallback == null' "recovered host"

  # Dirty work can also leave the local queue through automatic offload.
  setup stilldirty 'test -f untracked-change'
  printf 'host fake-mac\ncommand p -- bash t/job.sh\noffload\n' > "$HOME_FM/config/heavy-remote"
  echo dirty > "$REPO/untracked-change"
  hold_local
  heavy >"$CASE/out" 2>&1 3>&- 4>&- & pid=$!
  wait_for "$LOG"
  wait "$pid" || fail "dirty tree offload: $(cat "$CASE/out")"
  release_local
  expect_record '.host == "fake-mac" and .snapshot == true and .outcome == "pass"' "dirty tree offloads"
  pass "fm-heavy: queued approved jobs, including dirty work, move to the free host"
}

test_queued_job_signal_runs_nowhere() {
  setup queuedstop "echo ran >> $TMP_ROOT/queuedstop/ran"
  observe_remote_checks
  hold_local
  hold_remote
  stop_group_at "$CTL/remote-checked"
  expect_code 143 "$?" "a job signalled while checking both queues"
  release_remote
  release_local
  expect_record '.host == "local" and .started_at == null and .exit == null' "queued record"
  [ ! -e "$CASE/ran" ] || fail "a signalled job must not run"
  [ ! -s "$CTL/log" ] || fail "a signalled job must not reach the host"
  pass "fm-heavy: a signal while a job checks both queues stops it before it runs anywhere"
}

make_node_project() {
  # Local fallback is observable and does not need this fixture's host-only modules.
  { printf '%s\n' 'if [ "$HOME" != "$FAKE_SSH_HOME" ]; then echo local >> "$FAKE_SSH_CTL/local-runs"; exit 0; fi'; cat "$REPO/t/job.sh"; } > "$CASE/job"
  mv "$CASE/job" "$REPO/t/job.sh"
  cat > "$REPO/package.json" <<'JSON'
{"engines":{"node":">=20 <23","pnpm":"^9.0.0"},"packageManager":"pnpm@9.1.0","scripts":{"e2e":"playwright test"}}
JSON
  printf 'lockfileVersion: 9\n' > "$REPO/pnpm-lock.yaml"
  printf '22\n' > "$REPO/.nvmrc"
  cat > "$FAKEBIN/node" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_NODE_MISSING:-}" != 1 ] || exit 127
echo "${FAKE_NODE_VERSION:-v22.1.0}"
SH
  cat > "$FAKEBIN/pnpm" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_PNPM_MISSING:-}" != 1 ] || exit 127
if [ "$1" = --version ]; then echo "${FAKE_MANAGER_VERSION:-9.1.0}"; exit; fi
printf '%s\n' "$*" >> "$HOME/install.log"
[ "${FAKE_INSTALL_FAIL:-}" != 1 ] || exit 42
[ "${FAKE_INSTALL_HANG:-}" != 1 ] || sleep 300
if [ "$1" = install ] || [ "$1" = ci ]; then mkdir -p node_modules; echo ready > node_modules/proof; fi
SH
  chmod +x "$FAKEBIN/node" "$FAKEBIN/pnpm"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m dependencies
}

test_dependency_cache_and_failures() {
  local out
  setup dependencies 'test -f node_modules/proof && echo tested >> "$HOME/tested"'
  make_node_project
  heavy --remote >"$CASE/out" 2>&1 || fail "first dependency install: $(cat "$CASE/out")"
  heavy --remote >/dev/null 2>&1 || fail "cached dependency install"
  [ "$(wc -l < "$REMOTE_HOME/install.log")" -eq 1 ] || fail "unchanged lockfile must reuse installed dependencies"
  [ "$(wc -l < "$REMOTE_HOME/tested")" -eq 2 ] || fail "both candidates must run with modules"
  echo '# changed' >> "$REPO/pnpm-lock.yaml"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m lockchange
  heavy --remote >/dev/null 2>&1 || fail "changed lockfile install"
  [ "$(wc -l < "$REMOTE_HOME/install.log")" -eq 2 ] || fail "changed lockfile must reinstall"
  FAKE_NODE_MISSING=1 heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "missing runtime"
  assert_grep 'missing runtime node' "$CASE/out" "missing runtime reason"
  FAKE_MANAGER_VERSION=8.0.0 heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "incompatible pnpm"
  FAKE_NODE_VERSION=v18.0.0 heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "incompatible runtime"
  assert_grep 'does not satisfy' "$CASE/out" "version failure reason"
  expect_record '.host == "local" and .fallback == "prepare-failed" and .preparation_step == "runtime"' "runtime failure returns locally"
  echo '# changed again' >> "$REPO/pnpm-lock.yaml"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m failedinstall
  FAKE_INSTALL_FAIL=1 heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "install error"
  expect_record '.host == "local" and .fallback == "prepare-failed" and .preparation_step == "dependencies"' "install failure returns locally"
  assert_grep 'exit status 42' "$(last_record | jq -r .preparation_log)" "retained install failure log"
  [ "$(wc -l < "$CTL/local-runs")" -eq 4 ] || fail "every preparation failure runs locally once"
  [ "$(wc -l < "$REMOTE_HOME/tested")" -eq 3 ] || fail "no candidate runs after runtime/install failure"
  setup preparetimeout 'echo tested >> "$HOME/tested"' 2
  make_node_project
  FAKE_INSTALL_HANG=1 heavy --remote >"$CASE/out" 2>&1 || fail "preparation timeout returns locally"
  expect_record '.host == "local" and .fallback == "prepare-failed" and .preparation_step == "dependencies"' "preparation timeout fallback"
  [ ! -e "$REMOTE_HOME/tested" ] || fail "remote test never starts after preparation timeout"
  [ "$(wc -l < "$CTL/local-runs")" -eq 1 ] || fail "preparation timeout runs locally once"
  pass "fm-heavy: cached dependencies refresh on lockfile change; runtime/install failures and preparation timeout return locally with evidence"
}

# host_tool <bin dir> <tool> <version>: one installed version of a tool on the host.
host_tool() {
  mkdir -p "$1"
  cat > "$1/$2" <<SH
#!/usr/bin/env bash
if [ "\$1" = --version ]; then echo $3; exit; fi
printf '%s\n' "$2 $3 \$*" >> "\$HOME/install.log"
mkdir -p node_modules; echo ready > node_modules/proof
SH
  chmod +x "$1/$2"
}

test_each_project_runs_on_its_pinned_runtimes() {
  local out
  setup runtimes 'test -f node_modules/proof && node --version && pnpm --version'
  make_node_project
  host_tool "$REMOTE_HOME/.nvm/versions/node/v22.4.0/bin" node v22.4.0
  host_tool "$REMOTE_HOME/.nvm/versions/node/v24.9.0/bin" node v24.9.0
  host_tool "$REMOTE_HOME/.nvm/versions/node/v24.10.0/bin" node v24.10.0
  host_tool "$REMOTE_HOME/.fm-heavy-remote/runtimes/pnpm/9.2.0/bin" pnpm 9.2.0
  # This project's pins are the host's defaults.
  out=$(heavy --remote 2>&1) || fail "default runtimes: $out"
  assert_contains "$out" "v22.1.0" "the SSH PATH node meets this project's pin"
  # The same host, pinned elsewhere: neither default can run this one.
  printf '{"engines":{"node":">=24.0.0"},"packageManager":"pnpm@9.2.0"}\n' > "$REPO/package.json"
  printf '24\n' > "$REPO/.nvmrc"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m pins
  out=$(heavy --remote 2>&1) || fail "pinned runtimes: $out"
  assert_contains "$out" "v24.10.0" "the newest installed node meeting the pins runs the job"
  assert_contains "$out" "9.2.0" "the pinned pnpm runs the job"
  grep -F 'pnpm 9.2.0 install' "$REMOTE_HOME/install.log" >/dev/null || fail "the pinned pnpm installs dependencies"
  printf '{"engines":{"node":">=26.0.0"},"packageManager":"pnpm@9.2.0"}\n' > "$REPO/package.json"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m missingnode
  heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "a pinned node that is not installed"
  assert_grep 'does not satisfy >=26.0.0' "$CASE/out" "the refusal names the node pin"
  printf '{"packageManager":"pnpm@9.9.0"}\n' > "$REPO/package.json"
  rm "$REPO/.nvmrc"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m missingpnpm
  heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "a pnpm that cannot provide the pin"
  assert_grep 'does not satisfy 9.9.0' "$CASE/out" "the refusal names the pnpm pin"
  # A real pnpm reports the pin once it has fetched that version for itself.
  out=$(FAKE_MANAGER_VERSION=9.9.0 heavy --remote 2>&1) || fail "self-fetched pnpm: $out"
  assert_contains "$out" "9.9.0" "a pnpm providing its own pin runs the job"
  rm -rf "$REMOTE_HOME/.fm-heavy-remote/runtimes"
  FAKE_PNPM_MISSING=1 heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "no pnpm reachable"
  assert_grep 'missing runtime pnpm' "$CASE/out" "the refusal says no pnpm was found"
  expect_record '.host == "local" and .fallback == "prepare-failed"' "a missing runtime returns locally"
  pass "fm-heavy: each project runs on the node and pnpm it pins; a missing node or no pnpm is a clear refusal"
}

test_project_without_dependencies_needs_no_lockfile() {
  local out
  setup nodeps 'node --version'
  make_node_project
  host_tool "$REMOTE_HOME/.nvm/versions/node/v24.7.0/bin" node v24.7.0
  printf '{"engines":{"node":">=24.7"},"scripts":{"test":"node --test"}}\n' > "$REPO/package.json"
  git -C "$REPO" rm -q pnpm-lock.yaml .nvmrc
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m nodeps
  out=$(heavy --remote 2>&1) || fail "a project with nothing to lock must run: $out"
  assert_contains "$out" "v24.7.0" "the job still runs on the project's pinned node"
  [ ! -e "$REMOTE_HOME/install.log" ] || fail "nothing may be installed: $(cat "$REMOTE_HOME/install.log")"
  printf '{"engines":{"node":">=26.0.0"}}\n' > "$REPO/package.json"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m missingnode
  heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "a pinned node that is not installed"
  assert_grep 'does not satisfy >=26.0.0' "$CASE/out" "the refusal names the node pin"
  printf '{"devDependencies":{"left-pad":"1.3.0"}}\n' > "$REPO/package.json"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m unlocked
  heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "declared dependencies with no lockfile"
  assert_grep 'no supported lockfile' "$CASE/out" "the refusal names the lockfile"
  pass "fm-heavy: a project with no dependencies needs no lockfile; a pinned node and declared dependencies still refuse"
}

test_command_missing_on_host_cannot_run() {
  setup nocommand 'echo unused'
  printf 'host fake-mac\ncommand p -- fm-no-such-command\n' > "$HOME_FM/config/heavy-remote"
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" \
    "$HEAVY" --class test --project p --remote -- fm-no-such-command) >"$CASE/out" 2>&1
  expect_code 127 "$?" "an approved command the host does not have"
  assert_grep 'cannot run fm-no-such-command' "$CASE/out" "the failure names the command"
  expect_record '.host == "fake-mac" and .outcome == "failed" and .exit == 127' "cannot-run record"
  pass "fm-heavy --remote: a command missing on the host is a cannot-run failure, not a preparation failure"
}

test_npm_dependency_cache() {
  setup npmdeps 'test -f node_modules/proof'
  make_node_project
  mv "$FAKEBIN/pnpm" "$FAKEBIN/npm"
  rm "$REPO/pnpm-lock.yaml"
  printf '{}\n' > "$REPO/package-lock.json"
  printf '{"engines":{"node":"^22.0.0","npm":">=9"},"packageManager":"npm@9.1.0"}\n' > "$REPO/package.json"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m npm
  heavy --remote >"$CASE/out" 2>&1 || fail "npm dependencies: $(cat "$CASE/out")"
  heavy --remote >/dev/null 2>&1 || fail "npm cached dependencies"
  grep -Fx 'ci --include=dev' "$REMOTE_HOME/install.log" >/dev/null || fail "npm uses locked dev dependencies"
  [ "$(wc -l < "$REMOTE_HOME/install.log")" -eq 1 ] || fail "npm lock cache must avoid reinstall"
  printf '24\n' > "$REPO/.nvmrc"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m nvmrc
  heavy --remote >"$CASE/out" 2>&1; expect_code 0 "$?" "nvmrc mismatch"
  assert_grep 'does not satisfy ^22.0.0 and 24' "$CASE/out" "nvmrc selects runtime"
  pass "fm-heavy: npm lock caching and nvmrc compatibility are enforced"
}

test_e2e_browser_preparation() {
  setup browsers 'echo ran'
  make_node_project
  printf 'host fake-mac\ncommand p -- pnpm run e2e\n' > "$HOME_FM/config/heavy-remote"
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" \
    "$HEAVY" --class e2e --project p --remote -- pnpm run e2e) >"$CASE/out" 2>&1 || fail "e2e preparation: $(cat "$CASE/out")"
  grep -Fx 'exec playwright install' "$REMOTE_HOME/install.log" >/dev/null || fail "e2e script installs browsers"
  [ "$(tail -1 "$REMOTE_HOME/install.log")" = 'run e2e' ] || fail "browsers must be installed before the approved command"
  pass "fm-heavy: approved Playwright e2e commands prepare browsers before execution"
}

test_project_approvals() {
  local bad pid
  setup projectwide 'echo ran >> "$HOME/runs"'
  printf 'host fake-mac\nproject p\n' > "$HOME_FM/config/heavy-remote"
  heavy --remote >/dev/null 2>&1 || fail "a project approval covers the project's test command"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "project approval"
  printf 'host fake-mac\nproject *\n' > "$HOME_FM/config/heavy-remote"
  heavy --class e2e --remote >/dev/null 2>&1 || fail "an every-project approval covers e2e"
  expect_record '.class == "e2e" and .host == "fake-mac" and .outcome == "pass"' "every-project approval"
  printf 'host fake-mac\nproject other\n' > "$HOME_FM/config/heavy-remote"
  heavy --remote >/dev/null 2>&1; expect_code 2 "$?" "another project's approval"
  printf 'host fake-mac\nproject *\n' > "$HOME_FM/config/heavy-remote"
  heavy --project '' --remote >/dev/null 2>&1; expect_code 2 "$?" "a job with no project never leaves"
  [ "$(wc -l < "$REMOTE_HOME/runs")" -eq 2 ] || fail "only the approved jobs ran on the host"
  for bad in 'project p\nproject p' 'project a b' 'project' 'nofile 65536' 'nofile 8192' 'image bad image!' 'image a\nimage b' \
    'image i\nproject q service=nope' 'service db pg 5432 1g\nproject q service=db' 'project q bogus=1' 'project q env=nokey' \
    'image i\nservice a x 5432 1g\nservice b y 5432 1g\nproject q service=a service=b' 'service DB pg 5432 1g' \
    'service db pg port 1g' 'service db pg 5432 1t' 'service db pg 5432 1g\nservice db pg 5433 1g' 'service db pg 5432 1g bad'; do
    printf 'host fake-mac\nproject p\noffload\n%b\n' "$bad" > "$HOME_FM/config/heavy-remote"
    heavy >/dev/null 2>&1; expect_code 2 "$?" "malformed approval $bad"
  done
  # Builds stay here even under an every-project approval.
  setup buildstays2 'echo local'
  observe_local_queue
  printf 'host fake-mac\nproject *\noffload\n' > "$HOME_FM/config/heavy-remote"
  hold_local
  heavy --class build >"$CASE/out" 2>&1 4>&- & pid=$!
  wait_for "$CTL/local-waiting"
  [ ! -s "$CTL/log" ] || fail "a build may not contact the host"
  release_local
  wait "$pid" || fail "local build"
  expect_record '.class == "build" and .host == "local"' "build stays local under project *"
  # A no-mistakes drive call needs this machine's gate, so a project approval never offloads it.
  setup drivestays 'echo local'
  observe_local_queue
  printf '#!/bin/sh\necho drove >> "$FAKE_SSH_CTL/drives"\n' > "$FAKEBIN/no-mistakes"
  chmod +x "$FAKEBIN/no-mistakes"
  printf 'host fake-mac\nproject *\noffload\n' > "$HOME_FM/config/heavy-remote"
  hold_local
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" FAKE_SSH_CTL="$CTL" \
    FAKE_SSH_HOME="$REMOTE_HOME" RUNNER_SRC="$RUNNER" "$HEAVY" --class test --task t --project p -- no-mistakes axi run) \
    >"$CASE/out" 2>&1 3>&- 4>&- & pid=$!
  wait_for "$CTL/local-waiting"
  [ ! -s "$CTL/log" ] || fail "a drive call may not contact the host"
  release_local
  wait "$pid" || fail "local drive call: $(cat "$CASE/out")"
  expect_record '.cmd == "no-mistakes" and .host == "local" and .fallback == null' "drive call stays local under project *"
  [ "$(cat "$CTL/drives")" = drove ] || fail "the drive call ran here once"
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" FAKE_SSH_CTL="$CTL" \
    FAKE_SSH_HOME="$REMOTE_HOME" RUNNER_SRC="$RUNNER" "$HEAVY" --class test --task t --project p --remote -- no-mistakes axi run) \
    >/dev/null 2>&1 3>&- 4>&-
  expect_code 2 "$?" "a project approval does not cover --remote drive calls"
  pass "fm-heavy: project and every-project approvals cover tests and e2e only, with a project, never drive calls"
}

hold_host() { exec 5>>"$FM_HEAVY_HOST_LOCK"; flock 5; }
release_host() { exec 5>&-; }

test_host_jobs_go_first_and_none_is_stopped() {
  local pid dead
  setup hostfirst 'echo ran >> "$HOME/runs"'
  printf 'host fake-mac\nproject p\n' > "$HOME_FM/config/heavy-remote"
  FM_HEAVY_HOST_LOCK=$FM_HEAVY_HOST_LOCK python3 "$RUNNER" busy >/dev/null; expect_code 0 "$?" "a free host slot"
  hold_host
  FM_HEAVY_HOST_LOCK=$FM_HEAVY_HOST_LOCK python3 "$RUNNER" busy >/dev/null; expect_code 12 "$?" "a held host slot"
  heavy --remote >/dev/null 2>&1 5>&- || fail "a busy host leaves the job here"
  expect_record '.host == "local" and .fallback == "destination-busy"' "held host slot"
  release_host
  # A host job waiting for its own slot goes before a sent job.
  mkdir "$FM_HEAVY_HOST_LOCK.waiting"
  : > "$FM_HEAVY_HOST_LOCK.waiting/$$"
  heavy --remote >/dev/null 2>&1 || fail "an awaited host slot leaves the job here"
  expect_record '.host == "local" and .fallback == "destination-busy"' "awaited host slot"
  rm "$FM_HEAVY_HOST_LOCK.waiting/$$"
  sh -c 'exit 0' & dead=$!; wait "$dead"
  : > "$FM_HEAVY_HOST_LOCK.waiting/$dead"
  heavy --remote >/dev/null 2>&1 || fail "a dead waiter does not hold the host"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "dead waiter ignored"
  [ "$(wc -l < "$REMOTE_HOME/runs")" -eq 1 ] || fail "busy jobs never ran on the host"
  # A sent job holds the host slot to the end; a host job then waits instead of stopping it.
  setup nopreempt 'touch "$HOME/started"; sleep 1; echo ran >> "$HOME/runs"'
  printf 'host fake-mac\nproject p\n' > "$HOME_FM/config/heavy-remote"
  heavy --remote >"$CASE/out" 2>&1 & pid=$!
  wait_for "$REMOTE_HOME/started"
  ! flock -n "$FM_HEAVY_HOST_LOCK" true || fail "a running sent job holds the host slot"
  flock "$FM_HEAVY_HOST_LOCK" true
  [ "$(wc -l < "$REMOTE_HOME/runs" 2>/dev/null)" = 1 ] || fail "the host job waited for the sent job to finish"
  wait "$pid" || fail "the sent job passes: $(cat "$CASE/out")"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "sent job not preempted"
  # A running host job is never stopped for a sent one.
  ( flock "$FM_HEAVY_HOST_LOCK" sh -c 'sleep 1; echo done > "$0"' "$CASE/hostjob" ) & pid=$!
  until ! flock -n "$FM_HEAVY_HOST_LOCK" true; do sleep 0.1; done
  heavy --remote >/dev/null 2>&1 || fail "a sent job beside a running host job"
  expect_record '.host == "local" and .fallback == "destination-busy"' "running host job keeps the slot"
  wait "$pid" || fail "the host job finishes"
  [ "$(cat "$CASE/hostjob")" = "done" ] || fail "the host job ran to its end"
  pass "fm-heavy: the host's own jobs go first, and no running job is stopped for another"
}

test_two_host_slots() {
  local pid first second n bad
  setup twoslots 'touch "$HOME/started"; while [ ! -e "$HOME/release" ]; do sleep 0.1; done'
  printf 'host fake-mac\nproject p\nhost-slots 2\n' > "$HOME_FM/config/heavy-remote"
  hold_host
  heavy --remote >"$CASE/out" 2>&1 5>&- & first=$!
  wait_for "$REMOTE_HOME/started"
  python3 "$RUNNER" busy 2 >/dev/null
  expect_code 12 "$?" "an own job and a sent job fill two slots"
  touch "$REMOTE_HOME/release"
  wait "$first" || fail "a sent job runs beside the unchanged own lock: $(cat "$CASE/out")"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "two-slot admission"
  # A queued raw flock user has no Firstmate marker, and must still go first.
  rm "$REMOTE_HOME/started" "$REMOTE_HOME/release"
  flock "$FM_HEAVY_HOST_LOCK" sh -c 'echo own > "$0"' "$CASE/own" 5>&- & pid=$!
  n=0
  until [ "$(ps -o comm= -p "$pid" | xargs basename)" = flock ]; do
    n=$((n + 1)); [ "$n" -le 50 ] || fail "native waiter never reached flock"; sleep 0.1
  done
  python3 "$RUNNER" busy 2 >/dev/null
  expect_code 12 "$?" "a native flock waiter prevents admission into the extra slot"
  [ ! -e "$CASE/own" ] || fail "the waiting own job has not acquired its lock"
  release_host
  wait "$pid" || fail "the native job completes after release"
  [ "$(cat "$CASE/own")" = own ] || fail "the native job was never stopped"
  hold_host
  ( exec 6>>"$FM_HEAVY_HOST_LOCK"; exec flock 6 ) 5>&- & pid=$!
  n=0
  until [ "$(ps -o comm= -p "$pid" | xargs basename)" = flock ]; do
    n=$((n + 1)); [ "$n" -le 50 ] || fail "descriptor waiter never reached flock"; sleep 0.1
  done
  python3 "$RUNNER" busy 2 >/dev/null
  expect_code 12 "$?" "descriptor-form native flock also reserves the extra slot"
  release_host
  wait "$pid" || fail "the descriptor waiter finishes after release"
  # Firstmate's explicit waiter markers also reserve capacity with two slots.
  mkdir -p "$FM_HEAVY_HOST_LOCK.waiting"
  : > "$FM_HEAVY_HOST_LOCK.waiting/$$"
  python3 "$RUNNER" busy 2 >/dev/null
  expect_code 12 "$?" "a marked own waiter prevents two-slot admission"
  rm "$FM_HEAVY_HOST_LOCK.waiting/$$"
  # Priority is checked again at start, after a successful busy probe.
  setup twostart 'exit 0'
  printf 'host fake-mac\nproject p\nhost-slots 2\n' > "$HOME_FM/config/heavy-remote"
  rule ownwait pre 'runner.py start' 1 "mkdir -p \"\$FM_HEAVY_HOST_LOCK.waiting\"; touch \"\$FM_HEAVY_HOST_LOCK.waiting/$$\""
  heavy --remote >"$CASE/out" 2>&1 || fail "a new own waiter leaves the sent job local: $(cat "$CASE/out")"
  expect_record '.host == "local" and .fallback == "destination-busy"' "priority rechecked at start"
  # Two drivers from the same client can run remotely, with no mistaken
  # reconciliation of the other live driver's completion record.
  setup twosent 'mkdir -p "$HOME/started"; touch "$HOME/started/$$"; while [ ! -e "$HOME/release" ]; do sleep 0.1; done'
  printf 'host fake-mac\nproject p\nhost-slots 2\n' > "$HOME_FM/config/heavy-remote"
  heavy --remote >"$CASE/first.out" 2>&1 & first=$!
  wait_for "$REMOTE_HOME/started"
  heavy --remote >"$CASE/second.out" 2>&1 & second=$!
  n=0
  until [ "$(find "$REMOTE_HOME/started" -type f | wc -l)" -eq 2 ]; do
    n=$((n + 1)); [ "$n" -le 200 ] || fail "two sent jobs never overlapped: $(cat "$CASE/first.out" "$CASE/second.out")"; sleep 0.1
  done
  python3 "$RUNNER" busy 2 >/dev/null
  expect_code 12 "$?" "two sent jobs refuse a third"
  touch "$REMOTE_HOME/release"
  wait "$first" || fail "first remote driver: $(cat "$CASE/first.out")"
  wait "$second" || fail "second remote driver: $(cat "$CASE/second.out")"
  [ "$(jq -s '[.[] | select(.host == "fake-mac" and .outcome == "pass")] | length' "$LOG")" -eq 2 ] || fail "both sent jobs completed remotely"
  # Explicit one-slot settings retain the default's held-lock refusal.
  hold_host
  python3 "$RUNNER" busy 1 >/dev/null
  expect_code 12 "$?" "explicit one slot retains legacy admission"
  release_host
  for bad in '0' '-1' '02' '65' '2 extra' '2\nhost-slots 2'; do
    printf 'host fake-mac\nproject p\nhost-slots %b\n' "$bad" > "$HOME_FM/config/heavy-remote"
    heavy --remote >/dev/null 2>&1
    expect_code 2 "$?" "invalid host-slots: $bad"
  done
  pass "fm-heavy: two host slots include native jobs, preserve native priority and admit two sent jobs"
}

make_fake_docker() {  # <fakebin>: runs the container's command on the host, logging its argv
  cat > "$1/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SSH_CTL/docker.log"
case "$1 ${2:-}" in
  "info "*) echo "${FAKE_DOCKER_MEM:-20928077824}"; exit 0 ;;
  "rm -f") [ ! -e "$FAKE_SSH_CTL/$3.pid" ] || { kill "$(cat "$FAKE_SSH_CTL/$3.pid")"; rm -f "$FAKE_SSH_CTL/$3.pid"; }; exit 0 ;;
  "run -d")  # a service: a detached listener on its declared PORT, owned by "the daemon"
    shift 2
    while [ "$#" -gt 1 ]; do case "$1" in --name) name=$2; shift 2 ;; -e) export "${2?}"; shift 2 ;; *) shift 2 ;; esac; done
    setsid python3 -c 'import os, socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(os.environ["PORT"]))); s.listen(); time.sleep(600)' </dev/null >/dev/null 2>&1 &
    echo $! > "$FAKE_SSH_CTL/$name.pid"
    exit 0 ;;
esac
[ "$1" = run ] || exit 0
shift
dir=.
ulimit -Sn 256
while [ "$#" -gt 0 ]; do
  case "$1" in --rm|--init) shift ;; --ulimit) limits=${2#nofile=}; ulimit -Sn "${limits%%:*}"; ulimit -Hn "${limits##*:}"; shift 2 ;; -w) dir=$2; shift 2 ;; -e) export "${2?}"; shift 2 ;; -*) shift 2 ;; *) break ;; esac
done
shift
cd "$dir" && exec "$@"
SH
  chmod +x "$1/docker"
}

test_image_runs_in_a_container() {
  local id
  setup container 'echo ran >> "$HOME/runs"; { printf "%s\n" "$PLAYWRIGHT_BROWSERS_PATH" "$npm_config_store_dir" "$npm_config_cache"; pnpm store path; } | grep . > "$HOME/tool-caches"'
  make_fake_docker "$FAKEBIN"
  # pnpm 11 resolves its store from pnpm_config_store_dir only; npm_config_store_dir serves older pinned pnpm.
  cat > "$FAKEBIN/pnpm" <<'SH'
#!/usr/bin/env bash
[ "$*" = "store path" ] && echo "${pnpm_config_store_dir:-$HOME/.local/share/pnpm/store}/v11"
SH
  chmod +x "$FAKEBIN/pnpm"
  printf 'host fake-mac\nproject p\nimage fm-heavy-linux:1\n' > "$HOME_FM/config/heavy-remote"
  heavy --remote >"$CASE/out" 2>&1 || fail "a job in the image: $(cat "$CASE/out")"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "container job"
  id=$(grep -o 'fm-heavy-[^ ]*' "$CTL/docker.log" | head -1)
  grep -E "^run --rm --init --name $id --memory 6g --memory-swap 6g .* fm-heavy-linux:1 python3 " "$CTL/docker.log" >/dev/null \
    || fail "docker run argv: $(cat "$CTL/docker.log")"
  grep -F "/.fm-heavy-remote/linux/runtimes:" "$CTL/docker.log" >/dev/null || fail "linux runtimes are mounted"
  grep -F -- "-v $REMOTE_HOME/.fm-heavy-remote/linux/cache:$REMOTE_HOME/.fm-heavy-remote/cache " "$CTL/docker.log" >/dev/null \
    || fail "linux cache is mounted: $(cat "$CTL/docker.log")"
  [ "$(wc -l < "$REMOTE_HOME/tool-caches")" -eq 4 ] || fail "four tool cache paths: $(cat "$REMOTE_HOME/tool-caches")"
  while read -r dir; do
    case "$dir" in "$REMOTE_HOME/.fm-heavy-remote/cache/"?*) ;; *) fail "tool cache outside the mounted cache: $dir" ;; esac
  done < "$REMOTE_HOME/tool-caches"
  grep -Fx "rm -f $id" "$CTL/docker.log" >/dev/null || fail "the container is removed: $(cat "$CTL/docker.log")"
  [ "$(ls "$REMOTE_HOME/.fm-heavy-remote")" = linux ] || fail "only the linux cache remains: $(ls "$REMOTE_HOME/.fm-heavy-remote")"
  pass "fm-heavy: an image line runs the job inside that container and removes it"
}

test_container_many_file_install() {
  setup manyfiles 'test -f node_modules/proof && test "$(ulimit -Sn)" = 65536 && test "$(ulimit -Hn)" = 65536'
  make_node_project
  make_fake_docker "$FAKEBIN"
  # Exercise real simultaneous descriptors, as a parallel pnpm install does.
  python3 - "$FAKEBIN/pnpm" <<'PYTHON'
import sys
from pathlib import Path
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('if [ "$1" = install ]', """python3 - <<'OPENFILES'
files = [open('/dev/null') for _ in range(4096)]
OPENFILES
[ "$?" = 0 ] || exit 42
if [ "$1" = install ]"""))
PYTHON
  printf 'image fm-heavy-linux:2\n' >> "$HOME_FM/config/heavy-remote"
  heavy --remote >"$CASE/out" 2>&1 || fail "many-file install: $(cat "$CASE/out")"
  expect_record '.host == "fake-mac" and .outcome == "pass" and .fallback == null' "many-file install passes on host"
  [ ! -e "$CTL/local-runs" ] || fail "no fallback for many-file install"
  setup command78 'exit 78'
  heavy --remote >/dev/null 2>&1; expect_code 78 "$?" "project command exiting 78"
  expect_record '.host == "fake-mac" and .outcome == "failed" and .fallback == null' "exit 78 after command starts remains failed"
  pass "fm-heavy: fixed container limits permit many-file installs; command exit 78 stays failed"
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# setup_services <name> <job body> [timeout]: a job approved with two services.
setup_services() {
  setup "$1" "$2" "${3:-30}"
  make_fake_docker "$FAKEBIN"
  P1=$(free_port); P2=$(free_port)
  printf '%s\n' 'host fake-mac' 'image fm-heavy-linux:1' "timeout ${3:-30}" \
    "service db postgres:16 $P1 512m PORT=$P1 POSTGRES_DB=t" "service cache redis:7 $P2 256m PORT=$P2" \
    "project p service=db service=cache env=DATABASE_URL=postgres://localhost:$P1/t" > "$HOME_FM/config/heavy-remote"
}

# Every service, the job container and the network are removed by name, and nothing else.
expect_services_removed() {  # <message>
  local id name line pids
  id=$(sed -n 's/^network create //p' "$CTL/docker.log" | head -1)
  [ -n "$id" ] || fail "$1: no network was created: $(cat "$CTL/docker.log")"
  for name in "$id" "$id-cache" "$id-db"; do
    grep -Fx "rm -f $name" "$CTL/docker.log" >/dev/null || fail "$1: $name is not removed: $(cat "$CTL/docker.log")"
  done
  grep -Fx "network rm $id" "$CTL/docker.log" >/dev/null || fail "$1: the network is not removed"
  while read -r line; do
    case "$line" in "rm -f $id"|"rm -f $id-db"|"rm -f $id-cache"|"network rm $id") ;; *) fail "$1: touched something else: $line" ;; esac
  done < <(grep -E '^(rm|network rm|stop|kill|volume|image|system)' "$CTL/docker.log")
  pids=$(cat "$CTL"/*.pid 2>/dev/null)
  [ -z "$pids" ] || fail "$1: a service is still running"
}

test_services_start_with_the_job_and_are_removed() {
  local id pid n=0
  setup_services svcpass 'echo "$DATABASE_URL" > "$HOME/url"'
  heavy --remote >"$CASE/out" 2>&1 || fail "a job with services: $(cat "$CASE/out")"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "services job"
  id=$(sed -n 's/^network create //p' "$CTL/docker.log")
  [ "$(grep -E '^(network create|run )' "$CTL/docker.log" | cut -c1-60 | sed "s/$id/ID/g" | awk '{print $1, $2, $3, $4}')" = \
"network create ID 
run -d --name ID-db
run -d --name ID-cache
run --rm --init --name" ] || fail "services start before the job: $(cat "$CTL/docker.log")"
  grep -Fx "run -d --name $id-db --memory 512m --memory-swap 512m --network $id -e PORT=$P1 -e POSTGRES_DB=t postgres:16" "$CTL/docker.log" >/dev/null \
    || fail "the first service's settings: $(cat "$CTL/docker.log")"
  grep -Fx "run -d --name $id-cache --memory 256m --memory-swap 256m --network container:$id-db -e PORT=$P2 redis:7" "$CTL/docker.log" >/dev/null \
    || fail "a later service shares the first one's network: $(cat "$CTL/docker.log")"
  grep -E "^run --rm --init --name $id --memory 6g --memory-swap 6g --network container:$id-db " "$CTL/docker.log" >/dev/null \
    || fail "the job joins the services' network: $(cat "$CTL/docker.log")"
  [ "$(cat "$REMOTE_HOME/url")" = "postgres://localhost:$P1/t" ] || fail "the job sees its env"
  expect_services_removed "after a pass"

  setup_services svcspaced 'echo "$DATABASE_URL" > "$HOME/url"'
  printf '%b\n' 'host fake-mac' 'image fm-heavy-linux:1' 'timeout 30' \
    "service  db\tpostgres:16   $P1  512m\tPORT=$P1  POSTGRES_DB=t" "service cache redis:7 $P2 256m PORT=$P2" \
    "project p  service=db\tservice=cache   env=DATABASE_URL=postgres://localhost:$P1/t" > "$HOME_FM/config/heavy-remote"
  heavy --remote >"$CASE/out" 2>&1 || fail "a service line with repeated spaces and tabs: $(cat "$CASE/out")"
  expect_record '.host == "fake-mac" and .outcome == "pass"' "a service line with repeated spaces and tabs"
  id=$(sed -n 's/^network create //p' "$CTL/docker.log")
  grep -Fx "run -d --name $id-db --memory 512m --memory-swap 512m --network $id -e PORT=$P1 -e POSTGRES_DB=t postgres:16" "$CTL/docker.log" >/dev/null \
    || fail "a spaced service line keeps its settings: $(cat "$CTL/docker.log")"
  [ "$(cat "$REMOTE_HOME/url")" = "postgres://localhost:$P1/t" ] || fail "the job sees its env with a spaced approval"
  expect_services_removed "after a spaced service line"

  setup_services svcfail 'exit 3'
  heavy --remote >/dev/null 2>&1; expect_code 3 "$?" "a failing job with services"
  expect_record '.outcome == "failed"' "failed services job"
  expect_services_removed "after a failure"

  setup_services svctimeout 'sleep 300' 2
  heavy --remote >/dev/null 2>&1; expect_code 124 "$?" "a timed-out job with services"
  expect_record '.outcome == "timeout"' "timed-out services job"
  expect_services_removed "after a timeout"

  setup_services svccancel 'touch "$HOME/started"; sleep 300'
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" \
    exec setsid env --default-signal=INT "$HEAVY" --class test --project p --remote -- bash t/job.sh >/dev/null 2>&1) &
  pid=$!
  until [ -e "$REMOTE_HOME/started" ]; do n=$((n + 1)); [ "$n" -le 100 ] || fail "the job never started"; sleep 0.1; done
  kill -TERM -- "-$pid"
  wait "$pid"
  expect_code 143 "$?" "a cancelled job with services"
  expect_services_removed "after a cancel"

  setup_services svclost 'sleep 1'
  rule wait drop 'runner.py wait' 1
  heavy --remote >/dev/null 2>&1 || fail "a services job found again after a dropped wait"
  expect_services_removed "after lost-connection reconciliation"

  setup_services svcfit 'echo ran >> "'"$TMP_ROOT"'/svcfit-runs"'
  FAKE_DOCKER_MEM=$((6 << 30)) heavy --remote >/dev/null 2>&1 || fail "a job whose services do not fit runs here"
  expect_record '.host == "local" and .fallback == "services-do-not-fit"' "services-do-not-fit record"
  ! grep -E '^(run|network create)' "$CTL/docker.log" >/dev/null || fail "nothing starts on the host when services do not fit"
  pass "fm-heavy --remote: services start before the job with their settings and are removed on pass, failure, timeout, cancel and reconciliation, whatever the spacing of their lines"
}

# Path callers must select the same approval and remote options as name callers.
test_project_paths() {
  local input
  setup_services pathservices 'echo "$DATABASE_URL" > "$HOME/url"'
  mkdir -p "$HOME_FM/projects"
  ln -s "$REPO" "$HOME_FM/projects/p"
  # Select an approval-specific image, rather than the global default.
  sed -i 's/project p service=/project p image=project-linux:1 service=/' "$HOME_FM/config/heavy-remote"
  for input in "$HOME_FM/projects/p/" "$REPO"; do
    heavy --project "$input" --remote >"$CASE/out" 2>&1 || fail "approved clone path: $(cat "$CASE/out")"
    expect_record '.project == "p" and .host == "fake-mac" and .outcome == "pass"' "clone name record"
    assert_grep ' project-linux:1 python3 ' "$CTL/docker.log" "approval image must reach the remote job"
    [ "$(cat "$REMOTE_HOME/url")" = "postgres://localhost:$P1/t" ] || fail "approval environment must reach the job"
    expect_services_removed "path services"
    : > "$CTL/docker.log"
  done

  setup pathroot 'echo ran'
  printf 'host fake-mac\nproject repo\n' > "$HOME_FM/config/heavy-remote"
  heavy --project "$REPO" --remote >/dev/null 2>&1 || fail "current repository root path"
  expect_record '.project == "repo" and .host == "fake-mac"' "repository basename record"
  heavy --project . --remote >/dev/null 2>&1 || fail "relative repository root"

  setup pathunapproved 'echo local'
  mkdir -p "$HOME_FM/projects/session-kit" "$CASE/elsewhere/p"
  printf 'host fake-mac\nproject p\noffload\n' > "$HOME_FM/config/heavy-remote"
  heavy --project "$HOME_FM/projects/session-kit" --remote >/dev/null 2>&1
  expect_code 2 "$?" "unapproved clone path refuses remote"
  heavy --project "$HOME_FM/projects/session-kit" >/dev/null 2>&1 || fail "unapproved clone stays local"
  expect_record '.project == "session-kit" and .host == "local"' "unapproved clone record"
  heavy --project "$CASE/elsewhere/p" --remote >/dev/null 2>&1
  expect_code 2 "$?" "an arbitrary path cannot borrow an approved basename"
  [ ! -s "$CTL/log" ] || fail "unapproved paths must never contact the host"
  printf 'host fake-mac\nproject *\n' > "$HOME_FM/config/heavy-remote"
  heavy --project "$HOME_FM/projects/session-kit" --remote >/dev/null 2>&1 || fail "wildcard retains its meaning"
  expect_record '.project == "session-kit" and .host == "fake-mac"' "wildcard path record"
  pass "fm-heavy: clone and repository paths use named approvals, options and records without approving other projects"
}

test_project_paths
test_pass_and_record
test_dirty_snapshot
test_hidden_untracked_snapshot
test_snapshot_failure
test_snapshot_bundle_failure
test_off_by_default_and_refusals
test_fallbacks_run_locally
test_prelaunch_refusal_does_not_reserve_a_slot
test_failed_command
test_timeout_cancels_only_the_jobs_processes
test_owned_processes_are_cleaned
test_killed_job_is_never_green
test_connection_lost_is_reconciled
test_unreachable_job_is_unknown
test_bad_results_are_rejected
test_duplicate_delivery
test_unknown_job_blocks_until_reconciled
test_unknown_job_other_endings
test_live_client_with_orphaned_group_blocks_admission
test_supervisor_loss_after_reconciliation_blocks_admission
test_native_admission_waits_for_an_orphaned_group
test_abandoned_result_has_one_collector
test_runner_reconcile_ages_out_a_dead_start
test_signalled_wrapper_stops_only_its_job
test_unterminated_config_last_line
test_signal_during_eligibility_never_runs_locally
test_wrapper_only_signal_never_runs_locally
test_signal_during_collection_is_cancelled
test_signal_during_reconcile_keeps_the_record
test_killed_check_is_never_a_pass
test_dropped_collection_is_reconciled
test_partial_transfer_is_cleaned
test_cancelled_on_host_is_never_green
test_zombie_group_eperm_keeps_the_result
test_runner_refuses_bad_input
test_summary_compares_hosts
test_scoped_offload
test_bad_config_refuses_only_offload
test_queued_job_moves_to_the_freed_host
test_queued_job_signal_runs_nowhere
test_dependency_cache_and_failures
test_each_project_runs_on_its_pinned_runtimes
test_project_without_dependencies_needs_no_lockfile
test_command_missing_on_host_cannot_run
test_e2e_browser_preparation
test_npm_dependency_cache
test_project_approvals
test_host_jobs_go_first_and_none_is_stopped
test_two_host_slots
test_image_runs_in_a_container
test_container_many_file_install
test_services_start_with_the_job_and_are_removed

echo '# all fm-heavy-remote tests passed'
