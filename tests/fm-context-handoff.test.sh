#!/usr/bin/env bash
# Behavior tests for the opt-in worker context handoff owned by
# bin/fm-context-handoff.sh: the Claude PreCompact and PostToolUse hook
# commands, the spawn wiring that installs them only under
# config/worker-context-handoff, and the firstmate-side replacement command.
#
# Every case drives the real script with real payloads and real files: a
# transcript fixture carrying assistant usage records, a busy-state
# incarnation armed by the real bin/fm-busy-event.sh, and the real fm-spawn
# against the shared fake tmux pane. The one seam is FM_CONTROL_BIN, which lets
# the replacement case prove exactly what is handed to fm-control without
# standing up the control plane's own session-provider stub (its transaction
# is pinned by tests/fm-control-relaunch.test.sh).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

HANDOFF="$ROOT/bin/fm-context-handoff.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-handoff)

[ -x "$HANDOFF" ] || fail "bin/fm-context-handoff.sh is missing or not executable"

# --- hook-level fixtures ----------------------------------------------------

# new_hook_case <name> -> echoes "<state>|<data>|<transcript>|<gen>" for a task
# named after the case, with the busy-state contract armed by the real writer.
new_hook_case() {
  local name=$1 dir gen
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data" "$dir/root"
  gen=$("$BUSY" arm "$dir/state" "$name") || fail "$name: could not arm the busy-state contract"
  printf '%s\n' "$dir/state|$dir/data|$dir/transcript.jsonl|$gen"
}

read_hook_case() {
  IFS='|' read -r STATE_DIR DATA_DIR TRANSCRIPT GEN <<EOF
$1
EOF
}

# write_transcript <path> <total-tokens>: an assistant record whose usage sums
# to <total-tokens> across the three input fields, preceded by noise lines a
# reader must skip (a user record, an assistant record with no usage).
write_transcript() {
  local path=$1 total=$2 a b c
  a=$((total / 3)); b=$((total / 3)); c=$((total - a - b))
  {
    printf '{"type":"user","message":{"role":"user","content":"hi"}}\n'
    printf '{"type":"assistant","message":{"role":"assistant","content":[]}}\n'
    printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":7}}}\n' "$a" "$b" "$c"
    printf '{"type":"progress","data":{}}\n'
  } > "$path"
}

precompact_payload() {  # <transcript> <trigger>
  printf '{"session_id":"s1","transcript_path":"%s","cwd":"/tmp","hook_event_name":"PreCompact","trigger":"%s","custom_instructions":""}\n' "$1" "$2"
}

posttooluse_payload() {  # <transcript>
  printf '{"session_id":"s1","transcript_path":"%s","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":""}}\n' "$1"
}

run_precompact() {  # <case-record> <id> <trigger> [gen-override]
  local rec=$1 id=$2 trigger=$3 gen
  read_hook_case "$rec"
  gen=${4:-$GEN}
  precompact_payload "$TRANSCRIPT" "$trigger" \
    | "$HANDOFF" precompact "$STATE_DIR" "$id" --gen "$gen" --data-dir "$DATA_DIR" --fm-root "$ROOT" 2>"$STATE_DIR/precompact.err"
}

run_posttooluse() {  # <case-record> <id> [gen-override]
  local rec=$1 id=$2 gen
  read_hook_case "$rec"
  gen=${3:-$GEN}
  posttooluse_payload "$TRANSCRIPT" \
    | "$HANDOFF" posttooluse "$STATE_DIR" "$id" --gen "$gen" --data-dir "$DATA_DIR" --fm-root "$ROOT" 2>"$STATE_DIR/posttooluse.err"
}

marker_field() {  # <state-dir> <id> <field>
  sed -n "s/.*[[:space:]]$3=\([^[:space:]]*\).*/\1/p" "$1/$2.context-handoff" | head -1
}

status_count() {  # <state-dir> <id> <fixed-string>
  grep -cF -- "$3" "$1/$2.status" 2>/dev/null || true
}

# --- PreCompact ---------------------------------------------------------------

