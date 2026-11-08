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
    and .fallback == null and .slot == null and (.job | type) == \"string\"
    and (.prepare_s | type) == \"number\" and (.collect_s | type) == \"number\"
    and (.wait_s | type) == \"number\" and (.run_s | type) == \"number\"
    and .started_at >= .requested_at and .ended_at >= .started_at
    and .peak_memory_bytes == null and (.cpu_usec | type) == \"number\"" "remote record"
  expect_host_clean "scratch must be removed after a collected result"
  [ -z "$(ls -A "$HOME_FM/state/heavy-remote/unknown-fake-mac")" ] || fail "a finished job must leave no open record"
  assert_present "$HOME_FM/state/heavy-remote/$(last_record | jq -r .job)/result.json" "the result copy is kept locally"
  pass "fm-heavy --remote: the exact candidate runs on the host and the record has every stage"
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

  echo dirty > "$REPO/untracked-change"
  heavy --remote >/dev/null 2>&1 || fail "a dirty tree must fall back to a local run"
  expect_record '.host == "local" and .fallback == "dirty-tree"' "dirty fallback"
  rm "$REPO/untracked-change"

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
    printf 'host fake-mac\ncommand p -- bash t/job.sh\n%b\n' "$bad" > "$HOME_FM/config/heavy-remote"
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

  # Nothing changes a dirty tree while it queues, so it stops asking.
  setup stilldirty 'echo local'
  observe_local_queue
  printf 'host fake-mac\ncommand p -- bash t/job.sh\noffload\n' > "$HOME_FM/config/heavy-remote"
  echo dirty > "$REPO/untracked-change"
  hold_local
  heavy >"$CASE/out" 2>&1 3>&- 4>&- & pid=$!
  wait_for "$CTL/local-waiting"
  [ ! -s "$CTL/log" ] || fail "a dirty tree may not contact the host"
  release_local
  wait "$pid" || fail "dirty tree local run"
  expect_record '.host == "local" and .fallback == "dirty-tree"' "dirty tree queues locally"
  pass "fm-heavy: a queued approved job moves to the host once it frees, and an ineligible one stays queued"
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
  FAKE_NODE_MISSING=1 heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "missing runtime"
  assert_grep 'missing runtime node' "$CASE/out" "missing runtime reason"
  FAKE_MANAGER_VERSION=8.0.0 heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "incompatible pnpm"
  FAKE_NODE_VERSION=v18.0.0 heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "incompatible runtime"
  assert_grep 'does not satisfy' "$CASE/out" "version failure reason"
  expect_record '.host == "fake-mac" and .outcome == "failed" and .fallback == null' "runtime failure never retries locally"
  echo '# changed again' >> "$REPO/pnpm-lock.yaml"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m failedinstall
  FAKE_INSTALL_FAIL=1 heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "install error"
  expect_record '.host == "fake-mac" and .outcome == "failed" and .fallback == null' "install failure never retries locally"
  [ "$(wc -l < "$REMOTE_HOME/tested")" -eq 3 ] || fail "no candidate runs after runtime/install failure"
  pass "fm-heavy: cached dependencies refresh on lockfile change; runtime/install failures cannot fall back"
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
  heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "a pinned node that is not installed"
  assert_grep 'does not satisfy >=26.0.0' "$CASE/out" "the refusal names the node pin"
  printf '{"packageManager":"pnpm@9.9.0"}\n' > "$REPO/package.json"
  rm "$REPO/.nvmrc"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m missingpnpm
  heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "a pnpm that cannot provide the pin"
  assert_grep 'does not satisfy 9.9.0' "$CASE/out" "the refusal names the pnpm pin"
  # A real pnpm reports the pin once it has fetched that version for itself.
  out=$(FAKE_MANAGER_VERSION=9.9.0 heavy --remote 2>&1) || fail "self-fetched pnpm: $out"
  assert_contains "$out" "9.9.0" "a pnpm providing its own pin runs the job"
  rm -rf "$REMOTE_HOME/.fm-heavy-remote/runtimes"
  FAKE_PNPM_MISSING=1 heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "no pnpm reachable"
  assert_grep 'missing runtime pnpm' "$CASE/out" "the refusal says no pnpm was found"
  expect_record '.host == "fake-mac" and .outcome == "failed" and .fallback == null' "a missing runtime never retries locally"
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
  heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "a pinned node that is not installed"
  assert_grep 'does not satisfy >=26.0.0' "$CASE/out" "the refusal names the node pin"
  printf '{"devDependencies":{"left-pad":"1.3.0"}}\n' > "$REPO/package.json"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m unlocked
  heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "declared dependencies with no lockfile"
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
  heavy --remote >"$CASE/out" 2>&1; expect_code 78 "$?" "nvmrc mismatch"
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

test_pass_and_record
test_off_by_default_and_refusals
test_fallbacks_run_locally
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
test_queued_job_moves_to_the_freed_host
test_queued_job_signal_runs_nowhere
test_dependency_cache_and_failures
test_each_project_runs_on_its_pinned_runtimes
test_project_without_dependencies_needs_no_lockfile
test_command_missing_on_host_cannot_run
test_e2e_browser_preparation
test_npm_dependency_cache

echo '# all fm-heavy-remote tests passed'
