#!/usr/bin/env bash
# Behavior tests for the supervision host across one main session
# (bin/fm-supervision-host.sh, docs/supervision-host.md): the first cycle's
# status stream, the broken-session latch in both postures, an unchanged held
# outcome across scan cadences, an unverified engine, and a host that does not
# own the session standing down. Split from tests/fm-supervision-host.test.sh
# so the two can run on separate CI shards; tests/supervision-host-helpers.sh
# holds the fixture they share.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

# The first cycle's status line reaches the owner before any close and only
# once; --restart replaces a watcher it would otherwise attach to, and the
# owner's predecessor arm makes the first cycle a handling successor. The home
# names no usable engine, so every attended close passes straight to main.
test_first_cycle_status_streams_and_owner_options_reach_it() {
  local home stale fresh generation predecessor
  home=$(make_home stream attended pi)
  start_host "$home"
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" \
    || fail "stream: the first cycle's status did not reach the owner before a close: $(cat "$home/host.out")"
  host_exited "$home" && fail "stream: the host exited before any close: $(cat "$home/host.out")"
  append_status "$home" 'fixture finished' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the attended close did not reach main"
  [ "$(grep -c '^watcher: ' "$home/host.out")" -eq 1 ] || fail "stream: the status line must be printed once: $(cat "$home/host.out")"
  [ "$(sed -n '1p' "$home/host.out" | cut -c1-17)" = 'watcher: started ' ] || fail "stream: the status line must come first"
  assert_re '^signal: .*demo.status' "$home/host.out" "stream: the close must follow the status line"
  # Main handles that close, so the next cycle has no episode to resurface.
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$home/drain.err" || fail "stream: main's drain failed"
  ack_drain_err "$home/state" "$home/drain.err" >/dev/null 2>&1 || fail "stream: main's acknowledgement failed: $(cat "$home/drain.err")"
  # Pass-through can leave a successor watcher running. Retire that cycle so
  # the orphan-arm fixture below owns the watcher we later ask --restart to replace.
  FM_HOME="$home" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null || fail "stream: could not stop the prior cycle"

  # A watcher a dead arm left behind, holding this home's watcher lock.
  FM_HOME="$home" PATH="$home/fakebin:$PATH" perl -e 'setpgrp(0, 0); exec @ARGV' "$ROOT/bin/fm-watch-arm.sh" \
    > "$home/stale-arm.out" 2>&1 &
  wait_until 150 grep -qs '^watcher: started pid=' "$home/stale-arm.out" \
    || fail "stream: the fixture arm never started its watcher: $(cat "$home/stale-arm.out")"
  wait_until 150 watcher_live "$home" || fail "stream: the fixture watcher never started"
  kill -KILL "$!" 2>/dev/null || true
  wait "$!" 2>/dev/null || true
  stale=$(cat "$home/state/.watch.lock/pid")
  rm -f "$home/host.out" "$home/host.rc"
  start_host "$home" --restart
  # Stopping the old watcher opens a downtime episode, so the fresh cycle may
  # close on its resurface before the arm confirms it, and the arm then prints
  # only that close (bin/fm-watch-arm.sh): either order is the owner's cycle.
  wait_until 150 sh -c 'grep -qs "^watcher: started pid=" "$1/host.out" || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "stream: the restarting host never reported its cycle: $(cat "$home/host.out" "$home/claude.err" 2>/dev/null)"
  fresh=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$home/host.out")
  [ "$fresh" != "$stale" ] || fail "stream: --restart attached to the watcher it should have replaced"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$stale" || fail "stream: --restart left the old watcher running"
  wait_until 200 host_exited "$home" || append_status "$home" 'second close' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the restarting host's close did not reach main"
  assert_re '^(signal: .*demo.status|check: rearm-resurface)$' "$home/host.out" "stream: the restarting host's close must reach main"

  # That close left an unacknowledged downtime episode; a host the owner starts
  # as the closed arm's successor takes it over as a handling successor
  # instead of re-announcing it.
  generation=$(sed -n 's/^[a-z]*:[a-z]*://p' "$home/state/.watcher-down")
  [ -n "$generation" ] || fail "fixture: the close left no downtime episode: $(cat "$home/state/.watcher-down")"
  predecessor=$(sed -n '1p' "$home/claude-pids")
  rm -f "$home/host.out" "$home/host.rc"
  FM_WATCH_PREDECESSOR_ARM_PID=$predecessor start_host "$home" --restart
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" || fail "stream: the successor host never reported its cycle"
  assert_re "^watcher: started pid=[0-9]+ \\(beacon fresh\\) recovery-generation=$generation\$" "$home/host.out" \
    "the owner's predecessor must make the first cycle a handling successor of the pending generation"
  sleep 3
  host_exited "$home" && fail "a handling successor re-announced the pending episode: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "stream: the successor host did not stop on TERM"
  pass "host: the first cycle's status streams once, --restart replaces a stale watcher, and an owner predecessor makes a handling successor"
}