test_first_auto_fire_blocks_and_records_the_marker() {
  local id=hk-first rec rc
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  write_transcript "$TRANSCRIPT" 80000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" auto; rc=$?
  expect_code 2 "$rc" "the first auto PreCompact must block (exit 2)"
  assert_present "$STATE_DIR/$id.context-handoff" "the first block must record the handoff-due marker"
  [ "$(marker_field "$STATE_DIR" "$id" state)" = due ] || fail "marker state must be 'due', got '$(cat "$STATE_DIR/$id.context-handoff")'"
  [ "$(marker_field "$STATE_DIR" "$id" gen)" = "$GEN" ] || fail "marker must be bound to the armed incarnation gen"
  [ "$(marker_field "$STATE_DIR" "$id" handoff)" = "$DATA_DIR/$id/handoff-1.md" ] \
    || fail "marker must name the first durable handoff path, got '$(marker_field "$STATE_DIR" "$id" handoff)'"
  [ "$(marker_field "$STATE_DIR" "$id" key)" = context-handoff-1 ] || fail "marker must carry the decision key for this handoff"
  [ "$(marker_field "$STATE_DIR" "$id" ceiling)" = 160000 ] \
    || fail "ceiling must be 80 percent of the window implied by 80000 tokens at 40 percent (160000), got '$(marker_field "$STATE_DIR" "$id" ceiling)'"
  [ "$(status_count "$STATE_DIR" "$id" 'note [at=')" = 1 ] || fail "the first block must append exactly one status note"
  assert_grep "context handoff due" "$STATE_DIR/$id.status" "the status note must say the handoff is due"
  assert_grep "$DATA_DIR/$id/handoff-1.md" "$STATE_DIR/$id.status" "the status note must name the handoff path"
  grep -q . "$STATE_DIR/precompact.err" || fail "a blocking PreCompact must explain itself on stderr"
  pass "the first auto PreCompact blocks, binds a due marker to the incarnation, and notes the handoff once"
}

test_repeat_fires_keep_blocking_silently() {
  local id=hk-repeat rec rc before
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  write_transcript "$TRANSCRIPT" 80000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" auto
  before=$(wc -c < "$STATE_DIR/$id.status")
  write_transcript "$TRANSCRIPT" 120000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" auto; rc=$?
  expect_code 2 "$rc" "a repeat auto PreCompact below the ceiling must keep blocking"
  [ "$(wc -c < "$STATE_DIR/$id.status")" = "$before" ] || fail "a repeat block must not append another status event"
  [ "$(marker_field "$STATE_DIR" "$id" state)" = due ] || fail "a repeat block must leave the marker due"
  pass "repeat auto PreCompact fires keep blocking without new status events while the handoff is pending"
}

test_ceiling_lets_compaction_through_and_records_the_fallback() {
  local id=hk-ceiling rec rc
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  write_transcript "$TRANSCRIPT" 80000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" auto
  write_transcript "$TRANSCRIPT" 160001
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" auto; rc=$?
  expect_code 0 "$rc" "usage past the ceiling must let compaction proceed"
  [ "$(marker_field "$STATE_DIR" "$id" state)" = fallback ] || fail "the ceiling must move the marker to 'fallback'"
  assert_grep "context handoff missed" "$STATE_DIR/$id.status" "the fallback must append a status event saying the handoff did not happen in time"
  [ "$(status_count "$STATE_DIR" "$id" 'context handoff missed')" = 1 ] || fail "the fallback event must be appended once"
  write_transcript "$TRANSCRIPT" 170000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" auto; rc=$?
  expect_code 0 "$rc" "after the fallback every later auto fire must proceed"
  [ "$(status_count "$STATE_DIR" "$id" 'context handoff missed')" = 1 ] || fail "later fires after the fallback must stay silent"
  pass "the fallback ceiling lets compaction through once the window nears its limit and records the miss once"
}

