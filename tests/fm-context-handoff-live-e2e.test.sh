#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for the worker context handoff
# (bin/fm-context-handoff.sh). Two vendor behaviors carry the feature and only
# the real installed Claude Code can prove them:
#   1. an exit-2 PreCompact hook on an auto compaction skips that compaction
#      and the session continues uncompacted;
#   2. PostToolUse hookSpecificOutput.additionalContext reaches the model.
# A very low CLAUDE_AUTOCOMPACT_PCT_OVERRIDE forces the auto compaction in a
# scratch session. A positive control first runs the same prompt with a
# PreCompact hook that allows the compaction and proves the forced compaction
# actually happens and is observable, so the blocking run cannot pass
# vacuously. The project and state are isolated; Claude keeps using its
# existing managed authentication. No live fleet home, worktree, or session is
# touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CONTEXT_HANDOFF_LIVE_E2E claude jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDOFF="$ROOT/bin/fm-context-handoff.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"
CLAUDE_VERSION=$(claude --version)

LAB="$ROOT/.context-handoff-live-e2e.$$"
KEEP_LAB=0
cleanup() { [ "$KEEP_LAB" = 1 ] || rm -rf "$LAB"; }
trap cleanup EXIT
fail() {  # keep the lab for inspection when a live assertion fails
  KEEP_LAB=1
  printf 'not ok - %s (lab kept at %s)\n' "$1" "$LAB" >&2
  exit 1
}
mkdir -p "$LAB"

PROMPT='Run these three commands with the Bash tool, one at a time, each as its own tool call, in this order: `echo one`, then `echo two`, then `echo three`. If any tool result includes a message beginning with FIRSTMATE CONTEXT HANDOFF, do not run any further command: reply with exactly HANDOFF-NOTICE-SEEN and stop. Otherwise, after the third command, reply with exactly NO-NOTICE and stop. Use no other tool.'

# run_session <name> <settings-json> -> writes $LAB/<name>.out; echoes the final result text
run_session() {
  local name=$1 settings=$2 project state data gen
  project="$LAB/$name"; state="$LAB/$name-state"; data="$LAB/$name-data"
  mkdir -p "$project/.claude" "$state" "$data"
  printf '%s\n' "$settings" > "$project/.claude/settings.local.json"
  gen=$("$BUSY" arm "$state" task) || fail "$name: could not arm the busy-state incarnation"
  sed -i.bak "s|__GEN__|$gen|g; s|__STATE__|$state|g; s|__DATA__|$data|g; s|__ROOT__|$ROOT|g; s|__LAB__|$LAB|g" "$project/.claude/settings.local.json"
  rm -f "$project/.claude/settings.local.json.bak"
  (
    cd "$project" || exit 1
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
      claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
      --effort low --output-format stream-json --verbose
  ) > "$LAB/$name.out" 2>"$LAB/$name.err" || fail "$name: Claude session failed: $(tail -20 "$LAB/$name.err")"
  grep '^{' "$LAB/$name.out" > "$LAB/$name.jsonl" || :
  jq -r 'select(.type == "result") | .result // empty' "$LAB/$name.jsonl" 2>/dev/null | tail -1
}

# events <name>: the stream-json lines only; stderr and any non-JSON line are
# kept apart so one stray line cannot blind every jq read below.

# compaction_events <name>: stream-json compact boundaries plus the transcript's
# compact summaries (verified on Claude Code 2.1.280: a forced auto compaction
# emits one `system`/`compact_boundary` event and writes an
# `isCompactSummary` record), so either observable form counts.
compaction_events() {
  local name=$1 n1 n2 transcript
  n1=$(jq -r 'select(.type == "system" and (.subtype // "") == "compact_boundary") | .type' "$LAB/$name.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  transcript=$(jq -r '.transcript_path // empty' "$LAB/$name-precompact.log" 2>/dev/null | head -1)
  n2=0
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    n2=$(grep -c '"isCompactSummary":true' "$transcript" 2>/dev/null || true)
  fi
  echo $((n1 + n2))
}

tool_commands() {  # <out-file>: the Bash commands the model issued, in order
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "Bash") | .input.command' "$LAB/$1.jsonl" 2>/dev/null
}