# Let the latch's cooldown pass, as the clock would, by moving its persisted
# probe time into the past, optionally with a cooldown already grown to
# <seconds>; the next close then probes the engine.
end_cooldown() {  # <home> [seconds]
  local health="$1/state/.supervision-host-health" tmp
  grep -q '^retry_after=[1-9]' "$health" 2>/dev/null || fail "the latch recorded no probe time"
  tmp=$(mktemp "$health.XXXXXX")
  if ! { sed -e 's/^retry_after=.*/retry_after=1/' ${2:+-e "s/^cooldown=.*/cooldown=$2/"} "$health" > "$tmp" \
    && mv -f "$tmp" "$health"; }; then
    fail "fixture: could not move the latch's probe time"
  fi
}

# Two consecutive engine errors in one main session: the second trips the latch.
trip_latch() {  # <home>
  echo fail > "$1/stub-mode"
  start_session "$1"
  park_again "$1"
  append_status "$1" 'first'
  wait_until 250 host_exited "$1" || fail "latch: the first engine error did not hand the wake back"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$1/host.out" "the first engine error must hand the wake back with its reason"
  assert_no_re 'paused' "$1/host.out" "one engine error must not latch the session"
  main_drain_and_ack "$1"
  park_again "$1"
  append_status "$1" 'second'
  wait_until 250 host_exited "$1" || fail "latch: the second engine error did not hand the wake back"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$1/host.out" "the tripping handback must still say why"
  assert_re '^supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next 5 minutes' \
    "$1/host.out" "the second consecutive engine error must trip the latch with one line"
  assert_grep 'cooldown=300' "$1/state/.supervision-host-health" "the latch must start with the Pi policy's five-minute cooldown"
  main_drain_and_ack "$1"
}

test_latch_trips_after_two_engine_errors_then_probes_and_recovers() {
  local home
  home=$(make_home away-latch away)
  trip_latch "$home"

  park_again "$home"
  append_status "$home" 'inside the cooldown'
  wait_until 250 host_exited "$home" || fail "latch: a close inside the cooldown did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "a close inside the cooldown must reach main"
  assert_re '^supervision-host: the away session is paused after repeated engine errors until .*; this wake is yours$' \
    "$home/host.out" "a close inside the cooldown must say why main has it"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine ran inside the cooldown"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close inside the cooldown must stay durable for main"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  park_again "$home"
  append_status "$home" 'the probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 3 ] || fail "the cooldown's end did not let one wake probe the engine"
  assert_no_re 'paused' "$home/host.out" "a failed probe must not repeat the trip line"
  assert_grep 'cooldown=600' "$home/state/.supervision-host-health" "a failed probe must double the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home" 2400
  park_again "$home"
  append_status "$home" 'a later probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the later failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 4 ] || fail "the grown cooldown's end did not let one wake probe the engine"
  assert_grep 'cooldown=3600' "$home/state/.supervision-host-health" "the doubled cooldown must stop at one hour"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'the probe succeeds'
  wait_until 250 handled_at_least "$home" 1 || fail "latch: the successful probe was not handled: $(cat "$home/host.out")"
  [ "$(engine_calls "$home")" -eq 5 ] || fail "the cooldown's end did not let the recovering wake probe the engine"
  host_exited "$home" && fail "an away recovery must not reach main: $(cat "$home/host.out")"
  assert_re '	recovered	after a successful probe' "$home/state/.supervision-host.log" "the ledger must record the recovery"
  assert_grep 'cooldown=0' "$home/state/.supervision-host-health" "a successful probe must clear the latch"
  assert_grep 'errors=0' "$home/state/.supervision-host-health" "a successful probe must clear the error streak"
  watcher_live "$home" || fail "the recovered host is not parked on a live successor cycle"
  pass "host: two engine errors latch the session, main keeps every away wake in the cooldown, a failed probe doubles it up to its cap, and a report recovers it silently"
}

