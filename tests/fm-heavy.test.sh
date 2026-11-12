#!/usr/bin/env bash
# Behavioral coverage for bin/fm-heavy.sh and bin/fm-heavy-summary.sh: the
# wrapper runs a command on a private slot lock (never the machine's real one),
# leaves its environment and stdin alone, propagates its exit status, appends one
# record per job, including jobs killed while running or queued, records
# unavailable values as null, honours config/host-test-slots, and the summary
# reports queue wait against run time per project and class. Also the brief rule
# that points workers at the wrapper. The real systemd scope cases are skipped
# where systemd-run cannot create user scopes.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-heavy)
HEAVY="$ROOT/bin/fm-heavy.sh"
SUMMARY="$ROOT/bin/fm-heavy-summary.sh"

for tool in flock jq systemd-run; do
  command -v "$tool" >/dev/null 2>&1 || { echo "# skip: $tool is not installed"; exit 0; }
done

make_home() {  # <name>
  mkdir -p "$TMP_ROOT/$1/state" "$TMP_ROOT/$1/config"
  printf '%s\n' "$TMP_ROOT/$1"
}

# A systemd-run that runs the command with no scope, so no cgroup counters exist.
make_unscoped_systemd_run() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/systemd-run" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in --user|--scope|-q) shift ;; -p) shift 2 ;; --unit=*) shift ;; *) break ;; esac; done
exec "$@"
SH
  chmod +x "$fakebin/systemd-run"
  printf '%s\n' "$fakebin"
}

heavy() {  # <home> <lock> args...
  local home=$1 lock=$2
  shift 2
  FM_HOME="$home" FM_HEAVY_LOCK="$lock" "$HEAVY" "$@"
}

# Starts the wrapper in the background as its own process group; $! is the group
# id. A background job starts with SIGINT ignored, and bash cannot trap that.
heavy_group() {  # <home> <lock> args...
  local home=$1 lock=$2
  shift 2
  FM_HOME="$home" FM_HEAVY_LOCK="$lock" setsid env --default-signal=INT "$HEAVY" "$@" &
}

# Starts a slot holder in the background; $! is the flock parent. Killing that
# leaves its sleep running, which must not keep the test's output open.
hold_lock() {  # <lock> <seconds>
  flock -o "$1" sleep "$2" >/dev/null 2>&1 &
}

wait_for_lock_held() {  # <lock>
  local tries=0
  while flock -n "$1" true; do
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || fail "timed out waiting for a holder of $1"
    sleep 0.1
  done
}