test_missing_override_lets_compaction_through_with_a_reason() {
  local id=hk-nooverride rec rc
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  write_transcript "$TRANSCRIPT" 150000
  env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE true
  ( unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE; run_precompact "$rec" "$id" auto ); rc=$?
  expect_code 0 "$rc" "with no lowering override the hook must let compaction proceed"
  [ "$(marker_field "$STATE_DIR" "$id" state)" = no-override ] || fail "the marker must record why nothing was blocked"
  assert_grep "context handoff skipped" "$STATE_DIR/$id.status" "the status log must say why compaction was allowed"
  ( unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE; run_precompact "$rec" "$id" auto ); rc=$?
  expect_code 0 "$rc" "a later fire with no override must still proceed"
  [ "$(status_count "$STATE_DIR" "$id" 'context handoff skipped')" = 1 ] || fail "the missing-override reason must be recorded once per incarnation"
  assert_absent "$DATA_DIR/$id" "no handoff directory may be created when no handoff is due"
  pass "a worker environment without the lowering override compacts as before and says why once"
}

test_high_override_is_treated_as_no_safe_threshold() {
  local id=hk-highpct rec rc
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  write_transcript "$TRANSCRIPT" 150000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=85 run_precompact "$rec" "$id" auto; rc=$?
  expect_code 0 "$rc" "an override at or above the ceiling percentage leaves no room for a handoff and must proceed"
  [ "$(marker_field "$STATE_DIR" "$id" state)" = no-override ] || fail "an unusable override must be recorded like a missing one"
  pass "an override too close to the window limit is treated as no safe handoff threshold"
}

test_manual_compaction_is_never_blocked() {
  local id=hk-manual rec rc
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  write_transcript "$TRANSCRIPT" 80000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" manual; rc=$?
  expect_code 0 "$rc" "a manual /compact must never be blocked"
  assert_absent "$STATE_DIR/$id.context-handoff" "a manual compaction must not record a handoff marker"
  assert_absent "$STATE_DIR/$id.status" "a manual compaction must not append a status event"
  pass "manual compaction is never blocked and leaves no record"
}

test_stale_incarnation_and_bad_input_let_compaction_through() {
  local id=hk-stale rec rc
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  write_transcript "$TRANSCRIPT" 80000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" auto gstale.1.1; rc=$?
  expect_code 0 "$rc" "a hook carrying a superseded gen must not block the replacement's compaction"
  assert_absent "$STATE_DIR/$id.context-handoff" "a stale-gen fire must not write a marker"
  printf 'not json\n' | CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 "$HANDOFF" precompact "$STATE_DIR" "$id" --gen "$GEN" --data-dir "$DATA_DIR" --fm-root "$ROOT" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "an unreadable payload must let compaction proceed rather than break Claude's lifecycle"
  printf '%s\n' '{"trigger":"auto","transcript_path":"/nonexistent/none.jsonl"}' | CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 "$HANDOFF" precompact "$STATE_DIR" "$id" --gen "$GEN" --data-dir "$DATA_DIR" --fm-root "$ROOT" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "a missing transcript leaves no usage evidence, so compaction must proceed"
  assert_absent "$STATE_DIR/$id.context-handoff" "no marker may be written without usage evidence"
  pass "stale incarnations, unreadable payloads, and missing transcripts all let compaction through"
}

test_second_handoff_gets_the_next_number() {
  local id=hk-second rec
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  mkdir -p "$DATA_DIR/$id"
  printf '# earlier handoff\n' > "$DATA_DIR/$id/handoff-1.md"
  write_transcript "$TRANSCRIPT" 80000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" auto
  [ "$(marker_field "$STATE_DIR" "$id" handoff)" = "$DATA_DIR/$id/handoff-2.md" ] \
    || fail "a task that already handed off once must be told to write handoff-2.md, got '$(marker_field "$STATE_DIR" "$id" handoff)'"
  [ "$(marker_field "$STATE_DIR" "$id" key)" = context-handoff-2 ] || fail "the second handoff must carry its own decision key"
  [ "$(cat "$DATA_DIR/$id/handoff-1.md")" = '# earlier handoff' ] || fail "an earlier handoff must never be overwritten"
  pass "each handoff in a task gets the next durable path and key, never overwriting an earlier one"
}

# --- PostToolUse ---------------------------------------------------------------

