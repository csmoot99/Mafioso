#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# slot-injection round-trip through the built page, bind-before-arm, and
# idempotent re-arm of the stable board source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A lavish-axi stub that reproduces the shapes verified against the real
# lavish-axi 0.1.61, because the build's liveness verdict is read from what the
# vendor emits. The load-bearing shape is the refusal: opening a session the
# captain ended from the browser EXITS 0 while reporting `status: user-ended`,
# and that session is absent from the server's listing. `--reopen` restores it.
# Markers under lavish-state drive the fixture: `user-ended` makes the next
# plain open refuse, and `refuse-reopen` makes even --reopen leave it dead.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # Registered with tests/lib.sh, not with a shell array: make_home is called
  # inside a command substitution, so an array append here never reaches the
  # caller and every listener this suite started used to survive the run.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
state=${LAVISH_FAKE_STATE:?}
emit() {  # <canonical-file> <status>
  printf 'session:\n'
  printf '  file: %s\n' "$1"
  printf '  url: "http://127.0.0.1:4387/session/0123456789abcdef"\n'
  printf '  status: %s\n' "$2"
}
case "${1-}" in
  --version) printf '0.1.61\n'; exit 0 ;;
  poll)
    # A real blocking listener: it returns only when the trigger appears, so a
    # live owner in these tests is a live process rather than a timing artifact.
    # Both waits are bounded, so a listener that escapes its test cannot keep
    # spawning processes for as long as the host stays up.
    limit=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
    while [ ! -e "$state/poll-trigger" ]; do
      [ "$SECONDS" -lt "$limit" ] || exit 75
      sleep 0.05
    done
    printf 'session:\n  status: ended\n'
    if [ -e "$state/hold-after-terminal" ]; then
      : > "$state/terminal-emitted"
      while [ -e "$state/hold-after-terminal" ]; do
        [ "$SECONDS" -lt "$limit" ] || exit 75
        sleep 0.05
      done
    fi
    exit 0
    ;;
  '')
    if [ -e "$state/end-before-next-list" ]; then
      : > "$state/open"
      rm -f "$state/end-before-next-list"
    fi
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    if [ -s "$state/open" ]; then
      while IFS= read -r listed; do
        [ -n "$listed" ] || continue
        printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$listed"
      done < "$state/open"
    fi
    exit 0
    ;;
  end) : > "$state/open"; printf 'session:\n  status: ended\n'; exit 0 ;;
esac
file=$1
shift
reopen=0
for arg in "$@"; do [ "$arg" != --reopen ] || reopen=1; done
real=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
if [ -e "$state/user-ended" ] && [ "$reopen" = 0 ]; then
  emit "$real" user-ended
  exit 0
fi
if [ -e "$state/refuse-reopen" ]; then
  emit "$real" user-ended
  exit 0
fi
rm -f -- "$state/user-ended"
printf '%s\n' "$real" > "$state/open"
jq -n --arg file "$real" \
  '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
  > "$state/state.json"
emit "$real" opened
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

end_session_as_captain() { : > "$1/lavish-state/user-ended"; : > "$1/lavish-state/open"; }

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

# Unwrap the report index from its generated classic-script callback.
report_index() {  # <assets-dir>
  perl -0pe 's/\Awindow\.fmBearingsReports\(//; s/\);\n\z//' "$1/.reports/index.js"
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "alarm"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown charted kind was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "warning"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a dispatchable warning row was accepted"

  write_valid_payload "$data"
  jq '.charted_warning_more = -1' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a negative omitted-warning count was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].subject = {"artifact":"quota-axi","version":"0.1"}' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an invalid structured version subject was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.underway = [{"id":"sample-task","repo":"sample","state":"working",
    "kind":"ship","doing":"implementing"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an underway row without an explicit name marker was accepted"

  for invalid_filed in "last Tuesday" "2026-13-01" "2026-08-14T99:30:00Z" "2026-02-29"; do
    write_valid_payload "$data"
    jq --arg filed "$invalid_filed" '.charted[0].filed = $filed' "$data" > "$data.tmp" \
      && mv "$data.tmp" "$data"
    set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "an invalid filed date was accepted: $invalid_filed"
  done

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unanswerable captains_call item was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_build_injects_binds_then_arms() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not report the answer binding: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_present "$board" "build reported success without a board"

  # Round-trip: apart from the reconcile choice the build adds to every
  # decision card, the payload extracted from the built page is the same JSON
  # document, and the escaped </script> string can no longer terminate the
  # data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]' \
    "$home/extracted.json" > "$home/stripped.json"
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]' \
    "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/stripped.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "bound: $sid" "the binding does not name the board source: $out"
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the board source is not bound any-origin"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build injects the payload, binds any-origin, then arms the source"
}

test_registration_cannot_consume_before_any_origin_binding() {
  local home data origin key hold board sid show
  home=$(make_home order-proof)
  data="$home/payload.json"
  origin=order-proof-review
  key=captain-choice
  hold="$origin-decision-$key"
  board="$home/.lavish/bearings-board.html"

  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$origin.meta" "project=$home/projects/sample" "kind=scout"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the order proof" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the order-proof captain hold"

  write_valid_payload "$data"
  jq --arg hold "$hold" '.captains_call[0].key = $hold' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"

  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ -z "${1:-}" ]; then
  printf 'sessions[1]{file,status,url,pending_prompts}:\n'
  [ ! -s "$FM_HOME/order-open" ] \
    || printf '  %s,open,"http://127.0.0.1/session/order",0\n' "$(cat "$FM_HOME/order-open")"
  exit 0
