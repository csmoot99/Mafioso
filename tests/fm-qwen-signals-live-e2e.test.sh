#!/usr/bin/env bash
# Qwen Code worker guard. Opt in with FM_QWEN_SIGNALS_LIVE=1.
# FM_QWEN_BASE_URL (default http://127.0.0.1:11434/v1) names the OpenAI-compatible
# endpoint and FM_QWEN_MODEL (default qwen3-coder:30b) the model it serves; the
# guard skips when that endpoint is unreachable, since the credential
# precondition is the operator's (references/harness/qwen.md).
# Runs the real fm-spawn launch command in a private tmux server; only worktree
# allocation and initial endpoint delivery use fixtures. All later steering,
# interrupt and exit operations use the real Firstmate control plane.
# The isolated user home carries ONLY the three-line ~/.qwen/.env the adapter
# documents as the operator's one-time precondition, so this guard also proves
# that precondition reaches the model with no auth or onboarding dialog.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_QWEN_SIGNALS_LIVE qwen tmux jq curl
QWEN_BIN=$(command -v qwen)
REAL_TMUX=$(command -v tmux)
VERSION="qwen $(qwen --version)"
BASE_URL=${FM_QWEN_BASE_URL:-http://127.0.0.1:11434/v1}
MODEL=${FM_QWEN_MODEL:-qwen3-coder:30b}
if ! curl -fsS --max-time 5 "$BASE_URL/models" >/dev/null 2>&1; then
  printf 'skip: live: %s has no reachable model endpoint at %s\n' "$VERSION" "$BASE_URL"
  exit 0
fi
LAB=$(mktemp -d "${TMPDIR:-/tmp}/qw.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
# Unix-domain socket paths have a small OS byte limit. Keep the socket name
# relative when the isolated lab is under this checkout's working directory.
SOCKET="$LAB/tmux.sock"
case "$SOCKET" in "$PWD"/*) SOCKET=${SOCKET#"$PWD"/} ;; esac
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  # The per-task git hooks dir is written read-only by fm-spawn.
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"
H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
ID=qwen-live
fm_test_spawn_home "$H" qwen
fm_git_worktree "$PROJ" "$WT" qwen-live
mkdir -p "$H/user-home/.qwen" "$LAB/bin"
# The documented one-time precondition, and nothing else: qwen reads this file
# itself at startup, and the model name is a placeholder credential for a
# local OpenAI-compatible server.
printf 'OPENAI_API_KEY=ollama\nOPENAI_BASE_URL=%s\nOPENAI_MODEL=%s\n' "$BASE_URL" "$MODEL" > "$H/user-home/.qwen/.env"
# A user-layer SessionStart hook records the session id for the resume probe
# and proves hook arrays merge across qwen's settings layers.
jq -n --arg cmd "cat >> '$LAB/events.jsonl'; printf '\n' >> '$LAB/events.jsonl'" \
  '{"$version": 4, hooks: {SessionStart: [{hooks: [{type: "command", command: $cmd}]}]}}' \
  > "$H/user-home/.qwen/settings.json"
git -C "$WT" config user.name 'Qwen Live Guard'
git -C "$WT" config user.email qwen-live-guard@example.invalid
# Absolute paths keep the local model from writing beside the wrong cwd.
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into '$WT/answer.txt', then commit answer.txt with git in '$WT' using a commit message you write yourself. Also run the shell command: '$ROOT/bin/fm-harness.sh' > '$WT/harness.txt' . Do no other work and do not delegate. Later read and acknowledge Firstmate's instruction inbox when the doorbell arrives."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$QWEN_BIN" "$fakebin/qwen"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness qwen --model "$MODEL" > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
SETTINGS="$H/state/$ID.qwen-settings.json"
[ -s "$SETTINGS" ] || fail 'fm-spawn wrote no per-task qwen settings file'
settings_before=$(cksum < "$SETTINGS")
# Route every backend read/write to this guard's own socket only.
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
# CLAUDECODE=1 stands in for a claude primary: the launch must clear it before
# qwen inherits it, because qwen itself does not (verified, 0.25.1).
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 120 -y 40 -c "$WT" \
  "HOME='$H/user-home' CLAUDECODE=1 /bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not start pane'
capture() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -e -t "$TARGET"; }
screen_text() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -t "$TARGET"; }
wait_file() {
  local path=$1 i
  for i in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/}: $(screen_text | tail -12)"
}
wait_idle() {
  local i
  for i in $(seq 1 240); do
    [ "$(fm_busy_classify tmux "$TARGET" qwen "$ID" "$H/state")" = 'idle qwen-hook' ] && return 0
    sleep 0.5
  done
  fail 'Stop did not produce semantic idle'
}
wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = qwen ] || fail "marker did not identify qwen under a claude primary: $(cat "$WT/harness.txt")"
wait_idle
[ -f "$H/state/$ID.turn-ended" ] || fail 'Stop did not notify turn end'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'real qwen process not classified alive'
! screen_text | grep -q 'Do you trust this folder' || fail 'a fresh worktree parked on the folder-trust dialog'
pass "$VERSION: spawn brief, model, autonomy, trust, identity and native Stop"
git -C "$WT" log -1 --format=%B -- answer.txt > "$LAB/commit.txt" 2>/dev/null
[ -s "$LAB/commit.txt" ] || fail 'the worker did not commit answer.txt'
! grep -qiE 'co-authored-by|generated with' "$LAB/commit.txt" \
  || fail "worker commit carries qwen attribution: $(cat "$LAB/commit.txt")"
[ ! -e "$WT/.qwen" ] || fail 'the launch created a .qwen directory inside the project worktree'
[ "$(cksum < "$SETTINGS")" = "$settings_before" ] || fail 'qwen rewrote the firstmate-owned settings file at startup'
# Managed auto-memory is off per task: the turn must leave no memory store
# under the worker's user home and no post-turn `Updated N memory` line.
[ ! -e "$H/user-home/.qwen/memories" ] || fail 'the worker wrote managed auto-memory under ~/.qwen/memories'
! screen_text | grep -qE 'Updated [0-9]+ memor' || fail "a post-turn memory update ran with managed auto-memory off: $(screen_text | tail -8)"
pass "$VERSION: no project settings written, no settings rewrite, no memory store, and the worker commit carries no attribution"
# The real styled screen must classify empty through the tmux path (the
# separated `*` glyph row proven by the foreground-process identity probe),
# because fm-control's exit refuses anything short of a proven-empty composer.
[ "$(fm_backend_composer_state tmux "$TARGET")" = empty ] \
  || fail "idle composer did not classify empty: $(screen_text | tail -8)"
# The absolute paths keep the acknowledgement from depending on the local
# model expanding the inbox variable; the doorbell is still what makes it
# read the inbox at all.
"$ROOT/bin/fm-send.sh" "$ID" "Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by running: mv '$H/state/$ID.inbox/001.msg' '$H/state/$ID.inbox/handled/' . Do no other work." > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_idle
pass "$VERSION: real fm-send doorbell read and acknowledged"
# qwen blocks a standalone sleep tool call, so the long turn is generation,
# typed directly: the steer path is already proven above, and the local model
# summarizes rather than counts when the request rides the doorbell. The pane
# must be settled first: qwen runs a memory update after a turn, and on this
# version Enter while a turn runs STEERS that turn (`Enter to steer` in the
# footer) instead of opening a new one, so text typed too early is consumed.
settled=0
for _ in $(seq 1 120); do
  if [ "$(fm_busy_classify tmux "$TARGET" qwen "$ID" "$H/state")" = 'idle qwen-hook' ] \
    && [ "$(fm_pane_busy_state "$TARGET" qwen)" = idle ] \
    && [ "$(fm_backend_composer_state tmux "$TARGET")" = empty ]; then
    settled=$((settled + 1))
    [ "$settled" -lt 6 ] || break
  else
    settled=0
  fi
  sleep 0.5
done
[ "$settled" -ge 6 ] || fail "pane never settled idle before the interrupt probe: $(screen_text | tail -8)"
tmux send-keys -t "$TARGET" -l 'Count from 1 to 400, one number per line with a short sentence about each. Do not use tools.'
sleep 0.3
tmux send-keys -t "$TARGET" Enter
# Interrupt only once output is streaming (the status row carries a token
# counter): an Escape that lands while the model is still thinking withdraws
# the prompt from the transcript without a cancel notice, a different qwen
# path that this probe deliberately does not exercise.
seen_busy=0
for _ in $(seq 1 900); do
  if screen_text | grep -q '> Count from 1 to 400' \
    && [ "$(fm_busy_classify tmux "$TARGET" qwen "$ID" "$H/state")" = 'busy qwen-hook' ] \
    && screen_text | grep -qE '↓ [0-9]+ tokens · esc to cancel'; then seen_busy=1; break; fi
  sleep 0.2
done
[ "$seen_busy" = 1 ] || fail "no echoed prompt with semantic and streaming busy during interrupt probe: $(screen_text | tail -12)"
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
grep -q 'cancel=unconfirmed' "$LAB/interrupt.log" || fail "busy interrupt was not armed: $(cat "$LAB/interrupt.log")"
# Stop does not fire on Escape, so control invalidates the record rather than
# waiting for a self-closing hook as gemini's AfterAgent allows.
[ "$(fm_busy_classify tmux "$TARGET" qwen "$ID" "$H/state")" = 'unknown fm-interrupt' ] || fail 'interrupt did not conservatively invalidate state'
for _ in $(seq 1 60); do
  screen_text | grep -q 'Request cancelled' && break
  sleep 0.5
done
screen_text | grep -q 'Request cancelled' || fail "single Escape did not cancel: $(screen_text | tail -30)"
# qwen restores the cancelled prompt into its composer; the control plane's
# Ctrl+U must have cleared it, or the exit below would concatenate onto it.
[ "$(fm_backend_composer_state tmux "$TARGET")" = empty ] \
  || fail "composer not empty after the interrupt's clear key: $(screen_text | tail -6)"
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'interrupt did not preserve the agent'
pass "$VERSION: single Escape cancels, Ctrl+U clears the restored prompt, and busy state is invalidated"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail 'quit did not return to shell'
# The exit verb retires the busy generation, so the SessionEnd idle that
# follows is a rejected stale event here by design; its open/close pairing
# is pinned by tests/fm-busy-adapter-wiring.test.sh.
screen_text | grep -q -- '--resume' || fail "quit printed no resume hint: $(screen_text | tail -8)"
session=$(jq -r 'select(.hook_event_name == "SessionStart") | .session_id' "$LAB/events.jsonl" 2>/dev/null | head -1)
[ -n "$session" ] || fail 'no session id from the user-layer SessionStart hook'
# Native resume is a vendor fact, not a new fm-control verb; it keeps the
# per-task settings so the busy hooks and the final exit still have state.
printf '%s\n' "exec env -u CLAUDECODE HOME='$H/user-home' QWEN_CODE_SYSTEM_SETTINGS_PATH='$SETTINGS' '$QWEN_BIN' -y -m '$MODEL' -r '$session' -i 'Runtime resume probe: write the product of 17 and 29 into resumed.txt, then stop.'" > "$LAB/resume.sh"
tmux send-keys -t "$TARGET" -l "sh '$LAB/resume.sh'"
sleep 0.5
tmux send-keys -t "$TARGET" Enter
wait_file "$WT/resumed.txt"
[ "$(tr -d '[:space:]' < "$WT/resumed.txt")" = 493 ] || fail 'resume prompt not processed'
# Exit via the actual table-backed control plane once more, after the resumed
# turn has settled (the file lands mid-turn; exit refuses a working pane).
settled=0
for _ in $(seq 1 240); do
  if [ "$(fm_pane_busy_state "$TARGET" qwen)" = idle ] \
    && [ "$(fm_backend_composer_state tmux "$TARGET")" = empty ]; then
    settled=$((settled + 1))
    [ "$settled" -lt 6 ] || break
  else
    settled=0
  fi
  sleep 0.5
done
[ "$settled" -ge 6 ] || fail "resumed pane never settled idle: $(screen_text | tail -10)"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "resumed exit failed: $(cat "$LAB/exit.log")
$(screen_text | tail -10)"
pass "$VERSION: /quit and native -r session resume"