# --- positive control: the forced compaction is real and observable -----------
# The allowing control hook records each payload so the transcript path is known.
CONTROL_SETTINGS='{"hooks":{"PreCompact":[{"matcher":"auto","hooks":[{"type":"command","command":"cat >> __LAB__/control-precompact.log; echo >> __LAB__/control-precompact.log; exit 0"}]}]}}'
result=$(run_session control "$CONTROL_SETTINGS")
[ -s "$LAB/control-precompact.log" ] \
  || fail "Claude $CLAUDE_VERSION: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=1 did not fire an auto PreCompact hook in the control session, so this guard cannot force a compaction: $(tail -5 "$LAB/control.err")"
control_compactions=$(compaction_events control)
[ "$control_compactions" -ge 1 ] \
  || fail "Claude $CLAUDE_VERSION: the control session fired PreCompact but no compaction was observable in stream-json or the transcript, so the blocking assertion below would be vacuous"
[ "$result" = NO-NOTICE ] \
  || fail "Claude $CLAUDE_VERSION: the control session should end with NO-NOTICE, got '$result'"

# --- blocking run: the real hooks hold the compaction and deliver the notice ---
# The blocking run wires the real commands exactly as bin/fm-spawn.sh does, plus
# a payload recorder so the transcript path is known here too.
BLOCK_SETTINGS='{"hooks":{"PreCompact":[{"matcher":"auto","hooks":[{"type":"command","command":"cat >> __LAB__/block-precompact.log; echo >> __LAB__/block-precompact.log; exit 0"},{"type":"command","command":"'"$HANDOFF"' precompact __STATE__ task --gen __GEN__ --data-dir __DATA__ --fm-root __ROOT__","timeout":30}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"'"$HANDOFF"' posttooluse __STATE__ task --gen __GEN__ --data-dir __DATA__ --fm-root __ROOT__ 2>/dev/null || true","timeout":30}]}]}}'
result=$(run_session block "$BLOCK_SETTINGS")
STATE="$LAB/block-state"
[ -f "$STATE/task.context-handoff" ] \
  || fail "Claude $CLAUDE_VERSION: the blocking session never recorded a handoff-due marker, so the auto PreCompact hook did not run the real script: $(tail -5 "$LAB/block.err")"
grep -q ' state=due ' "$STATE/task.context-handoff" \
  || fail "Claude $CLAUDE_VERSION: the marker is not 'due': $(cat "$STATE/task.context-handoff")"
grep -q 'context handoff due' "$STATE/task.status" \
  || fail "Claude $CLAUDE_VERSION: the handoff-due status note was not appended"
block_compactions=$(compaction_events block)
[ "$block_compactions" -eq 0 ] \
  || fail "Claude $CLAUDE_VERSION: the exit-2 PreCompact hook did not skip the auto compaction ($block_compactions compaction events observed)"
commands=$(tool_commands block)
printf '%s\n' "$commands" | grep -q 'echo two' \
  || fail "Claude $CLAUDE_VERSION: the session did not continue past the blocked compaction (commands: $(printf '%s ' "$commands" | tr '\n' ' '))"
[ "$result" = HANDOFF-NOTICE-SEEN ] \
  || fail "Claude $CLAUDE_VERSION: the PostToolUse additionalContext notice did not reach the model (final reply '$result')"
! printf '%s\n' "$commands" | grep -q 'echo three' \
  || fail "Claude $CLAUDE_VERSION: the model ran on after the notice instead of stopping"
[ ! -e "$LAB/block-data/task" ] || [ -z "$(ls -A "$LAB/block-data/task" 2>/dev/null)" ] \
  || fail "the scratch session must not have written a handoff (the prompt told it to stop): $(ls "$LAB/block-data/task")"

printf 'ok - Claude %s live E2E: a forced auto compaction was observed with an allowing PreCompact hook (%s events), the exit-2 hook skipped it and the session continued, and the PostToolUse notice reached the model\n' \
  "$CLAUDE_VERSION" "$control_compactions"
