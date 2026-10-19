#!/usr/bin/env bash
# Behavior tests for the supervision host's engine turns
# (bin/fm-supervision-host.sh, docs/supervision-host.md): away wakes handled on
# the engine, the captain's return during a turn, failed and incomplete turns,
# killed and restarted hosts, engine-turn bounding, and the park boundary.
# Split from tests/fm-supervision-host.test.sh so the two can run on separate
# CI shards; tests/supervision-host-helpers.sh holds the fixture they share.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

test_away_wake_is_handled_on_the_engine_and_never_reaches_main() {
  local home lock_pid session first second pid watcher
  home=$(make_home away-handled away)
  echo hold-lease > "$home/stub-mode"
  # Dialog in the mirror that an away wake must neither carry nor mark read.
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "away: the wake was not handled: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  lock_pid=$(cat "$home/state/.lock")

  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the engine must run as the branch actor"
  assert_re "^holder=$lock_pid\$" "$first" "the engine's lease holder must be the session-lock holder"
  assert_re '^primary=claude$' "$first" "the engine must carry the primary-harness pin"
  assert_re '^turn=host-' "$first" "the engine must carry its report turn"
  assert_re '^arg=--safe-mode$' "$first" "the engine must load none of the home's hooks"
  assert_re '^arg=dontAsk$' "$first" "the engine must never prompt"
  assert_re '^arg=sonnet$' "$first" "the engine must default to its default model"
  assert_re '^arg=--session-id$' "$first" "the first turn must open a new conversation"
  assert_re '^POSTURE: AWAY\.' "$first" "the wake must carry the away tail"
  assert_grep 'keep the export worker on low effort' "$home/state/.host-mirror.jsonl" "fixture: the captain's dialog was not mirrored"
  assert_no_re 'MAIN DIALOG MIRROR|low effort' "$first" "an away wake must carry no dialog mirror"
  assert_absent "$home/state/.host-mirror-cursor" "a handled away wake must leave the mirror cursor where it was"
  assert_absent "$home/state/.host-mirror-cursor.next" "an away wake must stage no mirror cursor"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "the engine's report did not reach the outcome store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  if FM_HOME="$home" "$LEASE" check demo >/dev/null 2>&1; then
    fail "the host did not release the lease the engine left held: $(FM_HOME="$home" "$LEASE" check demo)"
  fi
  [ ! -s "$home/host.rc" ] || fail "a handled away wake reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a handled away wake printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor cycle"

  echo handle > "$home/stub-mode"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "away: the second wake was not handled"
  session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$first")
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "a later turn must resume the conversation"
  assert_re "^arg=$session\$" "$second" "a later turn must resume the same conversation"
  [ "$(grep -c '"task":"demo"' "$home/state/branch-outcomes.jsonl")" -eq 2 ] || fail "the second outcome was not recorded"
  assert_re '	handled	turn=[^	]*\.2	.* cost=0\.25 conversation_cost=0\.5 ' "$home/state/.supervision-host.log" \
    "a resumed turn must log its own cost, not the conversation's running total"

  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "the host did not stop on TERM"
  expect_code 143 "$(cat "$home/host.rc")" "a TERMed host must exit 143"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "a stopped host left its watcher running"
  assert_absent "$home/state/.supervision-host" "a stopped host left its record"
  pass "host: an away wake is handled on the engine through the branch contract and never reaches main"
}

test_away_turn_without_a_report_hands_the_wake_to_main() {
  local home token
  home=$(make_home away-noreport away)
  echo noreport > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noreport: the host never started a watcher cycle"
  append_status "$home" 'needs a look'
  wait_until 250 host_exited "$home" || fail "noreport: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*recorded no outcome for its wake; this wake is yours$' "$home/host.out" "the handback must say why"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "a handback must leave the recovery marker in downtime for the owner's rewake, got: $token" ;;
  esac
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn that records no outcome hands its durable wake to main"
}

test_return_during_an_engine_turn_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return away)
  echo return > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return: the host never started a watcher cycle"
  append_status "$home" 'mid-task'
  wait_until 250 host_exited "$home" || fail "return: the host did not hand the late outcome to main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a late-outcome handoff must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handoff must carry the close"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake.*store rows 1[,)]' "$home/host.out" \
    "the handoff must say the captain returned mid-turn and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handoff must carry the turn's outcome for main to relay"
  assert_re '	handled	turn=' "$home/state/.supervision-host.log" "the turn itself was handled"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the outcome to main"
  pass "host: a captain return during an engine turn hands that turn's outcomes to main"
}

