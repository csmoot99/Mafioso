#!/usr/bin/env bash
# Behavioral coverage for bin/fm-heavy.sh and bin/fm-heavy-summary.sh: the
# wrapper runs a command on a private slot lock (never the machine's real one),
# propagates its exit status, appends one record per job, records unavailable
# values as null, honours config/host-test-slots, and the summary reports queue
# wait against run time per project and class. Also the brief rule that points
# workers at the wrapper. The real systemd scope case is skipped where systemd-run
# cannot create user scopes.
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

test_record_and_exit_status() {
  local home log rc
  home=$(make_home record)
  log="$home/state/heavy-jobs.jsonl"
  heavy "$home" "$TMP_ROOT/record.lock" --class build --task t1 --project demo -- bash -c 'exit 7'
  rc=$?
  expect_code 7 "$rc" "the command's exit status"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "expected exactly one record, got: $(cat "$log")"
  jq -e '.task == "t1" and .project == "demo" and .class == "build" and .cmd == "bash"
    and .exit == 7 and .slot == 1 and .wait_s == (.started_at - .requested_at)
    and .run_s == (.ended_at - .started_at)' "$log" >/dev/null \
    || fail "record fields wrong: $(cat "$log")"
  pass "fm-heavy: one record per job and the command's exit status"
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
  flock -o "$TMP_ROOT/wait.lock" sleep 3 &
  holder=$!
  sleep 0.5
  PATH="$fakebin:$PATH" heavy "$home" "$TMP_ROOT/wait.lock" --class test -- true || fail "queued command failed"
  wait "$holder"
  jq -e '.wait_s >= 2 and .slot == 1' "$log" >/dev/null || fail "a held slot must show as wait: $(cat "$log")"

  printf '2\n' > "$home/config/host-test-slots"
  flock -o "$TMP_ROOT/wait.lock" sleep 3 &
  holder=$!
  sleep 0.5
  PATH="$fakebin:$PATH" heavy "$home" "$TMP_ROOT/wait.lock" --class test -- true || fail "second-slot command failed"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  tail -1 "$log" | jq -e '.wait_s <= 1 and .slot == 2' >/dev/null || fail "a free second slot must run at once: $(tail -1 "$log")"
  pass "fm-heavy: queue wait is measured and config/host-test-slots opens more slots"
}

test_refusals_write_no_record() {
  local home log
  home=$(make_home refuse)
  log="$home/state/heavy-jobs.jsonl"
  heavy "$home" "$TMP_ROOT/refuse.lock" --class nonsense -- true 2>/dev/null; expect_code 2 "$?" "bad class"
  heavy "$home" "$TMP_ROOT/refuse.lock" --class test 2>/dev/null; expect_code 2 "$?" "no command"
  printf 'lots\n' > "$home/config/host-test-slots"
  heavy "$home" "$TMP_ROOT/refuse.lock" --class test -- true 2>/dev/null; expect_code 2 "$?" "malformed host-test-slots"
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
EOF
  out=$("$SUMMARY" --log "$log") || fail "summary failed"
  printf '%s\n' "$out" | awk '$1 == "alpha" && $2 == "test" && $3 == 2 && $4 == 1 && $5 == 200 && $6 == 300 && $7 == 200 && $8 == 300 && $9 == 50 && $10 == 2048 && $11 == 1 { ok = 1 } END { exit !ok }' \
    || fail "alpha/test row wrong: $out"
  printf '%s\n' "$out" | awk '$1 == "unknown" && $2 == "build" && $10 == "unknown" { ok = 1 } END { exit !ok }' \
    || fail "unknown/build row wrong: $out"
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
    assert_grep "bin/fm-heavy.sh' --class test|build|e2e|image --task heavy-on-$kind --project some-proj" "$brief" "$kind: wrapper command missing"
    assert_grep "never takes the slot again inside your hold" "$brief" "$kind: nested-hold rule missing"
    assert_grep "drive without it while the pipeline is in intent, rebase or review" "$brief" "$kind: drive-call slot rule missing"
  done
  pass "fm-brief: config/heavy-commands points ship and scout workers at the wrapper"
}

test_record_and_exit_status
test_real_scope_counters
test_unavailable_values_are_null
test_wait_is_measured_and_slots_setting
test_refusals_write_no_record
test_summary
test_brief_rule

echo '# all fm-heavy tests passed'