test_posttooluse_is_silent_without_a_marker() {
  local id=hk-pt-none rec out rc
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  out=$(run_posttooluse "$rec" "$id"); rc=$?
  expect_code 0 "$rc" "PostToolUse without a marker must exit 0"
  [ -z "$out" ] || fail "PostToolUse without a marker must print nothing, got '$out'"
  assert_absent "$STATE_DIR/$id.status" "the no-marker path must not touch the status log"
  pass "the no-marker PostToolUse path is a silent exit 0"
}

test_posttooluse_delivers_the_notice_sparingly_until_the_handoff_exists() {
  local id=hk-pt-due rec out rc i delivered=0 handoff
  rec=$(new_hook_case "$id"); read_hook_case "$rec"
  write_transcript "$TRANSCRIPT" 80000
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 run_precompact "$rec" "$id" auto
  handoff="$DATA_DIR/$id/handoff-1.md"
  out=$(run_posttooluse "$rec" "$id"); rc=$?
  expect_code 0 "$rc" "PostToolUse with a due marker must exit 0"
  [ -n "$out" ] || fail "the first PostToolUse after the block must deliver the notice"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null \
    || fail "the notice must be a PostToolUse hookSpecificOutput record, got '$out'"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
  assert_contains "$ctx" "$handoff" "the notice must name the exact durable handoff path"
  assert_contains "$ctx" "$ROOT/.agents/skills/context-handoff/SKILL.md" "the notice must name the handoff skill at its absolute path"
  assert_contains "$ctx" "context-handoff-1" "the notice must name the decision key the report must carry"
  assert_contains "$ctx" "$STATE_DIR/$id.status" "the notice must name the status file to report through"
  assert_contains "$ctx" "start nothing new" "the notice must tell the worker to finish the step in hand and start nothing new"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    out=$(run_posttooluse "$rec" "$id")
    [ -z "$out" ] || delivered=$((delivered + 1))
  done
  [ "$delivered" -ge 1 ] || fail "a pending handoff must be re-noticed eventually"
  [ "$delivered" -le 3 ] || fail "the notice must be re-delivered sparingly, not on every call ($delivered of 12)"
  mkdir -p "$DATA_DIR/$id"
  printf '# handoff\n' > "$handoff"
  out=$(run_posttooluse "$rec" "$id"); rc=$?
  expect_code 0 "$rc" "PostToolUse after the handoff exists must exit 0"
  [ -z "$out" ] || fail "once the handoff exists the notice must stop, got '$out'"
  out=$(run_posttooluse "$rec" "$id" gstale.1.1)
  [ -z "$out" ] || fail "a stale-gen PostToolUse must never speak for the replacement"
  pass "PostToolUse delivers the handoff notice once, re-delivers it sparingly, and stops once the handoff exists"
}

# --- spawn wiring ---------------------------------------------------------------

make_spawn_case() {  # <name> <harness> <id> [flag]
  local name=$1 harness=$2 id=$3 flag=${4:-off} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude codex)
  fm_test_spawn_home "$home" "$harness"
  [ "$flag" = off ] || : > "$home/config/worker-context-handoff"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_case() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

hook_names() {  # <settings.json>
  jq -r '.hooks | keys | join(" ")' "$1"
}

test_flag_off_leaves_the_claude_settings_exactly_as_today() {
  local rec id=sp-off out settings
  rec=$(make_spawn_case off claude "$id" off); read_spawn_case "$rec"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "claude ship spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "the busy-state settings file must still be written"
  [ "$(hook_names "$settings")" = "SessionEnd Stop StopFailure UserPromptSubmit" ] \
    || fail "with the flag off the settings must carry only the busy-state hooks, got '$(hook_names "$settings")'"
  assert_absent "$HOME_DIR/state/$id.context-handoff" "no handoff record may exist with the flag off"
  pass "with config/worker-context-handoff absent a claude worker's settings are exactly the busy-state hooks"
}

