#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the tab bar, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits, and records that
  # session in this home's own store. The listener resolves its server from that
  # store; the machine-wide default has no session for this board.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # The build's listening sample can land before this process resolves a
    # session. Recording entry makes that gap observable: a claim that dies
    # without reaching poll is not a listener.
    printf 'entered\n' > "$FM_HOME/stub-poll"
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    jq -n --arg file "$real" \
      '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
      > "$LAVISH_AXI_STATE_DIR/state.json"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# The build treats a claimed runner as listening before that runner resolves a
# Lavish session. Wait until the stub poll is entered or the source is no longer
# live, and require both: a claim that dies in the gap is the flake.
require_listener_reached_poll() {  # <home>
  local home=$1 i=0 owner=''
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    owner=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      LAVISH_AXI_STATE_DIR="$home/lavish-state" \
      "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
      | awk 'NR > 1 { print $3; exit }')
    if [ -s "$home/stub-poll" ] && [ "$owner" = live ]; then
      return 0
    fi
    case "$owner" in
      none|orphaned)
        if [ -s "$home/stub-poll" ]; then
          fail "the board listener reached the Lavish poll and then exited (owner: $owner)"
        fi
        fail "the board listener exited before it reached the Lavish poll (owner: $owner)"
        ;;
    esac
    sleep 0.05
  done
  fail "the board listener did not reach the Lavish poll (owner: ${owner:-none})"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.tabs[] | select(.label == "Charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and (.sub | test("no-mistakes: review round 2"))
          and (.sub | test("ship")) and (.sub | test("firstmate"))
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_underway_progress_renders_feature_part_and_stage_bars() {
  local home out
  home=$(make_home underway-progress)
  out=$(render_board "$home" '[
    {"id":"feat","repo":"sample","name":"A feature","state":"parked","kind":"ship","doing":"parked at ci",
     "progress":{"stage":"owner","reached":"checks","pct":90,"parts":[
       {"label":"One","state":"merged"},{"label":"Two","state":"current"},{"label":"Three","state":"pending"}]}},
    {"id":"one","repo":"sample","name":"One-off","state":"working","kind":"ship","doing":"ci",
     "progress":{"stage":"checks","reached":"checks","pct":90}},
    {"id":"lost","repo":"sample","name":"Lost worker","state":"unknown","kind":"ship","doing":"worktree gone",
     "progress":{"stage":"stuck","reached":"validating","pct":75}},
    {"id":"old","repo":"sample","name":"No progress","state":"working","kind":"ship","doing":"x"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    .underway[0] as $f | .underway[1] as $o | .underway[2] as $l | .underway[3] as $old
    | ([$f.badges[].text] == ["parked"] and $f.waiting == ["Waiting on you"]
       and ($f.bars | map([.label, .value, .max, .text]) == [
         ["Feature","33","100","1 of 3 parts merged"],
         ["Part 1: One","100","100","Merged"],
         ["Part 2: Two","90","100","PR checks · waiting on owner"],
         ["Part 3: Three","0","100","Not started"]])
       and ($f.bars[2].owner == true) and ($f.bars[1].owner == false))
      and ($o.badges == [] and $o.waiting == []
       and ($o.bars | map([.label, .value, .text]) == [["This task","90","PR checks · 90%"]]))
      and ([$l.badges[].text] == ["unknown"] and $l.waiting == []
       and ($l.bars | map([.label, .value, .text, .stuck]) == [["This task","75","Validating · stuck",true]]))
      and ([$old.badges[].text] == ["working"] and $old.bars == [])
  ' >/dev/null || fail "the Underway progress bars did not render as specified: $out"
  pass "Underway shows a feature bar, one bar per part, marker bars that keep their fill and state pill, and keeps the pill when there is no progress"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and (.sub | startswith("fixing the failing check · "))
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

# Build the board from <cards-json> alone (Captain's Call items whose images
# already carry the relative src build injects) and return what rendered.
render_cards() {  # <home> <cards-json>
  local home=$1 data="$1/payload.json"
  jq -n --argjson cards "$2" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:$cards, underway:[], landed:[], charted:[]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

test_a_card_with_images_renders_one_lazy_thumbnail_per_image() {
  local home out src
  home=$(make_home card-images)
  mkdir -p "$home/src"
  src="$home/src/a.png"
  printf 'x' > "$src"
  out=$(render_cards "$home" "$(jq -n --arg p "$src" '[
    {key:"with-shots",type:"decision",repo:"sample",title:"Has screenshots",
     options:[{value:"yes",label:"Yes"}],
     images:[{path:$p,alt:"First screen",caption:"Cap"},{path:$p,alt:"Second screen"}]},
    {key:"no-shots",type:"decision",repo:"sample",title:"Has none",
     options:[{value:"yes",label:"Yes"}]}]')")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the cards: $out"
  printf '%s' "$out" | jq -e '
    (.cards | length) == 2
      and (.cards[0] | .title == "Has screenshots"
        and .images == [
          {src:"bearings-board-assets/with-shots/1.png",alt:"First screen",lazy:true},
          {src:"bearings-board-assets/with-shots/2.png",alt:"Second screen",lazy:true}])
      and (.cards[1].images == [])
  ' >/dev/null || fail "a card did not render its screenshots as lazy thumbnails with alt text: $out"
  pass "a card with images renders one lazy thumbnail per image and a card without renders none"
}

test_an_image_outside_the_board_assets_folder_is_not_rendered() {
  local home out board
  home=$(make_home card-foreign-image)
  mkdir -p "$home/src"
  printf 'x' > "$home/src/a.png"
  render_cards "$home" "$(jq -n --arg p "$home/src/a.png" '[
    {key:"foreign",type:"decision",repo:"sample",title:"Foreign srcs",
     options:[{value:"yes",label:"Yes"}],
     images:[{path:$p,alt:"local"},{path:$p,alt:"remote"},{path:$p,alt:"ours"}]}]')" >/dev/null
  # build only ever writes relative srcs, so point two of them elsewhere in the
  # built page, as a tampered board would.
  board="$home/.lavish/bearings-board.html"
  sed -i -e 's|bearings-board-assets/foreign/1.png|/etc/passwd|' \
    -e 's|bearings-board-assets/foreign/2.png|https://example.com/x.png|' "$board"
  out=$(node "$HARNESS" "$board") || fail "the tampered board could not be rendered"
  printf '%s' "$out" | jq -e '
    [.cards[0].images[] | .src] == ["bearings-board-assets/foreign/3.png"]
  ' >/dev/null || fail "a src outside the board assets folder was rendered: $out"
  pass "an image src outside the board assets folder is not rendered"
}

# Two freeform decision cards, enough to deal from one to the next.
two_cards() {
  jq -n '[
    {key:"first",type:"decision",repo:"sample",title:"First call",
     options:[{value:"yes",label:"Yes"},{value:"approve-with-changes",label:"Approve with changes"}],
     allow_freeform:true},
    {key:"second",type:"decision",repo:"sample",title:"Second call",
     options:[{value:"yes",label:"Yes"}],allow_freeform:true}]'
}

test_the_sections_are_tabs_with_counts_and_only_the_selected_one_shows() {
  local home out
  home=$(make_home tabs)
  out=$(render_cards "$home" "$(two_cards)")
  printf '%s' "$out" | jq -e '
    [.tabs[] | {id, label, n, selected, tabindex, role, controls, panelRole, panelLabelledby}] == [
      {id:"bb-tab-call",label:"Captain'"'"'s Call",n:2,selected:"true",tabindex:0,role:"tab",controls:"bb-sec-call",panelRole:"tabpanel",panelLabelledby:"bb-tab-call"},
      {id:"bb-tab-underway",label:"Underway",n:0,selected:"false",tabindex:-1,role:"tab",controls:"bb-sec-underway",panelRole:"tabpanel",panelLabelledby:"bb-tab-underway"},
      {id:"bb-tab-landed",label:"Recently landed",n:0,selected:"false",tabindex:-1,role:"tab",controls:"bb-sec-landed",panelRole:"tabpanel",panelLabelledby:"bb-tab-landed"},
      {id:"bb-tab-charted",label:"Charted next",n:0,selected:"false",tabindex:-1,role:"tab",controls:"bb-sec-charted",panelRole:"tabpanel",panelLabelledby:"bb-tab-charted"}]
    and .loaded == ["call"]
  ' >/dev/null || fail "the board did not open on a Captain's Call tab with a counted, labelled tab per section: $out"
  printf '%s' "$out" | jq -e '
    [.tabClicks[] | {id, visible, selected}] == [
      {id:"bb-tab-call",visible:["call"],selected:["bb-tab-call"]},
      {id:"bb-tab-underway",visible:["underway"],selected:["bb-tab-underway"]},
      {id:"bb-tab-landed",visible:["landed"],selected:["bb-tab-landed"]},
      {id:"bb-tab-charted",visible:["charted"],selected:["bb-tab-charted"]}]
    and ([.tabClicks[] | .tabindexes | add] | all(. == -3))
  ' >/dev/null || fail "tapping a tab did not show exactly its own section: $out"
  printf '%s' "$out" | jq -e '.tabClicks[-1] | .hash == "#charted" and .name == "fm-bearings-tab=charted"' >/dev/null \
    || fail "the selected tab was not remembered in the address and the frame name: $out"
  pass "the sections are tabs with counts and only the selected one shows"
}

test_the_tab_bar_answers_to_the_arrow_home_and_end_keys() {
  local home out
  home=$(make_home tab-keys)
  out=$(render_cards "$home" "$(two_cards)")
  printf '%s' "$out" | jq -e '
    .keys.right == {selected:["bb-tab-underway"],visible:["underway"],prevented:true,focused:"bb-tab-underway"}
    and .keys.left == {selected:["bb-tab-charted"],visible:["charted"],prevented:true,focused:"bb-tab-charted"}
    and .keys.end.selected == ["bb-tab-charted"] and .keys.home.selected == ["bb-tab-call"]
    and .keys.other == {selected:["bb-tab-call"],visible:["call"],prevented:false,focused:"bb-tab-call"}
  ' >/dev/null || fail "the arrow, Home and End keys did not move the selected tab (or a stray key did): $out"
  pass "the tab bar answers to the arrow, Home and End keys"
}

test_queuing_an_answer_keeps_the_captains_call_tab_selected() {
  local home out
  home=$(make_home tab-answer)
  out=$(render_cards "$home" "$(two_cards)")
  printf '%s' "$out" | jq -e '.answerKeepsTab == ["call"]' >/dev/null \
    || fail "queuing answers changed the visible tab: $out"
  pass "queuing an answer keeps the Captain's Call tab selected"
}

# Render the built board for a returning viewer: <hash> <window.name> <localStorage json or blocked>.
render_returning() {  # <home> <hash> <name> <store> [with-reports]
  local home=$1
  if [ "${5-}" = with-reports ]; then
    render_reports "$home" "$(reports_json "$home")" >/dev/null
  else
    render_cards "$home" "$(two_cards)" >/dev/null
  fi
  BOARD_HASH=$2 BOARD_NAME=$3 BOARD_STORE=$4 node "$HARNESS" "$home/.lavish/bearings-board.html" | jq -c '.loaded'
}

test_the_selected_tab_is_restored_from_the_hash_then_storage_then_the_frame_name() {
  local home
  home=$(make_home tab-restore)
  [ "$(render_returning "$home" '#landed' '' '{}')" = '["landed"]' ] || fail "the URL hash did not restore its tab"
  [ "$(render_returning "$home" '' '' '{"fm-bearings-tab":"charted"}')" = '["charted"]' ] \
    || fail "the stored tab was not restored without a hash"
  [ "$(render_returning "$home" '#underway' '' '{"fm-bearings-tab":"charted"}')" = '["underway"]' ] \
    || fail "storage outranked the URL hash"
  [ "$(render_returning "$home" '' 'fm-bearings-tab=landed' 'blocked')" = '["landed"]' ] \
    || fail "a board whose storage is blocked did not restore the tab from the frame name"
  [ "$(render_returning "$home" '' 'someone-elses-name' 'blocked')" = '["call"]' ] \
    || fail "a blocked-storage board without a remembered tab did not open on Captain's Call"
  [ "$(render_returning "$home" '#nonsense' '' '{"fm-bearings-tab":"nope"}')" = '["call"]' ] \
    || fail "an unknown tab did not fall back to Captain's Call"
  [ "$(render_returning "$home" '#reports' '' '{}')" = '["call"]' ] \
    || fail "a remembered Reports tab on a board with no reports did not fall back to Captain's Call"
  pass "the selected tab is restored from the hash, then storage, then the frame name"
}

# Two real report files under the home's data directory, plus one in another project.
reports_json() {  # <home>
  local home=$1 i
  mkdir -p "$home/data/r1" "$home/data/r2" "$home/data/r3"
  for i in 1 2 3; do printf '# Report %s\n\nbody %s\n' "$i" "$i" > "$home/data/r$i/report.md"; done
  jq -n --arg d "$home/data" '[
    {title:"Older alpha write-up",repo:"alpha",date:"2026-10-30",summary:"",path:($d + "/r1/report.md")},
    {title:"Newest sync scout",repo:"alpha",date:"2026-11-02",summary:"Why the sync stalls",path:($d + "/r2/report.md")},
    {title:"Beta sync status",repo:null,date:"2026-11-01",summary:"Status of the sync work",path:($d + "/r3/report.md")}]'
}

render_reports() {  # <home> <reports-json>
  local home=$1 data="$1/payload.json"
  jq -n --argjson reports "$2" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[], charted:[], reports:$reports}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

test_a_board_with_reports_gets_a_reports_tab_listing_them_newest_first() {
  local home out
  home=$(make_home reports-tab)
  out=$(render_reports "$home" "$(reports_json "$home")")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null || fail "the board rendered its error instead of the reports: $out"
  printf '%s' "$out" | jq -e '
    ([.tabs[] | .label] | last) == "Reports" and (.tabs[-1] | .n == 3 and .controls == "bb-sec-reports")
    and .reports.count == "3 reports"
    and [.reports.rows[] | .title] == ["Newest sync scout","Beta sync status","Older alpha write-up"]
    and .reports.rows[0] == {title:"Newest sync scout",meta:"alpha · 2026-11-02",summary:"Why the sync stalls"}
    and .reports.rows[1].meta == "(no project) · 2026-11-01"
    and .reports.rows[2].summary == null
    and [.reports.projects[] | .label] == ["All projects","(no project) (1)","alpha (2)"]
  ' >/dev/null || fail "the Reports tab did not list the reports newest first with title, project, date and summary: $out"
  printf '%s' "$out" | jq -e '.tabClicks[-1] | .visible == ["reports"]' >/dev/null \
    || fail "the Reports tab did not show its own section: $out"
  pass "a board with reports gets a Reports tab listing them newest first"
}

test_the_reports_filters_narrow_the_list_by_text_and_project() {
  local home out
  home=$(make_home reports-filter)
  out=$(render_reports "$home" "$(reports_json "$home")")
  printf '%s' "$out" | jq -e '
    .reports.byText == {rows:["Newest sync scout","Beta sync status"],status:"2 of 3 reports",empty:false}
    and .reports.byProject.rows == ["Newest sync scout","Older alpha write-up"]
    and .reports.byBoth == {rows:["Newest sync scout"],status:"1 of 3 reports",empty:false}
    and .reports.noMatch == {rows:[],status:"0 of 3 reports",empty:true}
  ' >/dev/null || fail "the text and project filters did not narrow the reports: $out"
  pass "the reports filters narrow the list by text and project"
}

test_a_report_opens_in_a_scriptless_reader_with_a_way_back() {
  local home out
  home=$(make_home reports-reader)
  out=$(render_reports "$home" "$(reports_json "$home")")
  printf '%s' "$out" | jq -e '
    .reports.opened == {src:"bearings-board-assets/.reports/2.html",hidden:false,title:"Newest sync scout",locked:true}
    and .reports.closed == {src:null,hidden:true,locked:false}
    and .reports.escapeCloses == true
  ' >/dev/null || fail "a report did not open full screen in the reader and close again: $out"
  pass "a report opens in a reader with a way back"
}

test_a_board_without_reports_has_no_reports_tab() {
  local home out
  home=$(make_home reports-absent)
  out=$(render_cards "$home" "$(two_cards)")
  printf '%s' "$out" | jq -e '([.tabs[] | .label] | index("Reports")) == null and .reports == {rows:[],status:"",moreHidden:false,moreLabel:"",count:"",projects:[]}' >/dev/null \
    || fail "a board with no reports grew a Reports tab: $out"
  out=$(render_reports "$home" '[]')
  printf '%s' "$out" | jq -e '([.tabs[] | .label] | index("Reports")) == null' >/dev/null \
    || fail "a board with an empty reports list grew a Reports tab: $out"
  pass "a board without reports has no Reports tab"
}

test_a_note_stops_at_the_cap_while_typing_and_the_cap_leaves_room_for_the_label() {
  local home out
  home=$(make_home note-cap)
  out=$(render_cards "$home" "$(two_cards)")
  # The answer reaches firstmate as "<title> -> <selection> - <note>" and the answer
  # path keeps 512 bytes of it: 512 - len("First call -> ") - (len("approve-with-changes") + 3).
  # build adds the reserved "reconcile" option, so a card of short options reserves 9 + 3.
  printf '%s' "$out" | jq -e '
    .cards[0].note
      | .tag == "textarea" and .maxLength == (512 - 14 - 23)
        and .bytes <= .maxLength and .bytes >= .maxLength - 1
        and (.count | test("^[01] left$"))
  ' >/dev/null || fail "a pasted multi-byte note was not stopped at the label-aware cap: $out"
  printf '%s' "$out" | jq -e '.cards[1].note.maxLength == (512 - 15 - 12)' >/dev/null \
    || fail "the second card's cap did not follow its own title and options: $out"
  pass "a note stops at the cap while typing, counted in bytes against the whole answer label"
}

test_the_card_arrows_bring_the_new_card_into_view() {
  local home out
  home=$(make_home arrows)
  out=$(render_cards "$home" "$(two_cards)")
  printf '%s' "$out" | jq -e '
    .arrow.moved == true and .arrow.scrolled == true and (.arrow.count | test("card 2 of 2"))
  ' >/dev/null || fail "the next arrow did not deal the next card and scroll its top into view: $out"
  pass "the next arrow shows the next card and scrolls its top into view"
}

test_cards_sent_to_the_agent_leave_the_board_and_a_failed_send_deals_them_back() {
  local home out
  home=$(make_home sent-hide)
  out=$(render_cards "$home" "$(two_cards)")
  printf '%s' "$out" | jq -e '
    .send.foreign.shown == ["Second call"]
  ' >/dev/null || fail "a message from another window changed the board: $out"
  printf '%s' "$out" | jq -e '(.send.foreign.count | test("of 2")) and .send.foreign.need == "2"' >/dev/null \
    || fail "a message from another window changed the card count: $out"
  printf '%s' "$out" | jq -e '
    .send.sent | .shown == ["Second call"] and (.count | test("card 1 of 1"))
      and .need == "1" and .sub == "1 item wait on you" and .empty == false
  ' >/dev/null || fail "a sent card stayed on the board or the counters did not follow: $out"
  printf '%s' "$out" | jq -e '
    .send.restored | (.shown | length) == 1 and (.count | test("of 2")) and .need == "2"
      and .sub == "2 items wait on you"
  ' >/dev/null || fail "a failed send did not deal its card back: $out"
  printf '%s' "$out" | jq -e '
    .send.misrouted | (.shown | length) == 1 and (.count | test("of 1")) and .need == "1"
  ' >/dev/null || fail "a send whose selector named the wrong card did not hide the card its text names: $out"
  printf '%s' "$out" | jq -e '
    .send.all | .shown == [] and .empty == true and .navHidden == true
      and .need == "0" and .sub == "nothing needs you"
  ' >/dev/null || fail "sending every card did not leave the empty board: $out"
  pass "cards sent to the agent leave the board at once, counters follow, and a failed send deals them back"
}

test_a_card_attaches_reference_images_through_the_chrome_upload_and_queues_their_ids() {
  local home out
  home=$(make_home attach)
  out=$(render_cards "$home" "$(two_cards)")
  printf '%s' "$out" | jq -e '.error == "" and .attach.control == true' >/dev/null     || fail "the decision card has no image picker: $out"
  printf '%s' "$out" | jq -e '
    .attach | .accept == "image/png,image/jpeg,image/webp" and .multiple == true
      and .afterPick.tiles == ["is-uploading"] and .afterPick.stripShown == true
      and .afterPick.message == "Unsupported file type. Use PNG, JPEG, or WebP."
      and .afterPick.messageShown == true
      and .afterPick.posted == [{type:"lavish:uploadAttachment",name:"a.png",mime:"image/png",token:"tok+en"}]
  ' >/dev/null || fail "a pick did not upload the supported image through the chrome and refuse the rest: $out"
  printf '%s' "$out" | jq -e '
    .attach | .queuedWhileUploading.queued == 0
      and (.queuedWhileUploading.message | test("Waiting for an image to finish uploading"))
      and .foreignNonceIgnored == ["is-uploading"] and .foreignWindowIgnored == ["is-uploading"]
  ' >/dev/null || fail "an answer was queued mid-upload or a stranger's upload result was believed: $out"
  printf '%s' "$out" | jq -e '
    .attach | .afterResult.tiles == ["is-ready"]
      and .queued.count == 1 and .queued.attachments == [{id:"abc.png",name:"a.png"}]
      and .queued.tag == "choice" and (.queued.text | test(" -> "))
      and .queued.data.schema == "fm-bearings-answer.v1" and (.queued.data | has("attachments") | not)
  ' >/dev/null || fail "the queued answer did not carry the uploaded image id, or its keyed context changed: $out"
  printf '%s' "$out" | jq -e '
    .attach | .refused.tiles == ["is-ready","is-error"] and .refused.queued == 1
      and .refused.message == "Image is larger than the 10 MB limit"
      and (.blockedMessage | test("couldn.t be attached. Retry or remove it"))
      and .afterRemove.tiles == ["is-ready"] and .afterRemove.message == ""
      and .queuedAfterRemove == 2
  ' >/dev/null || fail "a refused image was not shown, did not block the answer, or could not be removed: $out"
  printf '%s' "$out" | jq -e '
    .attach | .overTotal.queued == 2
      and .overTotal.message == "Images on one answer can total at most 25 MB. Remove one before queuing."
      and .underTotal.queued == 3 and .underTotal.attachments == ["abc.png","h1.jpg"]
  ' >/dev/null || fail "an answer whose images exceed the Lavish 25 MB per-prompt total was queued: $out"
  printf '%s' "$out" | jq -e '
    .attach.cap | .tiles == 4 and .message == "You can attach up to 4 images."
  ' >/dev/null || fail "a fifth image was not refused: $out"
  pass "a card uploads images through the chrome, shows Lavish's refusals, and queues the ids with the answer"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_underway_progress_renders_feature_part_and_stage_bars
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_a_card_with_images_renders_one_lazy_thumbnail_per_image
test_an_image_outside_the_board_assets_folder_is_not_rendered
test_the_sections_are_tabs_with_counts_and_only_the_selected_one_shows
test_the_tab_bar_answers_to_the_arrow_home_and_end_keys
test_queuing_an_answer_keeps_the_captains_call_tab_selected
test_the_selected_tab_is_restored_from_the_hash_then_storage_then_the_frame_name
test_a_board_with_reports_gets_a_reports_tab_listing_them_newest_first
test_the_reports_filters_narrow_the_list_by_text_and_project
test_a_report_opens_in_a_scriptless_reader_with_a_way_back
test_a_board_without_reports_has_no_reports_tab
test_a_note_stops_at_the_cap_while_typing_and_the_cap_leaves_room_for_the_label
test_the_card_arrows_bring_the_new_card_into_view
test_cards_sent_to_the_agent_leave_the_board_and_a_failed_send_deals_them_back
test_a_card_attaches_reference_images_through_the_chrome_upload_and_queues_their_ids