fi
if [ "${1:-}" != poll ]; then
  real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  printf '%s\n' "$real" > "$FM_HOME/order-open"
  mkdir -p "$LAVISH_AXI_STATE_DIR"
  jq -n --arg file "$real" \
    '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:14387/session/0123456789abcdef"}}}' \
    > "$LAVISH_AXI_STATE_DIR/state.json"
  printf 'session:\n  status: opened\n'
  exit 0
fi
cat <<EOF
session:
  status: feedback
  session_ended: false
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Order proof: yes\\n\\nContext data:\\n{\\n  \\"schema\\": \\"fm-bearings-answer.v1\\",\\n  \\"question\\": \\"$ORDER_PROOF_HOLD\\",\\n  \\"selection\\": \\"yes\\",\\n  \\"note\\": \\"\\"\\n}","form",choice,"Order proof: yes"
EOF
SH
  chmod +x "$home/fakebin/lavish-axi"

  ORDER_PROOF_HOLD="$hold" run_board "$home" build "$data" >/dev/null \
    || fail "the order-proof board build failed"

  # Arm starts the listener, which captures the answer and closes the hold on
  # its own schedule after build returns.
  for _ in $(seq 1 100); do
    show=$(cd "$home" && tasks-axi show "$hold" --full) \
      || fail "the order-proof captain hold disappeared"
    case "$show" in *"state: done"*) break ;; esac
    sleep 0.1
  done
  assert_contains "$show" "state: done" \
    "registration consumed its answer before the any-origin binding existed"
  assert_contains "$show" "Resolution mode: answered" \
    "the answer was not closed through the real keyed-answer intake"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the order-proof source did not retain its any-origin binding"
  pass "registration can consume answers only after any-origin binding exists"
}

test_build_does_not_bind_or_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board before its Lavish session existed"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before binding and arming"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

test_charted_kind_is_optional_and_accepts_both_values() {
  local home data
  home=$(make_home chartedkind)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.charted = [
        {"id":"a","repo":"sample","title":"Queued","reason":"","dispatchable":true},
        {"id":"b","repo":"sample","title":"Queued too","reason":"gated","dispatchable":true,"kind":"queued"},
        {"id":"c","repo":"sample","title":"Integrity notice","reason":"main inventory","dispatchable":false,"kind":"warning"}
      ] | .charted_warning_more = 2' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null \
    || fail "an omitted, queued, and warning charted kind was refused"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.charted[] | .kind // "queued"]) == ["queued", "queued", "warning"]
      and .charted_warning_more == 2
  ' >/dev/null || fail "the built board did not carry the charted kinds and omitted-warning count it was given"
  pass "charted kind is optional and accepts queued and warning"
}


# --- part 1: never arm a poll on an ended session ---------------------------

test_build_reopens_a_session_the_captain_ended() {
  local home data board out sid claim old_pid old_token new_pid new_token
  home=$(make_home ended-session)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  sid=$(run_lavish_source_id "$home" "$board")
  claim="$home/procevent-claims/$sid.claim"
  old_pid=$(sed -n '2p' "$claim")
  old_token=$(sed -n '3p' "$claim")

  # The reported case: the captain ends the board from the browser, so opening
  # it again keeps the same session id, reports it ended, and EXITS 0. A build
  # that trusts the exit status arms a poll nothing can ever attach to.
  : > "$home/lavish-state/hold-after-terminal"
  : > "$home/lavish-state/poll-trigger"
  for _ in $(seq 1 100); do
    [ -e "$home/lavish-state/terminal-emitted" ] && break
    sleep 0.05
  done
  [ -e "$home/lavish-state/terminal-emitted" ] \
    || fail "the old listener did not receive its terminal result"
  rm -f "$home/lavish-state/poll-trigger"
  end_session_as_captain "$home"
  out=$(run_board "$home" build "$data") || fail "the rebuild refused a recoverable ended session"
  rm -f "$home/lavish-state/hold-after-terminal"
  assert_contains "$out" "session: reopened" \
    "the rebuild did not reopen the ended session: $out"
  [ ! -e "$home/lavish-state/user-ended" ] \
    || fail "the rebuild reported success while the session was still ended"
  new_pid=$(sed -n '2p' "$claim")
  new_token=$(sed -n '3p' "$claim")
  [ "$new_pid" != "$old_pid" ] || [ "$new_token" != "$old_token" ] \
    || fail "the rebuild accepted the pre-reopen source generation"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the reopened board has no live listener"
  pass "a board build reopens a session the captain ended instead of arming a dead one"
}

test_build_reopens_when_an_opened_session_ends_before_listing() {
  local home data out board sid
  home=$(make_home establish-list-race)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  : > "$home/lavish-state/end-before-next-list"
  out=$(run_board "$home" build "$data") || fail "the raced session build failed: $out"
  assert_contains "$out" "session: reopened" \
    "the build trusted an opened response after the server no longer listed it: $out"
  sid=$(run_lavish_source_id "$home" "$board")
  [ -s "$home/lavish-state/open" ] || fail "the raced session was not live before arming"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the replacement session did not receive a live listener"
  pass "build reopens a session that ends between establish and listing"
}