test_flag_on_adds_the_hooks_for_a_claude_ship() {
  local rec id=sp-ship out settings cmd rc
  rec=$(make_spawn_case ship claude "$id" on); read_spawn_case "$rec"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "claude ship spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  [ "$(hook_names "$settings")" = "PostToolUse PreCompact SessionEnd Stop StopFailure UserPromptSubmit" ] \
    || fail "with the flag on the settings must add PreCompact and PostToolUse beside the busy hooks, got '$(hook_names "$settings")'"
  [ "$(jq -r '.hooks.PreCompact[0].matcher' "$settings")" = auto ] || fail "PreCompact must match only auto compaction"
  [ "$(jq -r '.hooks.PostToolUse[0] | has("matcher")' "$settings")" = false ] || fail "PostToolUse must run on every tool call"
  # Drive the generated PreCompact command exactly as Claude would: a real
  # auto payload on stdin, the worker's environment carrying the override.
  cmd=$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$settings")
  write_transcript "$CASE_DIR/transcript.jsonl" 80000
  precompact_payload "$CASE_DIR/transcript.jsonl" auto \
    | CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 sh -c "$cmd" 2>/dev/null; rc=$?
  expect_code 2 "$rc" "the generated PreCompact command must block the first auto compaction"
  assert_present "$HOME_DIR/state/$id.context-handoff" "the generated command must write the marker into this home's state"
  [ "$(marker_field "$HOME_DIR/state" "$id" gen)" = "$(cat "$HOME_DIR/state/$id.busy-gen")" ] \
    || fail "the generated command must bind the marker to the gen fm-spawn armed"
  [ "$(marker_field "$HOME_DIR/state" "$id" handoff)" = "$(cd "$HOME_DIR/data" && pwd -P)/$id/handoff-1.md" ] \
    || fail "the generated command must point at this home's data directory, got '$(marker_field "$HOME_DIR/state" "$id" handoff)'"
  cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$settings")
  out=$(posttooluse_payload "$CASE_DIR/transcript.jsonl" | sh -c "$cmd" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "the generated PostToolUse command must exit 0"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("handoff-1.md")' >/dev/null \
    || fail "the generated PostToolUse command must deliver the notice once the marker exists, got '$out'"
  pass "with the flag on a claude ship gets working PreCompact and PostToolUse hooks bound to its incarnation"
}

test_flag_on_adds_the_hooks_for_a_claude_scout() {
  local rec id=sp-scout out settings
  rec=$(make_spawn_case scout claude "$id" on); read_spawn_case "$rec"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --scout "$id" "$PROJ_DIR")
  expect_code 0 $? "claude scout spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  [ "$(hook_names "$settings")" = "PostToolUse PreCompact SessionEnd Stop StopFailure UserPromptSubmit" ] \
    || fail "a scout must get the same handoff hooks as a ship, got '$(hook_names "$settings")'"
  pass "with the flag on a claude scout gets the handoff hooks"
}

test_flag_on_adds_nothing_for_another_harness() {
  local rec id=sp-codex out
  rec=$(make_spawn_case codex codex "$id" on); read_spawn_case "$rec"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  expect_code 0 $? "codex ship spawn should succeed: $out"
  assert_absent "$WT_DIR/.claude/settings.local.json" "a codex worker must get no claude settings file"
  out=$(grep -rl "fm-context-handoff.sh precompact" "$WT_DIR" "$HOME_DIR/state" 2>/dev/null || true)
  [ -z "$out" ] || fail "the handoff hooks must never be wired for a non-claude harness: $out"
  pass "with the flag on a codex worker gets no handoff wiring"
}

# make_relaunch_stub <case-dir>: the pane-lifecycle tmux stub
# tests/fm-spawn-launch-env.test.sh drives fm-control relaunch with, so the
# relaunch below runs the operator-facing verb end to end.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'claude' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x95\xad\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82 \xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x95\xaf\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

