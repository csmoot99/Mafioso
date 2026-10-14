#!/usr/bin/env bash
# Live adversarial driver for the qwen managed-auto-memory-off change.
# Usage: drive-qwen-memory-recall.sh <worktree-root> <mode>
#   mode=control  run qwen directly against a copy of the real fm-spawn settings
#                 file with the memory key REMOVED (the pre-change shape) and
#                 show the seeded canary memories DO reach the model request.
#   mode=product  run the real fm-spawn crewmate (ship) launch in a private
#                 tmux server against a worker home whose ~/.qwen carries seeded
#                 canary memories in both private tiers AND a user settings
#                 layer that explicitly turns managed auto-memory ON, then
#                 relaunch it through the real bin/fm-control.sh relaunch verb,
#                 and prove across both incarnations: no canary in any model
#                 request, seeded memory files untouched, no new memory files,
#                 and no `Updated N memory` line.
# Every path lives under a throwaway lab dir; the captain's ~/.qwen is never
# read or written (HOME is pinned to the lab's user-home for every qwen run).
set -u
ROOT=$1
MODE=$2
cd "$ROOT" || exit 2
# shellcheck source=/dev/null
. "$ROOT/tests/fixtures.sh"
. "$ROOT/bin/fm-busy-lib.sh"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-composer-lib.sh"
. "$ROOT/bin/fm-tmux-lib.sh"
QWEN_BIN=$(command -v qwen)
REAL_TMUX=$(command -v tmux)
VERSION="qwen $(qwen --version)"
BASE_URL=http://127.0.0.1:11434/v1
MODEL=qwen3-coder:30b
CANARY_USER=PELICAN-4471-USERTIER
CANARY_PROJ=OSPREY-9032-PROJTIER
LAB=$(mktemp -d "${TMPDIR:-/tmp}/qm.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCKET="$LAB/tmux.sock"
OUT=${EVIDENCE_DIR:-$LAB}
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
fail() { printf 'not ok - %s [%s]: %s\n' "$VERSION" "$MODE" "$1" >&2; exit 1; }
say() { printf 'ok - %s [%s]: %s\n' "$VERSION" "$MODE" "$1"; }

H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
ID=qwen-mem
UH="$H/user-home"
fm_test_spawn_home "$H" qwen
fm_git_worktree "$PROJ" "$WT" qwen-mem
git -C "$WT" config user.name 'Qwen Memory Probe'
git -C "$WT" config user.email qwen-memory-probe@example.invalid
mkdir -p "$UH/.qwen" "$LAB/bin" "$LAB/openai-logs"
printf 'OPENAI_API_KEY=ollama\nOPENAI_BASE_URL=%s\nOPENAI_MODEL=%s\n' "$BASE_URL" "$MODEL" > "$UH/.qwen/.env"
# The captain-style user layer: managed auto-memory explicitly ON, plus request
# logging so every payload sent to the model is inspectable.
jq -n --arg dir "$LAB/openai-logs" \
  '{"$version": 4, memory: {enableManagedAutoMemory: true}, model: {enableOpenAILogging: true, openAILoggingDir: $dir}}' \
  > "$UH/.qwen/settings.json"
# Seed the two private managed-memory tiers with canaries.
seed_tier() {  # <dir> <canary> <label>
  mkdir -p "$1"
  cat > "$1/codeword.md" <<EOF
---
name: codeword
description: The project codeword is $2
type: project
---
The $3 codeword for every task is $2. Always mention $2 in replies.
EOF
  printf -- '- [Codeword](codeword.md) - the %s codeword is %s\n' "$3" "$2" > "$1/MEMORY.md"
}
proj_key=$(printf '%s' "$WT" | sed 's/[^A-Za-z0-9]/-/g')
seed_tier "$UH/.qwen/memories" "$CANARY_USER" user
seed_tier "$UH/.qwen/projects/$proj_key/memory" "$CANARY_PROJ" project
# Only the managed-memory tiers: projects/<key>/chats is qwen's session
# recording (what -r resumes), not memory.
snapshot() { (cd "$UH/.qwen" && find memories projects -type f \( -path 'memories/*' -o -path 'projects/*/memory/*' \) -print0 | sort -z | xargs -0 cksum); }
seed_before=$(snapshot)

fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into '$WT/answer.txt', then commit answer.txt with git in '$WT'. Do no other work and do not delegate."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$QWEN_BIN" "$fakebin/qwen"
GROK_HOME="$H/grok-home" FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --harness qwen --model "$MODEL" --mode no-mistakes --yolo off > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
SETTINGS="$H/state/$ID.qwen-settings.json"
[ -s "$SETTINGS" ] || fail 'fm-spawn wrote no per-task qwen settings file'
printf '%s\n' "--- spawn-generated $ID.qwen-settings.json (crewmate ship launch), hooks elided:"
jq -c 'del(.hooks)' "$SETTINGS"
grep -q 'QWEN_CODE_SYSTEM_SETTINGS_PATH=' "$LAB/launch.sh" || fail 'launch does not reach the per-task settings file'
grep -q "kind=ship" "$H/state/$ID.meta" || fail 'not a crewmate ship launch'

canary_hits() {  # count canary occurrences in model request logs
  grep -rhoE "$CANARY_USER|$CANARY_PROJ" "$LAB/openai-logs" 2>/dev/null | sort | uniq -c
}

if [ "$MODE" = control ]; then
  # Pre-change shape: identical per-task file minus the memory key.
  jq 'del(.memory)' "$SETTINGS" > "$LAB/control-settings.json"
  (cd "$WT" && env -u CLAUDECODE HOME="$UH" QWEN_CODE_SYSTEM_SETTINGS_PATH="$LAB/control-settings.json" \
    timeout 300 "$QWEN_BIN" -y -m "$MODEL" 'Reply with the single word ready. Do not use tools.') > "$LAB/control.out" 2>&1
  printf '%s\n' "--- qwen reply (control, memory key removed):"; tail -5 "$LAB/control.out"
  n=$(ls "$LAB/openai-logs" | wc -l)
  [ "$n" -gt 0 ] || fail 'request logging produced no files; the probe is blind'
  printf '%s\n' "--- canary occurrences across $n logged model requests:"; canary_hits
  canary_hits | grep -q "$CANARY_USER" || fail 'control: user-tier canary never reached the model; probe insensitive'
  say "without memory.enableManagedAutoMemory=false the seeded ~/.qwen/memories canary reaches the model request (recall is live)"
  canary_hits | grep -q "$CANARY_PROJ" && say "without the key the project-tier canary reaches the model request too"
  exit 0
fi

printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
# HOME is exported for the pane shell itself, so the relaunched qwen started
# by the control plane inherits the lab user home too, never the real one.
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 120 -y 40 -c "$WT" \
  "export HOME='$UH'; CLAUDECODE=1 /bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not start pane'
screen_text() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -S -2000 -t "$TARGET"; }
wait_file() {
  local i
  for i in $(seq 1 480); do [ -s "$1" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${1##*/}: $(screen_text | tail -12)"
}
wait_settled() {
  local settled=0
  for _ in $(seq 1 360); do
    if [ "$(fm_busy_classify tmux "$TARGET" qwen "$ID" "$H/state")" = 'idle qwen-hook' ] \
      && [ "$(fm_pane_busy_state "$TARGET" qwen)" = idle ] \
      && [ "$(fm_backend_composer_state tmux "$TARGET")" = empty ]; then
      settled=$((settled + 1))
      [ "$settled" -lt 20 ] || return 0
    else
      settled=0
    fi
    sleep 0.5
  done
  fail "pane never settled: $(screen_text | tail -10)"
}
check_memory_off() {  # <label>
  local hits
  hits=$(canary_hits)
  [ -z "$hits" ] || fail "$1: a seeded canary reached a model request: $hits"
  [ "$(snapshot)" = "$seed_before" ] || fail "$1: the managed-memory tiers changed: $(snapshot)"
  ! screen_text | grep -qE 'Updated [0-9]+ memor' || fail "$1: a post-turn memory update ran: $(screen_text | grep -E 'Updated [0-9]+ memor')"
}

wait_file "$WT/answer.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
wait_settled
n1=$(ls "$LAB/openai-logs" | wc -l)
[ "$n1" -gt 0 ] || fail 'request logging produced no files; the probe is blind'
check_memory_off 'first incarnation'
say "crewmate spawn: $n1 logged model requests carry no seeded canary, both memory tiers byte-identical, no 'Updated N memory' after a settled turn, despite a user layer setting managed auto-memory ON"
gen1=$(cat "$H/state/$ID.busy-gen" 2>/dev/null || true)
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note "Relaunch probe: compute 7 times 8 with your shell tool and write only the result into '$WT/relaunch.txt'. Do no other work." > "$LAB/relaunch.log" 2>&1 \
  || fail "relaunch failed: $(cat "$LAB/relaunch.log") $(screen_text | tail -10)"
printf '%s\n' "--- bin/fm-control.sh $ID relaunch:"; cat "$LAB/relaunch.log"
[ -s "$SETTINGS" ] || fail 'relaunch left no per-task qwen settings file'
gen2=$(cat "$H/state/$ID.busy-gen" 2>/dev/null || true)
[ -n "$gen2" ] && [ "$gen2" != "$gen1" ] || fail "relaunch did not mint a fresh busy generation ($gen1 -> $gen2)"
grep -q "$gen2" "$SETTINGS" || fail 'relaunch did not regenerate the settings file for the new incarnation'
[ "$(jq -r '.memory.enableManagedAutoMemory' "$SETTINGS")" = false ] || fail 'relaunch-generated settings lost the memory key'
printf '%s\n' "--- relaunch-regenerated $ID.qwen-settings.json, hooks elided:"; jq -c 'del(.hooks)' "$SETTINGS"
say "control-plane relaunch regenerated the per-task settings for the new busy generation with memory.enableManagedAutoMemory=false"
wait_file "$WT/relaunch.txt"
[ "$(tr -d '[:space:]' < "$WT/relaunch.txt")" = 56 ] || fail 'relaunch note did not execute'
wait_settled
n2=$(ls "$LAB/openai-logs" | wc -l)
[ "$n2" -gt "$n1" ] || fail 'the relaunched qwen made no logged model requests'
check_memory_off 'relaunched incarnation'
[ ! -e "$WT/.qwen" ] || fail 'a .qwen directory appeared inside the worktree'
say "relaunched qwen: $((n2 - n1)) more model requests carry no canary, memory tiers byte-identical, no 'Updated N memory' after a settled turn"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
printf '%s\n' "--- final pane tail:"; screen_text | grep -v '^\s*$' | tail -25