# The latch lives only in the opted-in host's away path: an attended close in a
# latched session and a home that dropped config/supervision-host both reach
# main exactly as they do without it.
test_latch_keeps_attended_closes_on_main_and_skips_unopted_homes() {
  local home health
  home=$(make_home latch-scope away)
  trip_latch "$home"
  health=$(cat "$home/state/.supervision-host-health")

  FM_HOME="$home" "$CONTRACT" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"
  park_again "$home"
  append_status "$home" 'attended while latched'
  wait_until 250 host_exited "$home" || fail "latch scope: the attended close did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "an attended close in a latched session must reach main"
  assert_no_re '^supervision-host' "$home/host.out" "an attended close in a latched session must reach main exactly as the arm printed it"
  [ "$(cat "$home/state/.supervision-host-health")" = "$health" ] || fail "an attended close changed the latch"
  main_drain_and_ack "$home"

  : > "$home/config/supervision-host-off"
  FM_HOME="$home" "$CONTRACT" enter --words 'watch the fleet; merge nothing' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture again"
  park_again "$home"
  append_status "$home" 'away after opting out'
  wait_until 250 host_exited "$home" || fail "latch scope: the close after the opt-out did not reach main"
  assert_re '^supervision-host: the home no longer runs the supervision host$' "$home/host.out" \
    "a home opted out by config/supervision-host-off must hand the close back as the opt-out, not the latch"
  assert_no_re 'paused' "$home/host.out" "a home opted out by config/supervision-host-off must not read the latch"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "an engine ran after the latch tripped"
  pass "host: an attended close in a latched session reaches main as the arm printed it and leaves the latch as it was, and a home that opted out with off never reads it"
}

test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main() {
  local home handled
  home=$(make_home attended-latch attended)
  echo fail > "$home/stub-mode"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 host_exited "$home" || fail "latch: the first engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$home/host.out" "the first engine error must hand the wake back with its reason"
  assert_no_re 'paused' "$home/host.out" "one engine error must not latch the session"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'second'
  wait_until 250 host_exited "$home" || fail "latch: the second engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next 5 minutes' "$home/host.out" \
    "the second consecutive engine error must trip the latch with one line"
  assert_grep 'cooldown=300' "$home/state/.supervision-host-health" "the latch must start with the Pi policy's five-minute cooldown"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'inside the cooldown'
  wait_until 250 host_exited "$home" || fail "latch: a close inside the cooldown did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "a close inside the cooldown must reach main"
  assert_no_re '^supervision-host' "$home/host.out" "a close inside the cooldown must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine ran inside the cooldown"
  assert_re '	pass-through	attended	the supervision session is cooling down' "$home/state/.supervision-host.log" \
    "the ledger must record the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  park_again "$home"
  append_status "$home" 'the probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 3 ] || fail "the cooldown's end did not let one wake probe the engine"
  assert_no_re 'paused' "$home/host.out" "a failed probe must not repeat the trip line"
  assert_grep 'cooldown=600' "$home/state/.supervision-host-health" "a failed probe must double the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home" 2400
  park_again "$home"
  append_status "$home" 'a later probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the later failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 4 ] || fail "the grown cooldown's end did not let one wake probe the engine"
  assert_grep 'cooldown=3600' "$home/state/.supervision-host-health" "the doubled cooldown must stop at one hour"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  echo handle > "$home/stub-mode"
  handled=$(handled_count "$home")
  park_again "$home"
  append_status "$home" 'the probe succeeds'
  wait_until 250 handled_at_least "$home" $((handled + 1)) \
    || fail "latch: the successful probe was not handled: $(cat "$home/host.out"; tail -n 5 "$home/state/.supervision-host.log")"
  assert_re '	recovered	after a successful probe$' "$home/state/.supervision-host.log" "the ledger must record the recovery"
  ! wait_until 20 host_exited "$home" || fail "a routine probe's recovery reached main: $(cat "$home/host.out")"
  assert_no_re '^supervision-host' "$home/host.out" "a recovery must stay off main"
  assert_grep 'cooldown=0' "$home/state/.supervision-host-health" "a successful probe must clear the latch"
  assert_grep 'errors=0' "$home/state/.supervision-host-health" "a successful probe must clear the error streak"
  pass "host: attended, two engine errors latch the session, main keeps every close unchanged in the cooldown, a failed probe doubles it up to its cap, and a routine probe's recovery stays in the ledger, off main"
}

