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
#   line 1  drop (fail 255 without running), after (run, then fail 255) or pre (run
#           the rest of the file as a script in the host's home first)
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
  [ "$mode" != pre ] || (cd "$FAKE_SSH_HOME" && HOME="$FAKE_SSH_HOME" bash -c "$(sed -n '4,$p' "$rule")")
  break
done
[ "$mode" != drop ] || exit 255
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
  printf '%s\n' '# approved for these tests only' 'host fake-mac' 'command bash t/job.sh' "timeout ${3:-30}" \
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
    FAKE_SSH_CTL="$CTL" FAKE_SSH_HOME="$REMOTE_HOME" "$HEAVY" --class test --task t --project p "$@" -- bash t/job.sh)
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
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" "$HEAVY" --class test --remote -- bash other.sh) 2>/dev/null
  expect_code 2 "$?" "a command that is not the approved one"
  (cd "$REPO" && PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FM" FM_HEAVY_LOCK="$LOCK" "$HEAVY" --class build --remote -- bash t/job.sh) 2>/dev/null
  expect_code 2 "$?" "a class other than test"
  rm "$HOME_FM/config/heavy-remote"
  heavy --remote >/dev/null 2>&1; expect_code 2 "$?" "no config"
  local bad
  for bad in 'host a\n' 'host a\ncommand bash t/job.sh\nhost b\n' 'host a b\ncommand bash t/job.sh\n' \
    'host a\ncommand bash t/job.sh\ncommand bash t/other.sh\n' 'host a\ncommand bash t/job.sh\ntimeout 0\n' \
    'host a\ncommand bash t/job.sh\nsurprise 1\n'; do
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
  expect_record '.outcome == "unknown" and .exit == 75 and .host == "fake-mac" and (.job | type) == "string"' "unknown record"
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
  rule collect drop 'tar -cf - result.json' 1
  heavy --remote >/dev/null 2>&1 || fail "a dropped collection falls back to a local run"
  expect_record '.host == "local" and .fallback == "unreachable"' "dropped collection fallback"
  assert_present "$OPEN" "a dropped collection leaves the record open"
  assert_present "$REMOTE_HOME/.fm-heavy-remote/$JOB/result.json" "a dropped collection must keep the result on the host"
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
    exec setsid env --default-signal=INT "$HEAVY" --class test --remote -- bash t/job.sh >/dev/null 2>&1) &
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

test_summary_compares_hosts() {
  local log=$TMP_ROOT/summary.jsonl out
  cat > "$log" <<'EOF'
{"task":"a","project":"p","class":"test","requested_at":100,"wait_s":1900,"run_s":25,"exit":0,"peak_memory_bytes":null}
{"task":"b","project":"p","class":"test","requested_at":200,"wait_s":0,"run_s":22,"exit":0,"peak_memory_bytes":null,"host":"fm-mac","prepare_s":6,"collect_s":1,"outcome":"pass"}
{"task":"c","project":"p","class":"test","requested_at":300,"wait_s":0,"run_s":24,"exit":0,"peak_memory_bytes":null,"host":"fm-mac","prepare_s":8,"collect_s":1,"outcome":"pass"}
EOF
  out=$("$SUMMARY" --log "$log") || fail "summary failed"
  printf '%s\n' "$out" | awk '$1 == "p" && $2 == "test" && $3 == 1 && $12 == "local" && $13 == "unknown" && $14 == "unknown" { ok = 1 } END { exit !ok }' \
    || fail "the local row is wrong: $out"
  printf '%s\n' "$out" | awk '$1 == "p" && $2 == "test" && $3 == 2 && $12 == "fm-mac" && $13 == 7 && $14 == 1 { ok = 1 } END { exit !ok }' \
    || fail "the remote row is wrong: $out"
  pass "fm-heavy-summary: local and remote jobs get their own rows with preparation and collection time"
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
test_runner_refuses_bad_input
test_summary_compares_hosts

echo '# all fm-heavy-remote tests passed'