# Silent outcomes stay stored, but neither captain-return path names or relays
# them when the host decides whether to hand the wake to main.
test_silent_outcomes_are_not_relayed_when_the_captain_returns() {
  local mode home host
  for mode in return-silent return-fail-silent; do
    home=$(make_home "away-$mode" away)
    echo "$mode" > "$home/stub-mode"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$mode: the host never started a watcher cycle"
    append_status "$home" 'no-change result during a captain return'

    if [ "$mode" = return-silent ]; then
      wait_until 250 handled_at_least "$home" 1 || fail "$mode: the wake was not handled: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(cat "$home/engine-report.log" 2>/dev/null)"
      [ ! -s "$home/host.rc" ] || fail "$mode: a silent-only outcome forced a captain handoff: $(cat "$home/host.out")"
      watcher_live "$home" || fail "$mode: the host did not park on its successor"
      host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
      kill -TERM "$host"
      wait_until 200 host_exited "$home" || fail "$mode: the host did not stop on TERM"
    else
      wait_until 250 host_exited "$home" || fail "$mode: the failed turn did not hand the wake to main: $(cat "$home/host.out" 2>/dev/null) $(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null)"
      assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
        "$home/host.out" "$mode: the failed turn must still hand its wake to main"
    fi
    assert_no_re 'captain returned|store rows|^supervision-host: outcome ' "$home/host.out" \
      "$mode: a silent outcome was referenced in the captain-return handoff"
    assert_grep '"silent":true' "$home/state/branch-outcomes.jsonl" "$mode: the silent outcome was not retained in the store"
    assert_absent "$home/state/.afk-contract" "$mode: the captain return was not archived"
  done
  pass "host: silent outcomes are excluded from both captain-return handoff paths"
}

test_large_turn_relays_an_early_visible_outcome() {
  local home count
  home=$(make_home away-many-receipts away)
  echo return-many > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "many receipts: the host never started a watcher cycle"
  append_status "$home" 'large turn with a visible first outcome'
  wait_until 2000 host_exited "$home" || fail "many receipts: the captain-return handoff did not finish: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(tail -n 5 "$home/engine-report.log" 2>/dev/null) rows=$(wc -l < "$home/state/branch-outcomes.jsonl" 2>/dev/null)"
  count=$(grep -c '^supervision-host: outcome ' "$home/host.out")
  [ "$count" -eq 1 ] || fail "many receipts: expected one visible outcome, got $count: $(tail -n 5 "$home/host.out")"
  [ "$(wc -l < "$home/state/branch-outcomes.jsonl" | tr -d ' ')" -eq 1001 ] \
    || fail "many receipts: the fixture did not exceed the old 1,000-row window: rows=$(wc -l < "$home/state/branch-outcomes.jsonl") host=$(cat "$home/host.out") report=$(cat "$home/engine-report.log") tail=$(tail -c 300 "$home/state/branch-outcomes.jsonl")"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "many receipts: the early visible outcome was lost behind later silent rows"
  assert_no_grep 'bulk silent fixture' "$home/host.out" "many receipts: silent outcomes were relayed"
  pass "host: an early visible outcome survives more than 1,000 same-turn receipts"
}

test_outcome_lookup_failure_is_not_treated_as_silence() {
  local home
  home=$(make_home away-lookup-failure away)
  echo return-lookup-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "lookup failure: the host never started a watcher cycle"
  append_status "$home" 'outcome lookup failure after a captain return'
  wait_until 2000 host_exited "$home" || fail "lookup failure: the host treated an unreadable store as a silent outcome"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake, but the recorded outcomes could not be verified; main must review them$' \
    "$home/host.out" "lookup failure: the main handoff did not explain the lookup failure"
  assert_re '^supervision-host: outcome lookup failed for turn receipt rows 1; visible outcomes may require manual review$' \
    "$home/host.out" "lookup failure: the missing outcome warning was not emitted"
  pass "host: an outcome lookup failure forces a visible main handoff"
}