test_build_refuses_to_arm_when_the_session_stays_ended() {
  local home data rc out sid
  home=$(make_home dead-session)
  data="$home/payload.json"
  write_valid_payload "$data"
  # An ended session that will not come back: the build must stop rather than
  # register a poll against it.
  : > "$home/lavish-state/refuse-reopen"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build armed a poll on a session that stayed ended: $out"
  assert_contains "$out" "ended session" "the refusal did not say why: $out"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board to a session that stayed ended"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board against a session that stayed ended"
  pass "build refuses to arm a poll on a session that stays ended"
}

test_build_starts_a_listener_for_an_already_armed_board() {
  local home data board out sid claim
  home=$(make_home relisten)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  sid=$(run_lavish_source_id "$home" "$board")

  # Registered is not listening: drop the listener the way a crashed generation
  # would, then rebuild. `already-armed` must not be the end of the story.
  claim="$home/procevent-claims/$sid.claim"
  assert_present "$claim" "the first build left no listener to lose"
  kill -KILL -"$(sed -n '2p' "$claim")" 2>/dev/null || true
  kill -KILL "$(sed -n '2p' "$claim")" 2>/dev/null || true
  sleep 1

  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: $sid" "the rebuild re-registered the source: $out"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the rebuilt board is registered but nothing is listening"
  pass "a rebuild starts a listener when an already-armed board has none"
}

# --- part 2: a landed subject is not a live call ----------------------------

test_build_drops_decision_cards_whose_subject_already_landed() {
  local home data board out
  home=$(make_home landed-cards)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq '.captains_call = [
        {"key":"landed-by-task","type":"decision","repo":"sample","title":"Already shipped",
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"timeout-reattach","type":"decision","repo":"sample","title":"Already merged",
         "pr_url":"https://github.com/sample/sample/pull/7",
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"quota-version","type":"decision","repo":"sample","title":"Old quota release",
         "subject":{"artifact":"quota-axi","version":"0.1.37"},
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"still-open","type":"decision","repo":"sample","title":"Genuinely open",
         "subject":{"artifact":"quota-axi","version":"0.2.0"},
         "options":[{"value":"yes","label":"Yes"}]}
      ]
      | .landed = [
        {"id":"landed-by-task","repo":"sample","what":"shipped it","owner":"crew"},
        {"id":"some-other-task","repo":"sample","what":"merged timeout reattach","owner":"crew",
         "pr_url":"https://github.com/sample/sample/pull/7"},
        {"id":"quota-release","repo":"sample","what":"published quota-axi","owner":"crew",
         "subject":{"artifact":"quota-axi","version":"0.1.38"}},
        {"id":"unrelated\nstill-open","repo":"sample","what":"unrelated multiline identity","owner":"crew"}
      ]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the hygiene build failed: $out"
  assert_contains "$out" "dropped-landed-card: landed-by-task" \
    "the build did not report dropping the landed work item card: $out"
  assert_contains "$out" "dropped-landed-card: timeout-reattach" \
    "the build did not report dropping the merged timeout/reattach card: $out"
  assert_contains "$out" "dropped-landed-card: quota-version" \
    "the build did not report dropping the superseded quota-axi version card: $out"
  extract_payload "$board" | jq -e '[.captains_call[].key] == ["still-open"]' >/dev/null \
    || fail "the board dropped an open card or kept one whose subject already landed"
  pass "build drops decision cards whose subject already landed and keeps open ones"
}

test_build_keeps_a_decision_absent_from_the_main_backlog() {
  local home data board out
  home=$(make_home remote-decision-card)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  write_valid_payload "$data"
  jq '.captains_call = [{
        "key":"remote-mate-call","type":"decision","repo":"sample",
        "title":"Remote secondmate decision",
        "options":[{"value":"yes","label":"Yes"}]
      }]
      | .landed = []' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the remote-card build failed: $out"
  assert_not_contains "$out" "dropped-landed-card: remote-mate-call" \
    "an absent remote card was reported as landed: $out"
  extract_payload "$board" | jq -e '
    [.captains_call[] | select(.key == "remote-mate-call")] | length == 1
  ' >/dev/null || fail "the hygiene check dropped a decision absent from the main backlog"
  pass "build keeps remote decisions absent from the main backlog"
}

# --- part 3: every decision card offers reconcile ---------------------------