wait_for_file() {  # <path>
  local tries=0
  until [ -e "$1" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

test_record_and_exit_status() {
  local home fakebin log rc
  home=$(make_home record)
  fakebin=$(make_unscoped_systemd_run "$TMP_ROOT/record-bin")
  log="$home/state/heavy-jobs.jsonl"
  PATH="$fakebin:$PATH" heavy "$home" "$TMP_ROOT/record.lock" --class build --task t1 --project demo -- bash -c 'exit 7'
  rc=$?
  expect_code 7 "$rc" "the command's exit status"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "expected exactly one record, got: $(cat "$log")"
  jq -e '.task == "t1" and .project == "demo" and .class == "build" and .cmd == "bash"
    and .exit == 7 and .slot == 1 and .wait_s == (.started_at - .requested_at)
    and .run_s == (.ended_at - .started_at)' "$log" >/dev/null \
    || fail "record fields wrong: $(cat "$log")"
  pass "fm-heavy: one record per job and the command's exit status"
}

test_command_runs_as_by_hand() {
  local home fakebin out
  home=$(make_home byhand)
  fakebin=$(make_unscoped_systemd_run "$TMP_ROOT/byhand-bin")
  PATH="$fakebin:$PATH" LC_ALL=C.UTF-8 heavy "$home" "$TMP_ROOT/byhand.lock" --class test -- \
    bash -c 'env > "$1"' _ "$TMP_ROOT/byhand.env" || fail "command failed"
  assert_grep "LC_ALL=C.UTF-8" "$TMP_ROOT/byhand.env" "the worker's LC_ALL must reach the command"
  assert_no_grep "_FMH_" "$TMP_ROOT/byhand.env" "wrapper state must not reach the command"
  (unset LC_ALL; PATH="$fakebin:$PATH" heavy "$home" "$TMP_ROOT/byhand.lock" --class test -- \
    bash -c 'env > "$1"' _ "$TMP_ROOT/byhand-unset.env") || fail "command failed"
  assert_no_grep "LC_ALL=" "$TMP_ROOT/byhand-unset.env" "the wrapper must not set LC_ALL"
  out=$(printf 'from stdin' | PATH="$fakebin:$PATH" heavy "$home" "$TMP_ROOT/byhand.lock" --class test -- cat)
  [ "$out" = "from stdin" ] || fail "the command must keep stdin, got: $out"
  PATH="$fakebin:$PATH" heavy "$home" "$TMP_ROOT/byhand.lock" --class test -- \
    bash -c 'sleep 5 >/dev/null 2>&1 &' || fail "command failed"
  flock -n "$TMP_ROOT/byhand.lock" true || fail "a process the command leaves running must not hold the slot"
  pass "fm-heavy: the command keeps its environment and stdin, and leftovers do not hold the slot"
}

test_killed_while_running() {
  local home fakebin log lock pid rc name number
  home=$(make_home killed)
  fakebin=$(make_unscoped_systemd_run "$TMP_ROOT/killed-bin")
  log="$home/state/heavy-jobs.jsonl"
  lock="$TMP_ROOT/killed.lock"
  for name in HUP:1 INT:2 TERM:15; do
    number=${name#*:}
    name=${name%:*}
    : > "$log"
    PATH="$fakebin:$PATH" heavy_group "$home" "$lock" --class test --task "run-$name" -- \
      bash -c ': > "$1"; exec sleep 30' _ "$TMP_ROOT/killed-$name.ready"
    pid=$!
    wait_for_file "$TMP_ROOT/killed-$name.ready"
    kill "-$name" -- "-$pid"
    wait "$pid"
    rc=$?
    expect_code "$((128 + number))" "$rc" "wrapper status after SIG$name"
    [ "$(wc -l < "$log")" -eq 1 ] || fail "expected one record after SIG$name, got: $(cat "$log")"
    jq -e --arg task "run-$name" --argjson rc "$((128 + number))" '
      .task == $task and .exit == $rc and .slot == 1 and (.started_at | type) == "number"
      and (.ended_at | type) == "number" and (.run_s | type) == "number"' "$log" >/dev/null \
      || fail "killed-job record wrong after SIG$name: $(cat "$log")"
  done
  pass "fm-heavy: a job killed while running is recorded with exit 128+n"
}

test_killed_while_queued() {
  local home fakebin log lock holder pid rc slots
  home=$(make_home queued)
  fakebin=$(make_unscoped_systemd_run "$TMP_ROOT/queued-bin")
  log="$home/state/heavy-jobs.jsonl"
  lock="$TMP_ROOT/queued.lock"
  hold_lock "$lock" 60
  holder=$!
  wait_for_lock_held "$lock"

  PATH="$fakebin:$PATH" heavy_group "$home" "$lock" --class e2e --task group --project demo -- \
    touch "$TMP_ROOT/queued-group.ran"
  pid=$!
  sleep 1.2
  kill -TERM -- "-$pid"
  wait "$pid"
  expect_code 143 "$?" "wrapper status when queued"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "expected one queued record, got: $(cat "$log")"
  jq -e '.task == "group" and .project == "demo" and .class == "e2e" and .cmd == "touch"
    and (.requested_at | type) == "number" and .wait_s >= 1 and .started_at == null
    and .ended_at == null and .run_s == null and .exit == null and .slot == null
    and .peak_memory_bytes == null and .cpu_usec == null' "$log" >/dev/null \
    || fail "queued record wrong: $(cat "$log")"

  for slots in 1 2; do
    printf '%s\n' "$slots" > "$home/config/host-test-slots"
    if [ "$slots" -eq 2 ]; then
      hold_lock "$lock.2" 60
      holder="$holder $!"
      wait_for_lock_held "$lock.2"
    fi
    : > "$log"
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_HEAVY_LOCK="$lock" "$HEAVY" --class test --task "alone-$slots" -- \
      touch "$TMP_ROOT/queued-alone.ran" &
    pid=$!
    sleep 0.5
    kill -TERM "$pid"
    wait "$pid"
    rc=$?
    expect_code 143 "$rc" "wrapper status when only the wrapper is signalled ($slots slots)"
    jq -e --arg task "alone-$slots" '.task == $task and .exit == null and .started_at == null' "$log" >/dev/null \
      || fail "queued record wrong with $slots slots: $(cat "$log")"
  done

  # shellcheck disable=SC2086 # one pid per word
  kill $holder 2>/dev/null
  # shellcheck disable=SC2086 # one pid per word
  wait $holder 2>/dev/null
  flock "$lock" sleep 0.5
  [ ! -e "$TMP_ROOT/queued-group.ran" ] && [ ! -e "$TMP_ROOT/queued-alone.ran" ] \
    || fail "a job killed in the queue must never run"
  pass "fm-heavy: a job killed while queued records its wait and never runs"
}

test_real_scope_counters() {
  local home log
  home=$(make_home scope)
  log="$home/state/heavy-jobs.jsonl"
  if ! systemd-run --user --scope -q true 2>/dev/null; then
    pass "fm-heavy: skipped real scope counters (no user scopes here)"
    return
  fi
  heavy "$home" "$TMP_ROOT/scope.lock" --class test -- bash -c 'head -c 20000000 /dev/zero | tail -c 1 >/dev/null' \
    || fail "wrapped command failed"
  jq -e '(.peak_memory_bytes | type) == "number" and .peak_memory_bytes > 0
    and (.cpu_usec | type) == "number"' "$log" >/dev/null \
    || fail "scope counters missing: $(cat "$log")"
  jq -e '.task == null and .project == null' "$log" >/dev/null || fail "unset task/project must be null"
  pass "fm-heavy: peak memory and CPU come from the job's own scope"
}

# What systemd does when the cap kills a child: SIGTERM to everything in the scope.
test_scope_wide_stop_keeps_counters() {
  local home log
  home=$(make_home stop)
  log="$home/state/heavy-jobs.jsonl"
  if ! systemd-run --user --scope -q true 2>/dev/null; then
    pass "fm-heavy: skipped scope-wide stop (no user scopes here)"
    return
  fi
  printf '%s\n' '#!/usr/bin/env bash' 'kill -TERM "$PPID" "$$"' 'sleep 5' > "$TMP_ROOT/stop.sh"
  chmod +x "$TMP_ROOT/stop.sh"
  heavy "$home" "$TMP_ROOT/stop.lock" --class test -- "$TMP_ROOT/stop.sh"
  expect_code 143 "$?" "the terminated command's status"
  jq -e '.exit == 143 and (.peak_memory_bytes | type) == "number" and .peak_memory_bytes > 0
    and (.cpu_usec | type) == "number"' "$log" >/dev/null \
    || fail "a scope-wide stop must keep the counters: $(cat "$log")"
  pass "fm-heavy: a scope-wide stop still records peak memory and CPU"
}

test_unavailable_values_are_null() {
  local home fakebin log
  home=$(make_home unknown)
  fakebin=$(make_unscoped_systemd_run "$TMP_ROOT/unknown-bin")
  log="$home/state/heavy-jobs.jsonl"
  PATH="$fakebin:$PATH" heavy "$home" "$TMP_ROOT/unknown.lock" --class e2e -- true || fail "command failed"
  jq -e '.peak_memory_bytes == null and .cpu_usec == null' "$log" >/dev/null \
    || fail "an unavailable reading must be null: $(cat "$log")"
  pass "fm-heavy: a reading outside the job's own scope is recorded as null"
}

test_wait_is_measured_and_slots_setting() {
  local home fakebin log holder
  home=$(make_home wait)
  fakebin=$(make_unscoped_systemd_run "$TMP_ROOT/wait-bin")
  log="$home/state/heavy-jobs.jsonl"
  hold_lock "$TMP_ROOT/wait.lock" 3
  holder=$!
  sleep 0.5
  PATH="$fakebin:$PATH" heavy "$home" "$TMP_ROOT/wait.lock" --class test -- true || fail "queued command failed"
  wait "$holder"
  jq -e '.wait_s >= 2 and .slot == 1' "$log" >/dev/null || fail "a held slot must show as wait: $(cat "$log")"

  printf '2\n' > "$home/config/host-test-slots"
  hold_lock "$TMP_ROOT/wait.lock" 3
  holder=$!
  sleep 0.5
  PATH="$fakebin:$PATH" heavy "$home" "$TMP_ROOT/wait.lock" --class test -- true || fail "second-slot command failed"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  tail -1 "$log" | jq -e '.wait_s <= 1 and .slot == 2' >/dev/null || fail "a free second slot must run at once: $(tail -1 "$log")"
  pass "fm-heavy: queue wait is measured and config/host-test-slots opens more slots"
}

test_refusals_write_no_record() {
  local home log bad
  home=$(make_home refuse)
  log="$home/state/heavy-jobs.jsonl"
  heavy "$home" "$TMP_ROOT/refuse.lock" --class nonsense -- true 2>/dev/null; expect_code 2 "$?" "bad class"
  heavy "$home" "$TMP_ROOT/refuse.lock" --class test 2>/dev/null; expect_code 2 "$?" "no command"
  for bad in 'lots\n' '00\n' '0\n' '01\n' '1\n2\n' '1 2\n' '\n'; do
    # shellcheck disable=SC2059 # the cases are printf formats
    printf "$bad" > "$home/config/host-test-slots"
    timeout 10 env FM_HOME="$home" FM_HEAVY_LOCK="$TMP_ROOT/refuse.lock" "$HEAVY" --class test -- true 2>/dev/null
    expect_code 2 "$?" "malformed host-test-slots $bad"
  done
  rm "$home/config/host-test-slots"
  timeout 10 env FM_HOME="$home" FM_HEAVY_LOCK="$TMP_ROOT/no-such-dir/refuse.lock" "$HEAVY" --class test -- true 2>/dev/null
  expect_code 2 "$?" "unopenable lock"
  [ ! -s "$log" ] || fail "a refused run must not write a record"
  pass "fm-heavy: usage and configuration errors refuse without a record"
}

test_summary() {
  local log out
  log="$TMP_ROOT/summary.jsonl"
  cat > "$log" <<'EOF'
{"task":"a","project":"alpha","class":"test","requested_at":100,"wait_s":300,"run_s":100,"exit":0,"peak_memory_bytes":2147483648}
{"task":"b","project":"alpha","class":"test","requested_at":200,"wait_s":100,"run_s":300,"exit":1,"peak_memory_bytes":null}
{"task":null,"project":null,"class":"build","requested_at":300,"wait_s":0,"run_s":60,"exit":0,"peak_memory_bytes":null}
{"task":"c","project":"beta","class":"e2e","requested_at":400,"started_at":null,"ended_at":null,"wait_s":90,"run_s":null,"exit":null,"slot":null,"peak_memory_bytes":null,"cpu_usec":null}
{"task":"d","project":"gamma","class":"test","requested_at":500,"wait_s":0,"run_s":100,"exit":0,"peak_memory_bytes":1048576}
{"task":"e","project":"gamma","class":"test","requested_at":600,"started_at":null,"ended_at":null,"wait_s":100,"run_s":null,"exit":null,"slot":null,"peak_memory_bytes":null,"cpu_usec":null}
EOF
  out=$("$SUMMARY" --log "$log") || fail "summary failed"
  printf '%s\n' "$out" | awk '$1 == "alpha" && $2 == "test" && $3 == 2 && $4 == 1 && $5 == 200 && $6 == 300 && $7 == 200 && $8 == 300 && $9 == 50 && $10 == 2048 && $11 == 1 { ok = 1 } END { exit !ok }' \
    || fail "alpha/test row wrong: $out"
  printf '%s\n' "$out" | awk '$1 == "unknown" && $2 == "build" && $10 == "unknown" { ok = 1 } END { exit !ok }' \
    || fail "unknown/build row wrong: $out"
  printf '%s\n' "$out" | awk '$1 == "beta" && $2 == "e2e" && $3 == 1 && $4 == 0 && $5 == 90 && $6 == 90 && $7 == "unknown" && $8 == "unknown" && $9 == 100 && $10 == "unknown" && $11 == 1 { ok = 1 } END { exit !ok }' \
    || fail "a job killed in the queue must count its wait and nothing else: $out"
  printf '%s\n' "$out" | awk '$1 == "gamma" && $2 == "test" && $3 == 2 && $4 == 0 && $5 == 50 && $7 == 100 && $8 == 100 && $9 == 50 { ok = 1 } END { exit !ok }' \
    || fail "null run times must stay out of the averages: $out"
  out=$("$SUMMARY" --log "$log" --since 250) || fail "summary --since failed"
  assert_not_contains "$out" alpha "--since must drop earlier jobs"
  [ "$("$SUMMARY" --log "$TMP_ROOT/none.jsonl")" = "no heavy-command records in $TMP_ROOT/none.jsonl" ] \
    || fail "an absent log must say so"
  "$SUMMARY" --since soon >/dev/null 2>&1; expect_code 2 "$?" "bad --since"
  pass "fm-heavy-summary: wait versus run time and peak memory per project and class"
}

test_brief_rule() {
  local home brief kind
  home=$(make_home brief)
  for kind in ship scout; do
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "heavy-off-$kind" some-proj --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "heavy-off-$kind" some-proj --mode no-mistakes >/dev/null 2>&1
    fi
    assert_no_grep "fm-heavy.sh" "$home/data/heavy-off-$kind/brief.md" "$kind: the rule appeared without config/heavy-commands"
  done
  : > "$home/config/heavy-commands"
  for kind in ship scout; do
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "heavy-on-$kind" some-proj --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "heavy-on-$kind" some-proj --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/heavy-on-$kind/brief.md"
    assert_grep "bin/fm-heavy.sh' --class test|build|e2e|image --task heavy-on-$kind --project 'some-proj'" "$brief" "$kind: wrapper command missing"
    assert_grep "never takes the slot again inside your hold" "$brief" "$kind: nested-hold rule missing"
    assert_grep "drive without it while the pipeline is in intent, rebase or review" "$brief" "$kind: drive-call slot rule missing"
  done
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" heavy-path "$home/projects/some-proj" --mode no-mistakes >/dev/null 2>&1
  assert_grep "--project 'some-proj' --" "$home/data/heavy-path/brief.md" "path input must render the project name"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" heavy-on-review some-proj --review >/dev/null 2>&1
  assert_no_grep "fm-heavy.sh" "$home/data/heavy-on-review/brief.md" "a read-only review must not get the rule"
  pass "fm-brief: config/heavy-commands points ship and scout workers at the wrapper"
}

# A PATH holding every tool here except systemd-run, and uname reporting <os>.
make_unscoped_path() {  # <dir> <os>
  local fakebin d f
  fakebin=$(fm_fakebin "$1")
  IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    for f in "$d"/*; do
      [ -x "$f" ] && [ ! -e "$fakebin/${f##*/}" ] && [ "${f##*/}" != systemd-run ] && ln -s "$f" "$fakebin/${f##*/}"
    done
  done
  rm -f "$fakebin/uname"
  printf '#!/bin/sh\necho %s\n' "$2" > "$fakebin/uname"
  chmod +x "$fakebin/uname"
  printf '%s\n' "$fakebin"
}

test_macos_runs_without_systemd() {
  local home lock fakebin log
  home=$(make_home darwin)
  lock=$TMP_ROOT/darwin.lock
  log=$home/state/heavy-jobs.jsonl
  fakebin=$(make_unscoped_path "$TMP_ROOT/darwin" Darwin)
  PATH=$fakebin heavy "$home" "$lock" --class test --task mac --project demo -- sh -c 'echo out; exit 3' > "$TMP_ROOT/darwin.out"
  expect_code 3 "$?" "the job's exit status on macOS"
  [ "$(cat "$TMP_ROOT/darwin.out")" = out ] || fail "macOS job output: $(cat "$TMP_ROOT/darwin.out")"
  jq -e '.exit == 3 and .slot == 1 and .peak_memory_bytes == null and .cpu_usec == null' "$log" >/dev/null \
    || fail "macOS record: $(cat "$log")"
  [ -z "$(ls -A "$lock.waiting" 2>/dev/null)" ] || fail "no waiter marker remains"
  fakebin=$(make_unscoped_path "$TMP_ROOT/linux-nosystemd" Linux)
  PATH=$fakebin heavy "$home" "$lock" --class test --task mac --project demo -- true 2>/dev/null
  expect_code 69 "$?" "Linux without systemd-run"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "the refusal writes no record"
  pass "fm-heavy: macOS runs jobs on the shared slot without systemd-run; Linux still requires it"
}

test_brief_rule_is_machine_wide() {
  local root mate
  root=$(make_home brief-root)
  mate=$(make_home brief-mate)
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  : > "$mate/config/heavy-commands"
  FM_HOME="$mate" "$ROOT/bin/fm-brief.sh" heavy-mate-off some-proj --mode no-mistakes >/dev/null 2>&1
  assert_no_grep "fm-heavy.sh" "$mate/data/heavy-mate-off/brief.md" "a secondmate's own flag must have no effect"
  rm "$mate/config/heavy-commands"
  : > "$root/config/heavy-commands"
  FM_HOME="$mate" "$ROOT/bin/fm-brief.sh" heavy-mate-on some-proj --mode no-mistakes >/dev/null 2>&1
  assert_grep "bin/fm-heavy.sh' --class test|build|e2e|image --task heavy-mate-on" "$mate/data/heavy-mate-on/brief.md" \
    "the root home's flag must reach a local secondmate's workers"
  pass "fm-brief: config/heavy-commands is read from the root home"
}

test_record_and_exit_status
test_command_runs_as_by_hand
test_killed_while_running
test_killed_while_queued
test_real_scope_counters
test_scope_wide_stop_keeps_counters
test_unavailable_values_are_null
test_wait_is_measured_and_slots_setting
test_refusals_write_no_record
test_summary
test_brief_rule
test_brief_rule_is_machine_wide
test_macos_runs_without_systemd

echo '# all fm-heavy tests passed'