# The live failure this guards: a Cursor park superseded by the captain's
# return kills its host as the engine turn ends, so the host's own handoff is
# never printed. The outcome still reaches main: the next host's first cycle
# resurfaces the durable queue and main's drain presents it.
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end() {
  local home host rc drained
  home=$(make_home away-return-first away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-first: the host never started a watcher cycle"
  append_status "$home" 'finishing while the captain comes back'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" \
    || fail "return-first: the late outcome was never queued: $(cat "$home/engine-report.log" 2>/dev/null)"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  kill -TERM "$host"
  wait_until 250 host_exited "$home" || fail "return-first: the stopped host did not exit"
  rc=$(cat "$home/host.rc")
  [ "$rc" -gt 128 ] || fail "fixture: the host was not stopped mid-turn (rc=$rc): $(cat "$home/host.out")"
  assert_no_re '^supervision-host: ' "$home/host.out" "fixture: the stopped host printed a handoff, so this case proves nothing"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.*; do
    [ -e "$f" ] && fail "a host stopped mid-turn left its turn file behind: $f"
  done
  assert_grep 'supervision-host-return:1' "$home/state/.wake-queue" "the late outcome must stay queued after its host died"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "return-first: the next host did not resurface the queued outcome"
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" "the attended resurface must reach main"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "supervision-host outcome 1 for demo [routine] was recorded after the captain returned" \
    "main's drain must present the outcome the killed host never handed off"
  pass "host: an outcome recorded after the return reaches main even when its host dies at the turn's end"
}

# A host killed outright mid-turn leaves turn files, but the bounded engine's
# watchdog stops the engine when its owner dies. The next host clears the files.
test_next_host_clears_a_turn_its_killed_predecessor_left() {
  local home host engine
  home=$(make_home away-killed-mid-turn away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "killed: the host never started a watcher cycle"
  append_status "$home" 'mid-turn when its host is killed'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" || fail "killed: the turn never reported"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  engine=$(cut -f1 "$home/state/.supervision-host.engine-pid")
  kill -KILL "$host"
  wait_until 100 host_exited "$home" || fail "killed: the host did not die"
  ls "$home"/state/.supervision-host-result.* >/dev/null 2>&1 || fail "fixture: the killed turn left no result file, so this case proves nothing"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$engine" || fail "the bounded engine survived its killed host"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "killed: the next host did not resurface the queued outcome"
  ! kill -0 "$engine" 2>/dev/null || fail "the next host revived its killed predecessor's engine"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.* \
    "$home"/state/.supervision-host-descendants.* "$home/state/.supervision-host-turn"; do
    [ -e "$f" ] && fail "the next host left its killed predecessor's turn file behind: $f"
  done
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  pass "host: a killed predecessor's engine is reaped and the next host removes its turn files"
}

test_report_without_acknowledgement_hands_the_wake_to_main() {
  local home
  home=$(make_home away-noack away)
  echo noack > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noack: the host never started a watcher cycle"
  append_status "$home" 'reported, never acknowledged'
  wait_until 250 host_exited "$home" || fail "noack: the host counted an unacknowledged wake handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn left its granted wake rows [0-9]+( [0-9]+)* unacknowledged; this wake is yours$' "$home/host.out" \
    "the handback must name the rows the turn left unacknowledged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unacknowledged wake must stay durable for main"
  assert_re '	failed	turn=.*	unacked=[0-9]' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  pass "host: a turn that reports but leaves its granted rows queued hands the wake to main"
}

test_return_during_a_failed_turn_still_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return-fail away)
  echo return-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-fail: the host never started a watcher cycle"
  append_status "$home" 'mid-task, then a crash'
  wait_until 250 host_exited "$home" || fail "return-fail: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a failed turn's handback must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); .*captain returned during its turn.*store rows 1[,)]' "$home/host.out" \
    "the handback must say the turn failed, that the captain returned, and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handback must carry the failed turn's outcome for main to relay"
  assert_re '	failed	turn=' "$home/state/.supervision-host.log" "the turn itself failed"
  pass "host: a captain return during a failed engine turn still hands that turn's outcomes to main"
}

test_incomplete_engine_result_hands_the_wake_to_main() {
  local home
  home=$(make_home away-emptyresult away)
  echo emptyresult > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "emptyresult: the host never started a watcher cycle"
  append_status "$home" 'handled, but the result is empty'
  wait_until 250 host_exited "$home" || fail "emptyresult: the host counted an empty result handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn ended with an error or an incomplete result; this wake is yours$' "$home/host.out" \
    "the handback must say the engine's result was incomplete"
  assert_re '	failed	turn=.*	error=1 ' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_no_re '	handled	turn=' "$home/state/.supervision-host.log" "an incomplete result must never count as handled"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn whose result is incomplete hands its wake to main"
}