test_build_fails_when_reconcile_cannot_establish_a_listener() {
  local home data out rc sid
  home=$(make_home no-listener)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "could not establish the listener fixture"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/ps"
  set +e
  out=$(FM_PROC_ROOT_OVERRIDE="$home/no-proc" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  rm -f "$home/fakebin/ps"
  [ "$rc" -ne 0 ] || fail "a build with an uncertain listener reported success: $out"
  assert_contains "$out" "source $sid is not listening after reconcile" \
    "the refusal did not name the source: $out"
  assert_contains "$out" "observed owner: uncertain" \
    "the refusal did not name the observed owner: $out"
  pass "build fails when reconcile cannot prove a live listener"
}

test_every_decision_card_carries_the_reconcile_choice() {
  local home data board
  home=$(make_home reconcile-option)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the reconcile-option build failed"
  extract_payload "$board" | jq -e '
    ([.captains_call[] | select(.type == "decision")] | length) > 0
    and ([.captains_call[]
      | select(.type == "decision")
      | ([.options[] | select(.value == "reconcile")] | length) == 1
        and ([.options[] | select(.value == "reconcile") | .label | length > 0] | all)] | all)
  ' >/dev/null || fail "a decision card was published without the reconcile choice"
  extract_payload "$board" | jq -e '
    ([.captains_call[] | select(.type != "decision")
      | .options[] | select(.value == "reconcile")] | length) == 0
  ' >/dev/null || fail "reconcile was injected into a non-decision card"
  pass "every decision card carries exactly one reconcile choice"
}

test_build_refuses_a_payload_that_occupies_the_reconcile_value() {
  local home data rc out
  home=$(make_home reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[0].options += [{"value":"reconcile","label":"Something else"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a payload occupying the reserved reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused payload still produced a board"
  pass "build refuses a payload that occupies the reserved reconcile value"
}

test_build_refuses_a_nondecision_reconcile_value() {
  local home data rc out
  home=$(make_home merge-reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[1].options += [{"value":"reconcile","label":"Merge action"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a merge card occupying the reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused merge card still produced a board"
  pass "build reserves reconcile across non-decision cards"
}

# --- Captain's Call screenshots ---------------------------------------------
# build copies each listed file beside the board and serves only a relative src.

make_image() {  # <path> [bytes]
  mkdir -p "$(dirname "$1")"
  if [ -n "${2-}" ]; then truncate -s "$2" "$1"; else printf 'not-really-a-png' > "$1"; fi
}

# A decision card named <key> carrying one image per <path> argument.
card_with_images() {  # <key> <path>...
  local key=$1 paths
  shift
  paths=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  jq -n --arg key "$key" --argjson paths "$paths" '
    {key:$key,type:"decision",repo:"sample",title:"Approve the screens",
     options:[{value:"yes",label:"Yes"}],
     images:[$paths | to_entries[] | {path:.value, alt:("screen " + (.key + 1 | tostring))}]}'
}

payload_with_cards() {  # <home> <cards-json-array>
  write_valid_payload "$1/payload.json"
  jq --argjson cards "$2" '.captains_call = $cards' "$1/payload.json" > "$1/payload.tmp" \
    && mv "$1/payload.tmp" "$1/payload.json"
}

test_build_copies_card_images_beside_the_board_and_injects_only_relative_srcs() {
  local home board assets
  home=$(make_home images-copy)
  board="$home/.lavish/bearings-board.html"
  assets="$home/.lavish/bearings-board-assets"
  make_image "$home/src/Home.PNG"
  make_image "$home/src/menu.jpeg"
  make_image "$home/src/report.webp"
  payload_with_cards "$home" "$(jq -n \
    --arg a "$home/src/Home.PNG" --arg b "$home/src/menu.jpeg" --arg c "$home/src/report.webp" \
    '[{key:"screens",type:"decision",repo:"sample",title:"Approve the screens",
       options:[{value:"yes",label:"Yes"}],
       images:[{path:$a,alt:"Home",caption:"The home page"},{path:$b,alt:"Menu",caption:""},{path:$c,alt:"Report"}]}]')"

  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "a payload with images did not build"
  [ "$(find "$assets" -type f | wc -l | tr -d ' ')" = 3 ] || fail "the images were not copied beside the board"
  assert_present "$assets/screens/1.png" "the first image was not copied under its card key"
  assert_present "$assets/screens/2.jpeg" "the second image was not copied under its card key"
  assert_present "$assets/screens/3.webp" "the third image was not copied under its card key"
  extract_payload "$board" | jq -e '
    .captains_call[0].images == [
      {src:"bearings-board-assets/screens/1.png",alt:"Home",caption:"The home page"},
      {src:"bearings-board-assets/screens/2.jpeg",alt:"Menu"},
      {src:"bearings-board-assets/screens/3.webp",alt:"Report"}]' >/dev/null \
    || fail "the page data does not carry exactly the relative src, alt and caption"
  grep -qF "$home/src" "$board" && fail "the page leaked a local image path"
  pass "build copies card images beside the board and injects only relative srcs"
}

test_build_generates_smaller_thumbnails_and_keeps_originals() {
  local board_home board assets thumbnail original
  command -v ffmpeg >/dev/null 2>&1 || { pass "thumbnail generation skipped: optional ffmpeg absent"; return; }
  board_home=$(make_home images-thumbnails)
  mkdir -p "$board_home/src"
  ffmpeg -nostdin -v error -f lavfi -i testsrc=size=780x1688 -frames:v 1 -threads 1 "$board_home/src/screen.png" \
    || fail "cannot generate the screenshot fixture"
  payload_with_cards "$board_home" "[$(card_with_images screens "$board_home/src/screen.png")]"
  run_board "$board_home" build "$board_home/payload.json" >/dev/null 2>&1 || fail "the thumbnail board did not build"
  board="$board_home/.lavish/bearings-board.html"
  assets="$board_home/.lavish"
  original=$(extract_payload "$board" | jq -r '.captains_call[0].images[0].src')
  thumbnail=$(extract_payload "$board" | jq -r '.captains_call[0].images[0].thumbnail')
  assert_present "$assets/$thumbnail" "the generated thumbnail is missing"
  cmp "$board_home/src/screen.png" "$assets/$original" || fail "the original was changed"
  [ "$(wc -c < "$assets/$thumbnail")" -lt "$(wc -c < "$assets/$original")" ] || fail "thumbnail did not reduce image bytes"
  [ "$(wc -c < "$assets/$thumbnail")" -lt 15000 ] || fail "thumbnail exceeds the tile byte target"
  pass "build generates small thumbnails and preserves original images"
}

test_build_without_ffmpeg_preserves_images_and_prints_one_note() {
  local board_home tools out
  board_home=$(make_home images-no-ffmpeg)
  tools="$board_home/without-ffmpeg"
  mkdir -p "$tools"
  # Keep the build's ordinary tools available while making ffmpeg genuinely absent.
  perl -e '
    for $dir (split /:/, $ENV{PATH}) {
      opendir(my $entries, $dir) or next;
      for $name (readdir $entries) {
        next if $name eq "." || $name eq ".." || $name eq "ffmpeg";
        symlink "$dir/$name", "$ARGV[0]/$name" unless -e "$ARGV[0]/$name" || -l "$ARGV[0]/$name";
      }
      closedir $entries;
    }' "$tools"
  PATH="$tools" command -v ffmpeg >/dev/null 2>&1 && fail "ffmpeg is still available in the fallback fixture"
  make_image "$board_home/src/a.png"
  payload_with_cards "$board_home" "[$(card_with_images screens "$board_home/src/a.png" "$board_home/src/a.png")]"
  out=$(PATH="$tools" run_board "$board_home" build "$board_home/payload.json" 2>&1) || fail "a build without ffmpeg failed: $out"
  [ "$(printf '%s' "$out" | grep -c 'thumbnails unavailable')" = 1 ] || fail "fallback did not print exactly one note: $out"
  extract_payload "$board_home/.lavish/bearings-board.html" | jq -e '[.captains_call[].images[] | has("thumbnail")] == [false,false]' >/dev/null \
    || fail "fallback published unavailable thumbnails"
  cmp "$board_home/src/a.png" "$board_home/.lavish/bearings-board-assets/screens/1.png" || fail "fallback did not preserve the original"
  pass "build without ffmpeg preserves original images with one note"
}

test_build_refuses_a_bad_images_field_before_touching_the_board() {
  local home good name filter
  home=$(make_home images-refuse)
  make_image "$home/src/ok.png"
  make_image "$home/src/anim.gif"
  make_image "$home/src/big.png" 5242881
  make_image "$home/src/exact.png" 5242880
  mkdir -p "$home/src/dir.png"
  good=$(card_with_images screens "$home/src/ok.png")
  payload_with_cards "$home" "[$good]"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "the baseline image board did not build"
  cp "$home/.lavish/bearings-board.html" "$home/before.html"

  while IFS='|' read -r name filter; do
    [ -n "$name" ] || continue
    jq --arg home "$home" "$filter" "$home/payload.json" > "$home/bad.json"
    jq empty "$home/bad.json" || fail "the $name case did not produce a payload"
    if run_board "$home" build "$home/bad.json" >/dev/null 2>&1; then
      fail "a payload with $name was accepted"
    fi
    cmp -s "$home/before.html" "$home/.lavish/bearings-board.html" \
      || fail "a refused payload with $name changed the existing board"
    assert_present "$home/.lavish/bearings-board-assets/screens/1.png" \
      "a refused payload with $name disturbed the existing assets"
  done <<'CASES'
a gif|.captains_call[0].images[0].path = ($home + "/src/anim.gif")
a missing file|.captains_call[0].images[0].path = ($home + "/src/none.png")
a directory named like an image|.captains_call[0].images[0].path = ($home + "/src/dir.png")
a file over 5 MB|.captains_call[0].images[0].path = ($home + "/src/big.png")
a relative path|.captains_call[0].images[0].path = "src/ok.png"
a missing alt|del(.captains_call[0].images[0].alt)
an empty alt|.captains_call[0].images[0].alt = ""
a non-string caption|.captains_call[0].images[0].caption = 3
images that are not an array|.captains_call[0].images = "x.png"
25 images|.captains_call[0].images = [range(25) | {path: ($home + "/src/ok.png"), alt: "s"}]
a dot-leading card key|.captains_call[0].key = ".hidden"
CASES

  jq --arg home "$home" '.captains_call[0].images = [range(24) | {path: ($home + "/src/ok.png"), alt: "s"}]' \
    "$home/payload.json" > "$home/max.json"
  run_board "$home" build "$home/max.json" >/dev/null 2>&1 || fail "24 images were refused"
  jq --arg home "$home" '.captains_call[0].images = [{path: ($home + "/src/exact.png"), alt: "s"}]' \
    "$home/payload.json" > "$home/exact.json"
  run_board "$home" build "$home/exact.json" >/dev/null 2>&1 || fail "an image of exactly 5 MB was refused"
  pass "build refuses a bad images field before touching the board and accepts the caps themselves"
}

test_build_clears_stale_images_on_every_rebuild() {
  local home assets
  home=$(make_home images-stale)
  assets="$home/.lavish/bearings-board-assets"
  make_image "$home/src/a.png"
  make_image "$home/src/b.png"
  payload_with_cards "$home" "[$(card_with_images card-a "$home/src/a.png" "$home/src/b.png")]"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "the first image build failed"
  assert_present "$assets/card-a/2.png" "the first build did not copy both images"
  printf 'stray' > "$assets/card-a/stray.png"

  payload_with_cards "$home" "[$(card_with_images card-b "$home/src/a.png")]"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "the second image build failed"
  [ "$(find "$assets" -type f | sed "s|^$assets/||")" = "card-b/1.png" ] \
    || fail "stale images survived a rebuild: $(find "$assets" -type f)"

  payload_with_cards "$home" '[]'
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "the image-free rebuild failed"
  [ -z "$(find "$assets" -type f)" ] || fail "images survived a rebuild with no image cards"
  pass "build clears stale images on every rebuild"
}

test_build_does_not_copy_images_of_a_dropped_landed_card() {
  local home
  home=$(make_home images-dropped)
  make_image "$home/src/a.png"
  payload_with_cards "$home" "[$(card_with_images landed-by-task "$home/src/a.png")]"
  jq '.landed = [{"id":"landed-by-task","repo":"sample","what":"shipped it","owner":"crew"}]' \
    "$home/payload.json" > "$home/payload.tmp" && mv "$home/payload.tmp" "$home/payload.json"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "the build failed"
  [ -z "$(find "$home/.lavish/bearings-board-assets" -type f)" ] \
    || fail "the images of a card the build dropped were still copied"
  pass "build does not copy the images of a card it dropped as landed"
}

# --- Reports ------------------------------------------------------------------
# build renders each listed markdown report into an inert page beside the board.

make_report() {  # <path> [markdown]
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "${2:-# A report\n\nbody}" > "$1"
}

payload_with_reports() {  # <home> <reports-json-array>
  write_valid_payload "$1/payload.json"
  jq --argjson reports "$2" '.reports = $reports' "$1/payload.json" > "$1/payload.tmp" \
    && mv "$1/payload.tmp" "$1/payload.json"
}

report_entry() {  # <title> <path>
  jq -n --arg title "$1" --arg path "$2" \
    '{title:$title,repo:"sample",date:"2026-11-02",summary:"One line",path:$path}'
}

test_build_validates_underway_progress() {
  local home data rc good bad
  home=$(make_home underway-progress)
  data="$home/payload.json"
  good='{"id":"t","repo":"r","name":"A feature","state":"working","kind":"ship","doing":"building",
    "progress":{"stage":"owner","reached":"checks","pct":90,"parts":[
      {"label":"One","state":"merged"},{"label":"Two","state":"current"},{"label":"Three","state":"pending"}]}}'
  write_valid_payload "$data"
  jq --argjson row "$good" '.underway = [$row]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null 2>&1 || fail "a valid progress row did not build"
  extract_payload "$home/.lavish/bearings-board.html" \
    | jq -e '.underway[0].progress | .stage == "owner" and .reached == "checks" and .pct == 90 and (.parts | length) == 3' >/dev/null \
    || fail "the progress row did not reach the built page"
  for bad in \
    '.progress.stage = "napping"' \
    '.progress.stage = "tests"' \
    '.progress.reached = "tests"' \
    '.progress.reached = "owner"' \
    '.progress.stage = "building"' \
    '.progress |= del(.reached)' \
    '.progress.pct = 101' \
    '.progress.pct = 12.5' \
    '.progress.pct = "60"' \
    '.progress.parts = []' \
    '.progress.parts[1].state = "done"' \
    '.progress.parts[0].label = ""' \
    '.progress.parts = [{"label":"A","state":"pending"},{"label":"B","state":"merged"}]' \
    '.progress.parts = [{"label":"A","state":"current"},{"label":"B","state":"current"}]' \
    '.progress.parts = [range(41) | {label:"p",state:"pending"}]' \
    '.progress = "owner"'; do
    write_valid_payload "$data"
    jq --argjson row "$good" ".underway = [\$row | $bad]" "$data" > "$data.tmp" && mv "$data.tmp" "$data"
    set +e; run_board "$home" build "$data" >/dev/null 2>&1; rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "an invalid progress field was accepted: $bad"
  done
  write_valid_payload "$data"
  jq '.underway = [{"id":"t","repo":"r","name":"No bars","state":"working","kind":"ship","doing":"x"}]' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null 2>&1 || fail "an underway row without progress stopped building"
  pass "build validates the optional underway progress field and keeps rows without it"
}

test_a_payload_without_reports_builds_as_before() {
  local home board
  home=$(make_home reports-absent)
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$home/payload.json"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "a payload with no reports did not build"
  extract_payload "$board" | jq -e 'has("reports") | not' >/dev/null \
    || fail "a payload with no reports grew a reports field"
  [ ! -e "$home/.lavish/bearings-board-assets/.reports" ] || fail "a payload with no reports published a reports folder"
  payload_with_reports "$home" '[]'
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "a payload with an empty reports list did not build"
  extract_payload "$board" | jq -e '.reports == []' >/dev/null || fail "an empty reports list was not kept as it was"
  [ ! -e "$home/.lavish/bearings-board-assets/.reports" ] || fail "an empty reports list published a reports folder"
  pass "a payload without reports builds as before"
}

test_build_publishes_each_report_beside_the_board_and_injects_only_relative_srcs() {
  local home board assets
  home=$(make_home reports-publish)
  board="$home/.lavish/bearings-board.html"
  assets="$home/.lavish/bearings-board-assets"
  make_report "$home/data/scout-a/report.md" '# Scout A\n\nfound it'
  make_report "$home/data/status-report-2026-11-02.md" '# Status'
  payload_with_reports "$home" "[$(report_entry "Scout A" "$home/data/scout-a/report.md"),$(report_entry "Status" "$home/data/status-report-2026-11-02.md")]"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "a payload with reports did not build"
  [ "$(find "$assets/.reports" -type f | wc -l | tr -d ' ')" = 3 ] || fail "the reports were not published beside the board"
  assert_present "$assets/.reports/1.html" "the first report was not published"
  grep -q "Scout A" "$assets/.reports/1.html" || fail "the first published page is not the first report"
  grep -q "Status" "$assets/.reports/2.html" || fail "the second published page is not the second report"
  extract_payload "$board" | jq -e '.reports_count == 2 and (has("reports") | not) and ([.. | objects | has("text")] | any | not)' >/dev/null \
    || fail "report metadata or text remained in the inline page data"
  report_index "$assets" | jq -e '
    (map(del(.text))) == [
      {title:"Scout A",repo:"sample",date:"2026-11-02",summary:"One line",src:"bearings-board-assets/.reports/1.html"},
      {title:"Status",repo:"sample",date:"2026-11-02",summary:"One line",src:"bearings-board-assets/.reports/2.html"}]' >/dev/null \
    || fail "the page data does not carry exactly the title, project, date, summary and relative src"
  report_index "$assets" | jq -e '(.[0].text | startswith("Scout A")) and .[1].text == "Status"' >/dev/null \
    || fail "the external index does not carry each report's search text"
  grep -qF "$home/data" "$board" && fail "the page leaked a local report path"
  # a rebuild replaces the folder, so a dropped report cannot linger
  payload_with_reports "$home" "[$(report_entry "Status" "$home/data/status-report-2026-11-02.md")]"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "the rebuild failed"
  [ "$(find "$assets/.reports" -type f | wc -l | tr -d ' ')" = 2 ] || fail "a dropped report survived a rebuild"
  pass "build publishes each report beside the board and injects only relative srcs"
}

test_build_refuses_a_report_outside_data_a_symlink_or_a_non_markdown_file() {
  local home name filter out
  home=$(make_home reports-refuse)
  make_report "$home/data/ok/report.md"
  make_report "$home/outside/secret.md"
  make_report "$home/data/notes.txt"
  make_report "$home/data/big/report.md"
  truncate -s 2097153 "$home/data/big/report.md"
  mkdir -p "$home/data/dir.md"
  ln -s "$home/data/ok/report.md" "$home/data/link.md"
  ln -s "$home/outside/secret.md" "$home/data/escape.md"
  ln -s "$home/outside" "$home/data/outdir"
  payload_with_reports "$home" "[$(report_entry "Fine" "$home/data/ok/report.md")]"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "the baseline reports board did not build"
  cp "$home/.lavish/bearings-board.html" "$home/before.html"

  while IFS='|' read -r name want filter; do
    [ -n "$name" ] || continue
    jq --arg home "$home" "$filter" "$home/payload.json" > "$home/bad.json"
    jq empty "$home/bad.json" || fail "the $name case did not produce a payload"
    if out=$(run_board "$home" build "$home/bad.json" 2>&1); then
      fail "a payload with $name was accepted"
    fi
    printf '%s' "$out" | grep -qF -- "$want" || fail "the refusal of $name did not say '$want': $out"
    cmp -s "$home/before.html" "$home/.lavish/bearings-board.html" \
      || fail "a refused payload with $name changed the existing board"
    assert_present "$home/.lavish/bearings-board-assets/.reports/1.html" \
      "a refused payload with $name disturbed the existing assets"
  done <<'CASES'
a path outside data|resolves outside|.reports[0].path = ($home + "/outside/secret.md")
a traversal out of data|resolves outside|.reports[0].path = ($home + "/data/../outside/secret.md")
a symlink inside data|is a symlink|.reports[0].path = ($home + "/data/link.md")
a symlink out of data|is a symlink|.reports[0].path = ($home + "/data/escape.md")
a symlinked folder out of data|resolves outside|.reports[0].path = ($home + "/data/outdir/secret.md")
a text file|does not end in .md|.reports[0].path = ($home + "/data/notes.txt")
a directory named like a report|not a readable regular file|.reports[0].path = ($home + "/data/dir.md")
a missing file|not a readable regular file|.reports[0].path = ($home + "/data/none.md")
a relative path|not absolute|.reports[0].path = "data/ok/report.md"
a report over 2 MB|larger than|.reports[0].path = ($home + "/data/big/report.md")
a bad date||.reports[0].date = "2026-13-40"
a date with a time||.reports[0].date = "2026-11-02T10:00:00Z"
an empty title||.reports[0].title = ""
a multi-line summary||.reports[0].summary = "one\ntwo"
a missing summary||del(.reports[0].summary)
a missing repo||del(.reports[0].repo)
a numeric repo||.reports[0].repo = 4
reports that are not an array||.reports = {}
501 reports||.reports[0] as $r | .reports = [range(501) | $r]
CASES
  jq --argjson r "$(jq '.reports[0]' "$home/payload.json")" '.reports = [range(500) | $r]' "$home/payload.json" > "$home/max.json"
  run_board "$home" build "$home/max.json" >/dev/null 2>&1 || fail "500 reports were refused"
  pass "build refuses a report outside data, a symlink or a non-markdown file before touching the board"
}

test_a_report_with_script_and_html_is_neutralised_in_the_published_page() {
  local home page
  home=$(make_home reports-hostile)
  page="$home/.lavish/bearings-board-assets/.reports/1.html"
  make_report "$home/data/evil/report.md" '# Evil <script>fetch("https://evil.example/x")</script>

<img src="https://evil.example/p.png" onerror="alert(1)"> <iframe src="https://evil.example"></iframe>

[js](javascript:alert(1)) ![remote](https://evil.example/i.png) [ok](https://example.com/a?b=1&c=2)

```html
<script>alert(2)</script>
```'
  payload_with_reports "$home" "[$(report_entry "Evil" "$home/data/evil/report.md")]"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "a hostile report stopped the build"
  grep -qiE '<(script|iframe|img|object|embed|link|svg|form|base)[ >/]' "$page" \
    && fail "the published page carries a raw active tag: $(grep -iE '<(script|iframe|img|object|embed)' "$page" | head -3)"
  grep -qE 'href="javascript:' "$page" && fail "the published page links to a javascript: address"
  grep -q '&lt;script&gt;' "$page" || fail "the script text was not kept as visible text"
  grep -q 'Content-Security-Policy" content="default-src '"'"'none'"'"'' "$page" \
    || fail "the published page does not deny every external request"
  [ "$(grep -o 'href="[^"]*"' "$page" | grep -vc -e '^href="https://' -e '^href="data:text/markdown;charset=utf-8;base64,')" = 0 ] \
    || fail "the published page has a link that is neither https nor its own Markdown download"
  [ "$(grep -o 'href="data:' "$page" | wc -l | tr -d ' ')" = 1 ] || fail "the published page does not have exactly one download link"
  grep -q 'href="https://example.com/a?b=1&amp;c=2" target="_blank" rel="noopener noreferrer"' "$page" \
    || fail "an https link did not open as a plain new-tab link"
  pass "a report with script and HTML is neutralised in the published page"
}

test_each_report_page_downloads_the_original_and_the_board_carries_a_capped_search_index() {
  local home board assets href name want
  home=$(make_home reports-download)
  board="$home/.lavish/bearings-board.html"
  assets="$home/.lavish/bearings-board-assets"
  make_report "$home/data/scout-a/report.md" $'# Scout: Ünï & more!\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [link](https://x.test) item\n\n```\ncode\n```'
  { printf '# Long\n\n'; head -c 300000 /dev/zero | tr '\0' 'w'; printf ' tail-marker\n'; } > "$home/data/long.md"
  payload_with_reports "$home" "[$(report_entry "Scout: Ünï & more!" "$home/data/scout-a/report.md"),$(report_entry "Long" "$home/data/long.md")]"
  run_board "$home" build "$home/payload.json" >/dev/null 2>&1 || fail "a payload with a long report did not build"
  href=$(sed -n 's/.*<a download="[^"]*" href="data:text\/markdown;charset=utf-8;base64,\([^"]*\)".*/\1/p' "$assets/.reports/1.html")
  [ "$(printf '%s' "$href" | base64 -d)" = "$(cat "$home/data/scout-a/report.md")" ] \
    || fail "the Download link does not carry the original report bytes"
  name=$(sed -n 's/.*<a download="\([^"]*\)".*/\1/p' "$assets/.reports/1.html")
  [ "$name" = "2026-11-02-scout-n-more.md" ] || fail "the download is not named <date>-<title-slug>.md: $name"
  grep -qiE '<script|https?://[^"]*"? *(src|href)=' "$assets/.reports/1.html" && fail "the report page is not inert"
  report_index "$assets" | jq -e '
    (.[0].text | contains("Scout") and (contains("|") | not) and (contains("---") | not) and (contains("```") | not) and contains("link item"))
    and (.[1].text | length == 6000 and (contains("tail-marker") | not))' >/dev/null \
    || fail "the search index is not plain, capped text"
  want=$(( $(grep -c . "$board") ))
  [ "$want" -gt 0 ] || fail "empty board"
  pass "each report page downloads the original and the board carries a capped search index"
}

test_path_is_stable_and_home_scoped
test_build_refuses_malformed_payloads_before_touching_the_board
test_charted_kind_is_optional_and_accepts_both_values
test_build_injects_binds_then_arms
test_registration_cannot_consume_before_any_origin_binding
test_build_does_not_bind_or_arm_when_session_start_fails
test_rebuild_is_idempotent_and_does_not_double_arm
test_build_refuses_a_template_without_exactly_one_slot
test_build_reopens_a_session_the_captain_ended
test_build_reopens_when_an_opened_session_ends_before_listing
test_build_refuses_to_arm_when_the_session_stays_ended
test_build_starts_a_listener_for_an_already_armed_board
test_build_drops_decision_cards_whose_subject_already_landed
test_build_keeps_a_decision_absent_from_the_main_backlog
test_build_fails_when_reconcile_cannot_establish_a_listener
test_every_decision_card_carries_the_reconcile_choice
test_build_refuses_a_payload_that_occupies_the_reconcile_value
test_build_refuses_a_nondecision_reconcile_value
test_build_copies_card_images_beside_the_board_and_injects_only_relative_srcs
test_build_generates_smaller_thumbnails_and_keeps_originals
test_build_without_ffmpeg_preserves_images_and_prints_one_note
test_build_refuses_a_bad_images_field_before_touching_the_board
test_build_clears_stale_images_on_every_rebuild
test_build_does_not_copy_images_of_a_dropped_landed_card
test_build_validates_underway_progress
test_a_payload_without_reports_builds_as_before
test_build_publishes_each_report_beside_the_board_and_injects_only_relative_srcs
test_build_refuses_a_report_outside_data_a_symlink_or_a_non_markdown_file
test_a_report_with_script_and_html_is_neutralised_in_the_published_page
test_each_report_page_downloads_the_original_and_the_board_carries_a_capped_search_index