test_relaunch_starts_with_fresh_handoff_state() {
  local id=sp-relaunch dir home proj wt out status settings gen1 gen2
  dir="$TMP_ROOT/relaunch"
  home="$dir/home"; proj="$dir/proj"; wt="$dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/user-home"
  touch "$home/state/.last-watcher-beat"
  : > "$home/config/worker-context-handoff"
  make_relaunch_stub "$dir"
  fm_git_worktree "$proj" "$wt" "wt-relaunch"
  fm_test_spawn_brief "$home" "$id"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  gen1=$("$BUSY" arm "$home/state" "$id") || fail "could not arm the prior incarnation"
  printf 'v1 gen=%s state=due seq=1 handoff=%s/data/%s/handoff-1.md key=context-handoff-1 usage=1 pct=40 window=2 ceiling=2 notices=0 calls=0 at=1\n' \
    "$gen1" "$home" "$id" > "$home/state/$id.context-handoff"

  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$ROOT/bin/fm-control.sh" "$id" relaunch --note 'replacement continues from the handoff' 2>&1)
  status=$?
  expect_code 0 "$status" "claude relaunch through fm-control should succeed: $out"
  gen2=$(cat "$home/state/$id.busy-gen")
  [ "$gen1" != "$gen2" ] || fail "a relaunch must mint a fresh incarnation"
  assert_absent "$home/state/$id.context-handoff" "a relaunch must clear the previous incarnation's handoff marker"
  settings="$wt/.claude/settings.local.json"
  [ "$(hook_names "$settings")" = "PostToolUse PreCompact SessionEnd Stop StopFailure UserPromptSubmit" ] \
    || fail "a relaunch must re-evaluate the flag and wire the hooks again, got '$(hook_names "$settings")'"
  assert_contains "$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$settings")" "--gen '$gen2'" \
    "the relaunched hooks must carry the new gen"
  pass "a relaunch clears the old handoff marker and re-wires the hooks for the new incarnation"
}

# --- replacement ------------------------------------------------------------------

# new_replace_case <name> -> echoes "<home>|<gen>" for a home whose task <name>
# has an armed incarnation and a due marker pointing at handoff-1.md, plus a
# recording fm-control stub reachable through FM_CONTROL_BIN.
new_replace_case() {
  local name=$1 home gen
  home="$TMP_ROOT/replace-$name"
  mkdir -p "$home/state" "$home/data/$name" "$home/bin"
  gen=$("$BUSY" arm "$home/state" "$name") || fail "$name: could not arm the busy-state contract"
  printf 'v1 gen=%s state=due seq=1 handoff=%s key=context-handoff-1 usage=80000 pct=40 window=200000 ceiling=160000 notices=1 calls=1 at=1\n' \
    "$gen" "$home/data/$name/handoff-1.md" > "$home/state/$name.context-handoff"
  cat > "$home/bin/fm-control" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_TEST_CONTROL_ARGS"
[ -z "${FM_TEST_CONTROL_FAIL:-}" ] || { echo "error: stub refused" >&2; exit 1; }
echo "relaunched $1 harness=claude"
SH
  chmod +x "$home/bin/fm-control"
  printf '%s\n' "$home|$gen"
}

run_replace() {  # <home> <id>
  local home=$1 id=$2
  FM_HOME="$home" FM_CONTROL_BIN="$home/bin/fm-control" FM_TEST_CONTROL_ARGS="$home/control.args" \
    "$HANDOFF" replace "$id" 2>&1
}

test_replace_refuses_a_missing_empty_or_stale_handoff() {
  local id=rp-refuse rec home gen out rc
  rec=$(new_replace_case "$id"); IFS='|' read -r home gen <<EOF
$rec
EOF
  out=$(run_replace "$home" "$id"); rc=$?
  expect_code 1 "$rc" "a missing handoff must be refused"
  assert_contains "$out" "handoff-1.md" "the refusal must name the missing handoff"
  assert_absent "$home/control.args" "nothing may reach fm-control for a missing handoff"
  : > "$home/data/$id/handoff-1.md"
  out=$(run_replace "$home" "$id"); rc=$?
  expect_code 1 "$rc" "an empty handoff must be refused"
  assert_contains "$out" "empty" "the refusal must say the handoff is empty"
  printf '   \n\n' > "$home/data/$id/handoff-1.md"
  out=$(run_replace "$home" "$id"); rc=$?
  expect_code 1 "$rc" "a whitespace-only handoff must be refused"
  printf '# handoff\n\nState: done.\n' > "$home/data/$id/handoff-1.md"
  "$BUSY" arm "$home/state" "$id" >/dev/null || fail "could not re-arm"
  out=$(run_replace "$home" "$id"); rc=$?
  expect_code 1 "$rc" "a handoff bound to a superseded incarnation must be refused"
  assert_contains "$out" "incarnation" "the refusal must say the handoff belongs to another incarnation"
  assert_absent "$home/control.args" "nothing may reach fm-control for a stale handoff"
  rm -f "$home/state/$id.context-handoff"
  out=$(run_replace "$home" "$id"); rc=$?
  expect_code 1 "$rc" "a task with no handoff record must be refused"
  assert_contains "$out" "no context handoff" "the refusal must say no handoff is recorded"
  pass "replace refuses a missing, empty, whitespace-only, stale, or unrecorded handoff and never reaches fm-control"
}