test_engine_turn_is_bounded_and_its_descendants_reaped() {
  local home orphan
  home=$(make_home away-hang away)
  echo hang > "$home/stub-mode"
  FM_SUPERVISION_HOST_TURN_TIMEOUT=3 FM_SUPERVISION_ENGINE_GRACE=1 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "hang: the host never started a watcher cycle"
  append_status "$home" 'slow one'
  wait_until 300 host_exited "$home" || fail "hang: the bounded turn did not end"
  assert_re '^supervision-host: .*the engine turn hit its 3s bound; this wake is yours$' "$home/host.out" "a bounded turn must hand its wake to main"
  orphan=$(cat "$home/orphan-pid")
  wait_until 50 sh -c '! kill -0 "$1" 2>/dev/null' _ "$orphan" \
    || fail "an engine tool process in its own process group outlived the turn: $(ps -p "$orphan" -o pid=,pgid=,command=)"
  pass "host: an engine turn is bounded, and tool processes outside its process group are reaped"
}

test_restarted_host_stops_what_a_killed_predecessor_left() {
  local home first_host arm watcher
  home=$(make_home away-crash away)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "crash: the host never started a watcher cycle"
  first_host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  arm=$(awk -F '\t' '$1 == "arm" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -KILL "$first_host"
  sleep 1
  kill -0 "$arm" 2>/dev/null || fail "crash: fixture error: the arm died with its host, so this case proves nothing"
  start_host "$home"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$arm" "$watcher" \
    || fail "a restarted host left its killed predecessor's arm or watcher running"
  wait_until 100 sh -c 'grep -q "	start	gen=host-" "$1" && [ "$(grep -c "	start	" "$1")" -ge 2 ]' _ "$home/state/.supervision-host.log" \
    || fail "the restarted host did not start"
  pass "host: a restarted host stops, by recorded identity, the cycle a killed predecessor left running"
}

test_park_exit_probe_uses_half_second_child_sleeps() {
  local home host_pid
  home=$(make_home park-cadence attended)
  cat > "$home/fakebin/sleep" <<'SH'
#!/bin/bash
pid=''
if [ -f "$FM_HOME/probe-host" ]; then
  IFS= read -r pid < "$FM_HOME/probe-host" || true
  if [ "$PPID" = "$pid" ]; then
    printf '%s\n' "$1" >> "$FM_HOME/park-sleeps"
  fi
fi
exec /bin/sleep "$@"
SH
  chmod +x "$home/fakebin/sleep"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "park-cadence: no watcher started"
  host_pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$host_pid" ] || fail "park-cadence: no recorded host"
  printf '%s\n' "$host_pid" > "$home/probe-host"
  wait_until 100 test -s "$home/park-sleeps" || fail "park-cadence: no child sleep observed"
  [ "$(sort -u "$home/park-sleeps")" = 0.5 ] || fail "park-cadence: exit probing did not use half-second sleeps"
  stop_home_processes "$home"
  pass "host: parked child-exit sampling uses ordinary half-second sleeps"
}

test_park_boundary_ends_the_park_before_the_hook_timeout() {
  local home token
  home=$(make_home boundary attended)
  # The wall-clock bound must sit past the exit check: only the injected clock
  # can reach the boundary in time, so a host ignoring it fails instead of
  # passing on real elapsed seconds.
  FM_SUPERVISION_HOST_PARK_SECONDS=60 FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary: the host never started a watcher cycle"
  echo 60 > "$home/park-clock"
  wait_until 150 host_exited "$home" || fail "boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "the park boundary must publish downtime for the owner's rewake, got: $token" ;;
  esac
  pass "host: the park ends itself with a boundary wake and a stopped watcher"
}

# A close that lands while a turn is running can only wait: the host ends its
# park at the bound regardless of how many closes are queued behind it. The
# park runs on the test clock (FM_TEST_SUPERVISION_HOST_CLOCK), which the test
# moves to the refusal window's opening (park bound minus the turn bound and
# grace) before it releases the held turn, so the second close can never take
# a turn of its own on any machine speed. The bound also stays well past every
# wall-clock check in the case: a host that ignored the test clock would start
# the second turn instead of silently passing at a wall-clock boundary.
test_park_boundary_holds_under_back_to_back_closes() {
  # The turn bound is the one wall-clock bound left: it must cover the stub's
  # report work after release, so the product never kills the held turn.
  local home park=300 turn=19 grace=1
  home=$(make_home boundary-busy away)
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  echo 0 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-busy: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'the first of many'
  wait_until 450 sh -c '[ -e "$1/engine-call.1" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-busy: the host never started the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -e "$home/engine-call.1" ] \
    || fail "boundary-busy: the host exited without starting the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  append_status "$home" 'queued while the first close is still handled'
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/stub-release"
  printf 'release\n' >&3
  wait_until 450 host_exited "$home" \
    || fail "the host kept handling back-to-back closes past its park boundary: $(cat "$home/state/.supervision-host.log")"
  exec 3>&-
  ! grep -q '	failed	' "$home/state/.supervision-host.log" \
    || fail "the held turn hit its turn bound or failed: $(cat "$home/state/.supervision-host.log")"
  [ "$(handled_count "$home")" -eq 1 ] || fail "the held turn did not complete once released: $(cat "$home/state/.supervision-host.log")"
  [ ! -e "$home/engine-call.2" ] || fail "a close waiting at the boundary still got an engine turn"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "a close read at the boundary must be printed ahead of the boundary line: $(cat "$home/host.out")"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close waiting at the boundary must stay queued for main"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  pass "host: waiting closes cannot carry the park past its boundary"
}

# Rendering the wake prompt runs after the successor cycle has started; the
# shim holds the render on a FIFO, and the test moves the park's test clock to
# the refusal window's opening before releasing it, so the close passes the
# arrival check and the pre-turn recheck must refuse on any machine speed. The
# snapshot proves the successor arm it started can be checked afterwards. The
# park bound stays past the case's wall-clock checks, so an ignored test clock
# would let the turn run and the engine-call assertions catch it.
test_park_boundary_rechecked_just_before_the_engine_turn() {
  local home real_node pid park=120 turn=3 grace=1
  home=$(make_home boundary-late away)
  real_node=$(command -v node)
  mkfifo "$home/render-release"
  echo 0 > "$home/park-clock"
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ]; then
  cp "\$FM_HOME/state/.supervision-host" "\$FM_HOME/host-record-at-render" 2>/dev/null
  read -r _ < "\$FM_HOME/render-release"
fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-late: the host never started a watcher cycle"
  append_status "$home" 'arrives with just enough margin'
  wait_until 300 sh -c '[ -s "$1/host-record-at-render" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-late: the host neither reached the wake render nor exited: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -s "$home/host-record-at-render" ] \
    || fail "the close was stopped before the successor started: $(cat "$home/host.out")"
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/render-release"
  printf 'release\n' >&3
  wait_until 300 host_exited "$home" || fail "boundary-late: the host did not end its park"
  exec 3>&-
  assert_re '^signal: .*demo.status' "$home/host.out" "the close read at the boundary must reach main"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "the close must be printed ahead of the boundary line: $(cat "$home/host.out")"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "an engine turn started that could run past the boundary"
  assert_no_re '	(handled|failed)	turn=' "$home/state/.supervision-host.log" "no engine turn may be logged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close refused at the boundary must stay queued for main"
  while IFS= read -r pid; do
    kill -0 "$pid" 2>/dev/null && fail "the boundary left the successor arm $pid running"
  done < <(awk -F '\t' '$1 == "arm" { print $2 }' "$home/host-record-at-render")
  watcher_live "$home" && fail "the boundary left the watcher running"
  pass "host: a close whose margin runs out while the successor starts reaches main at the boundary without a turn"
}