# The 2026-09-25 away-window flood: a held, green PR on a finished task was
# re-escalated on every inactive-outcome cadence, because the branch
# acknowledgement consumed the check row but left its terminal-outcome receipt
# pending, so each later scan re-queued the same fingerprint. Through the real
# watcher cadence, host, report surface, and drain, that unchanged situation
# now reaches the captain exactly once, and a new event on the same task - a
# decision - still reaches the captain path afterwards.
scan_marker_age() {  # <home> -> seconds since the last inactive-outcome scan
  perl -e 'my @s = stat $ARGV[0] or exit 1; print time - $s[9]' "$1/state/.inactive-outcome-reconcile"
}
scan_ran() { [ "$(scan_marker_age "$1" 2>/dev/null || echo 999999)" -lt 60 ]; }
scan_idle() {  # <home>
  [ ! -e "$1/state/.inactive-outcome-reconcile.lock" ] && [ ! -L "$1/state/.inactive-outcome-reconcile.lock" ]
}
captain_rows() {  # <home>
  local rows
  rows=$(grep -c '"verdict":"captain"' "$1/state/branch-outcomes.jsonl" 2>/dev/null)
  printf '%s\n' "${rows:-0}"
}
captain_rows_at_least() { [ "$(captain_rows "$1")" -ge "$2" ]; }
flood_signal() {  # <home>
  captain_rows_at_least "$1" 2 || grep -qs '	inactive-outcome:' "$1/state/.wake-queue"
}

test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event() {
  local home cycle old pid watcher
  home=$(make_home away-held-once away)
  echo captain > "$home/stub-mode"
  mkdir -p "$home/projects/held"
  git -C "$home/projects/held" init -q
  git -C "$home/projects/held" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  fm_write_meta "$home/state/held.meta" \
    'window=fm-held' "worktree=$home/projects/held" "project=$home/projects/held" \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=g1' \
    'pr=https://example.test/o/r/pull/153'
  printf 'done: PR https://example.test/o/r/pull/153 open, green, mergeable\n' > "$home/state/held.status"
  old=$(( $(date +%s) - 600 ))
  perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" \
    "$home/state/held.meta" "$home/state/held.status" \
    || fail "fixture: could not age the held task's records"
  prime_status_seen "$home/state" "$home/state/held.status"

  export FM_FAKE_CREW_STATE_held='state: done · source: fake'
  export FM_INACTIVE_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_INACTIVE_RECONCILE_SECS=60
  start_host "$home"
  wait_until 250 captain_rows_at_least "$home" 1 \
    || fail "held: the first cadence never escalated the held outcome: $(cat "$home/state/.supervision-host.log" 2>/dev/null)"
  assert_grep 'child=held' "$home/state/branch-outcomes.jsonl" "held: the escalation did not name the held task's outcome: $(cat "$home"/engine-drain.* "$home/state/.supervision-host.log")"
  wait_until 150 handled_at_least "$home" 1 || fail "held: the escalating turn never finished"
  assert_no_grep '	inactive-outcome:' "$home/state/.wake-queue" "held: the branch acknowledgement left the presentation row queued"

  for cycle in 1 2 3 4; do
    old=$(( $(date +%s) - 120 ))
    perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" "$home/state/.inactive-outcome-reconcile" \
      || fail "held: could not age the scan marker before cadence $cycle"
    wait_until 150 scan_ran "$home" || fail "held: cadence $cycle never rescanned"
    wait_until 150 scan_idle "$home" || fail "held: cadence $cycle never finished its scan"
    ! wait_until 10 flood_signal "$home" \
      || fail "held: cadence $cycle re-escalated the unchanged held outcome: $(cat "$home/state/branch-outcomes.jsonl")"
  done
  [ "$(captain_rows "$home")" -eq 1 ] || fail "held: the unchanged situation reached the captain $(captain_rows "$home") times"
  [ -s "$home/host.rc" ] && fail "held: the host handed a wake to main: $(cat "$home/host.out")"

  printf 'needs-decision [key=merge-153]: merge PR 153 now or hold it for the return?\n' >> "$home/state/held.status"
  wait_until 250 captain_rows_at_least "$home" 2 \
    || fail "held: the new decision never reached the captain path: $(cat "$home/state/branch-outcomes.jsonl")"
  [ "$(captain_rows "$home")" -eq 2 ] || fail "held: the decision escalated $(captain_rows "$home") rows, not one"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --recent 1 | sed -n 's/.*"task":"\([^"]*\)".*"verdict":"\([a-z]*\)".*/\1 \2/p')" = 'held captain' ] \
    || fail "held: the decision was not recorded as a captain outcome for the held task: $(cat "$home/state/branch-outcomes.jsonl")"
  unset FM_FAKE_CREW_STATE_held FM_INACTIVE_CREW_STATE_BIN FM_INACTIVE_RECONCILE_SECS
  # Stop the host and its watcher here, so no cadence scan is still writing
  # into this home while the suite's cleanup removes it.
  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "held: the host did not stop on TERM"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "held: a stopped host left its watcher running"
  pass "host: an unchanged held outcome reaches the captain once across cadences, and a later decision on the task still does"
}