test_replace_hands_a_valid_handoff_to_fm_control() {
  local id=rp-ok rec home gen out rc args
  rec=$(new_replace_case "$id"); IFS='|' read -r home gen <<EOF
$rec
EOF
  printf '# handoff\n\n## Current state\nAll tests green at abc123.\n' > "$home/data/$id/handoff-1.md"
  out=$(run_replace "$home" "$id"); rc=$?
  expect_code 0 "$rc" "a valid handoff must be replaced: $out"
  args=$(cat "$home/control.args")
  [ "$(sed -n 1p "$home/control.args")" = "$id" ] || fail "fm-control must be addressed to the task id, got '$args'"
  [ "$(sed -n 2p "$home/control.args")" = relaunch ] || fail "fm-control must be driven through relaunch, got '$args'"
  [ "$(sed -n 3p "$home/control.args")" = --note ] || fail "the relaunch must carry a --note, got '$args'"
  assert_contains "$(sed -n 4p "$home/control.args")" "$home/data/$id/handoff-1.md" "the note must tell the replacement to read the handoff"
  assert_contains "$(sed -n 4p "$home/control.args")" "first" "the note must tell the replacement to read the handoff first"
  assert_contains "$out" "$home/data/$id/handoff-1.md" "the outcome must name the handoff used"
  assert_grep "resolved [key=context-handoff-1]" "$home/state/$id.status" "the replacement must close the handoff-ready record"
  pass "replace hands a valid handoff to fm-control relaunch with a read-it-first note and closes the record"
}

test_replace_reports_a_refused_relaunch_without_closing_the_record() {
  local id=rp-fail rec home gen out rc
  rec=$(new_replace_case "$id"); IFS='|' read -r home gen <<EOF
$rec
EOF
  printf '# handoff\n\nState.\n' > "$home/data/$id/handoff-1.md"
  out=$(FM_TEST_CONTROL_FAIL=1 run_replace "$home" "$id"); rc=$?
  expect_code 1 "$rc" "a refused relaunch must fail the replacement"
  assert_contains "$out" "stub refused" "the relaunch refusal must be relayed"
  ! grep -q 'resolved' "$home/state/$id.status" 2>/dev/null || fail "a refused relaunch must not close the handoff-ready record"
  pass "a refused relaunch is relayed and leaves the handoff record open"
}

test_first_auto_fire_blocks_and_records_the_marker
test_repeat_fires_keep_blocking_silently
test_ceiling_lets_compaction_through_and_records_the_fallback
test_missing_override_lets_compaction_through_with_a_reason
test_high_override_is_treated_as_no_safe_threshold
test_manual_compaction_is_never_blocked
test_stale_incarnation_and_bad_input_let_compaction_through
test_second_handoff_gets_the_next_number
test_posttooluse_is_silent_without_a_marker
test_posttooluse_delivers_the_notice_sparingly_until_the_handoff_exists
test_flag_off_leaves_the_claude_settings_exactly_as_today
test_flag_on_adds_the_hooks_for_a_claude_ship
test_flag_on_adds_the_hooks_for_a_claude_scout
test_flag_on_adds_nothing_for_another_harness
test_relaunch_starts_with_fresh_handoff_state
test_replace_refuses_a_missing_empty_or_stale_handoff
test_replace_hands_a_valid_handoff_to_fm_control
test_replace_reports_a_refused_relaunch_without_closing_the_record

echo "all fm-context-handoff tests passed"