# A leaked test clock in a real primary's environment must stay inert: the
# host reads it only alongside the FM_TEST_SEAM marker that test suites set.
test_park_test_clock_requires_the_marker() {
  local home
  home=$(make_home clock-armed away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 host_exited "$home" || fail "clock-armed: the marked test clock did not end the park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the marked test clock must drive the boundary"

  home=$(make_home clock-unmarked away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SEAM='' FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "clock-unmarked: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'handled on the wall clock'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "a test clock without FM_TEST_SEAM changed the park: $(cat "$home/host.out" "$home/state/.supervision-host.log")"
  [ ! -s "$home/host.rc" ] || fail "a test clock without FM_TEST_SEAM ended the park: $(cat "$home/host.out")"
  assert_no_re 'cycle boundary' "$home/host.out" "a test clock without FM_TEST_SEAM reached the boundary"
  pass "host: the park's test clock is inert without the test marker"
}

# A park at or beyond the hook registration is refused for the default. The
# default is observable through the pre-turn margin: a turn bound plus grace of
# 27000 seconds crosses a 27000-second park, so the close goes to main at the
# boundary, while under a 28799-second park the same turn runs.
park_outcome() {  # <name> <park-seconds>; sets PARK_OUTCOME to boundary or handled
  local home
  home=$(make_home "$1" away)
  FM_SUPERVISION_HOST_PARK_SECONDS=$2 FM_SUPERVISION_HOST_TURN_TIMEOUT=26990 FM_SUPERVISION_ENGINE_GRACE=10 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "$1: the host never started a watcher cycle"
  append_status "$home" 'one close'
  wait_until 250 sh -c '[ -s "$1/host.rc" ] || grep -q "	handled	" "$1/state/.supervision-host.log" 2>/dev/null' _ "$home" \
    || fail "$1: the close was neither handled nor handed to main: $(cat "$home/state/.supervision-host.log")"
  if host_exited "$home"; then
    grep -q '^supervision-host: cycle boundary - ' "$home/host.out" || fail "$1: the host exited without the boundary: $(cat "$home/host.out")"
    ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "$1: an engine turn ran before the boundary exit"
    PARK_OUTCOME=boundary
  else
    kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
    wait_until 200 host_exited "$home" || fail "$1: the host did not stop on TERM"
    PARK_OUTCOME=handled
  fi
}

test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default() {
  park_outcome park-28799 28799
  [ "$PARK_OUTCOME" = handled ] || fail "a park just under the registration must be honored"
  park_outcome park-28800 28800
  [ "$PARK_OUTCOME" = boundary ] || fail "a park at the registration must fall back to the default"
  park_outcome park-huge 100000000000000000000
  [ "$PARK_OUTCOME" = boundary ] || fail "a park far beyond the registration must fall back to the default"
  pass "host: a park at or beyond the Stop-hook registration falls back to the default boundary"
}

# An owner whose own bound is the park lets a turn run past the boundary up to
# its limit; a limit below the boundary or at the registration is the boundary.
test_park_limit_lets_a_turn_outlive_the_boundary() {
  local cases name limit want home
  cases='limit-later:28000:handled limit-earlier:50:boundary limit-registration:28800:boundary limit-absent::boundary'
  for c in $cases; do
    name=${c%%:*}; limit=${c#*:}; want=${limit#*:}; limit=${limit%%:*}
    home=$(make_home "$name" away)
    FM_SUPERVISION_HOST_PARK_SECONDS=100 FM_SUPERVISION_HOST_PARK_LIMIT=$limit FM_SUPERVISION_HOST_TURN_TIMEOUT=200 \
      FM_SUPERVISION_ENGINE_GRACE=10 start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$name: the host never started a watcher cycle"
    append_status "$home" 'one close'
    wait_until 250 sh -c '[ -s "$1/host.rc" ] || grep -q "	handled	" "$1/state/.supervision-host.log" 2>/dev/null' _ "$home" \
      || fail "$name: the close was neither handled nor handed to main: $(cat "$home/state/.supervision-host.log")"
    if host_exited "$home"; then
      grep -q '^supervision-host: cycle boundary - ' "$home/host.out" || fail "$name: the host exited without the boundary: $(cat "$home/host.out")"
      [ "$want" = boundary ] || fail "$name: a turn inside the owner's limit was refused at the boundary"
    else
      [ "$want" = handled ] || fail "$name: a turn past the boundary ran without a later limit"
      kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
      wait_until 200 host_exited "$home" || fail "$name: the host did not stop on TERM"
    fi
  done
  pass "host: an owner's later park limit lets a turn outlive the boundary, and no other limit does"
}

test_park_exit_probe_uses_half_second_child_sleeps
test_away_wake_is_handled_on_the_engine_and_never_reaches_main
test_away_turn_without_a_report_hands_the_wake_to_main
test_return_during_an_engine_turn_hands_its_outcomes_to_main
test_silent_outcomes_are_not_relayed_when_the_captain_returns
test_large_turn_relays_an_early_visible_outcome
test_outcome_lookup_failure_is_not_treated_as_silence
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end
test_next_host_clears_a_turn_its_killed_predecessor_left
test_report_without_acknowledgement_hands_the_wake_to_main
test_return_during_a_failed_turn_still_hands_its_outcomes_to_main
test_incomplete_engine_result_hands_the_wake_to_main
test_engine_turn_is_bounded_and_its_descendants_reaped
test_restarted_host_stops_what_a_killed_predecessor_left
test_park_boundary_ends_the_park_before_the_hook_timeout
test_park_boundary_holds_under_back_to_back_closes
test_park_boundary_rechecked_just_before_the_engine_turn
test_park_test_clock_requires_the_marker
test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default
test_park_limit_lets_a_turn_outlive_the_boundary