test_unverified_engine_hands_every_away_wake_to_main() {
  local home
  home=$(make_home no-engine away 'pi')
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "no engine: the host never started a watcher cycle"
  append_status "$home" 'anything'
  wait_until 200 host_exited "$home" || fail "no engine: the wake did not reach main"
  assert_re "^supervision-host: no supervision engine runs here: config/supervision-host names 'pi', which is not a verified supervision engine" \
    "$home/host.out" "an unverified engine must be named on the wake it hands to main"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "no engine: an engine ran"
  pass "host: a home naming an unverified engine hands every away wake to main with the reason"
}

test_host_outside_the_lock_owner_stands_down() {
  local home out rc other
  home=$(make_home not-owner attended)
  "$FAKE_CLAUDE" -c 'sleep 30' &
  other=$!
  printf '%s\n' "$other" >> "$home/claude-pids"
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$home/fakebin:$PATH" "$HOST" park 2>&1); rc=$?
  expect_code 0 "$rc" "a host that does not own supervision exits 0"
  assert_contains "$out" "supervision-host stood down: this session does not own supervision" "the stand-down must say why"
  watcher_live "$home" && fail "a host that does not own supervision started a watcher"
  kill -TERM "$other" 2>/dev/null || true
  pass "host: a host outside the session-lock owner stands down without arming"
}

test_superseded_host_leaves_the_owner_untouched() {
  local home owner watcher lock_pid
  home=$(make_home superseded away)
  # One fake harness runs the owner host, then, on a signal file, a second host
  # under an auto-arm generation the ledger has already superseded.
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      "$0" park > "$FM_HOME/host.out" 2>&1 &
      while [ ! -e "$FM_HOME/go-second" ]; do sleep 0.1; done
      FM_SUPERVISION_HOST_AUTOARM_GEN=1 FM_SUPERVISION_HOST_OWNER_PID=$$ "$0" park > "$FM_HOME/host2.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host2.rc"
      wait
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "superseded: the owner host never started a watcher cycle"
  owner=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  lock_pid=$(cat "$home/state/.lock")
  printf 'epoch=2 owner_pid=%s outcome=arming\n' "$lock_pid" > "$home/state/.claude-autoarm-epoch"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$lock_pid" "$LEASE" claim demo >/dev/null 2>&1 \
    || fail "fixture: could not hold a branch lease"
  : > "$home/go-second"
  wait_until 200 sh -c '[ -s "$1" ]' _ "$home/host2.rc" || fail "superseded: the second host did not return"
  expect_code 0 "$(cat "$home/host2.rc")" "a superseded host exits 0"
  assert_grep 'supervision-host stood down: this session does not own supervision' "$home/host2.out" "the stand-down must say why"
  kill -0 "$owner" 2>/dev/null || fail "a superseded host stopped the owner host"
  [ "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")" = "$owner" ] \
    || fail "a superseded host took the owner's host record"
  if [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" != "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
    fail "a superseded host stopped the owner's watcher"
  fi
  FM_HOME="$home" "$LEASE" check demo 2>/dev/null | grep -q '^branch ' || fail "a superseded host released the owner's branch leases"
  kill -TERM "$owner"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$owner" "$watcher" \
    || fail "superseded: the owner host did not stop on TERM"
  pass "host: a host under a superseded auto-arm generation stands down without touching the owner"
}

test_latch_trips_after_two_engine_errors_then_probes_and_recovers
test_latch_keeps_attended_closes_on_main_and_skips_unopted_homes
test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main
test_first_cycle_status_streams_and_owner_options_reach_it
test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event
test_unverified_engine_hands_every_away_wake_to_main
test_host_outside_the_lock_owner_stands_down
test_superseded_host_leaves_the_owner_untouched
