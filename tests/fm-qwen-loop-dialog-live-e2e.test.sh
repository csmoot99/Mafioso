#!/usr/bin/env bash
# Qwen Code loop-detection halt guard. Opt in with FM_QWEN_LOOP_DIALOG_LIVE=1.
#
# When qwen's loop detector fires it ends the turn with no Stop hook and opens
# a dialog that waits for a keypress, so the busy record keeps reading busy
# while the worker sits halted. Firstmate reads the halt from the rendered
# dialog (bin/fm-composer-lib.sh fm_composer_qwen_loop_dialog), a vendor
# surface no fixture can prove. This guard launches a REAL qwen worker through
# the real control plane onto an isolated Herdr lab session, trips the detector
# with a per-turn tool-call cap in the guard's own qwen settings (detection
# stays on), and proves that the halted worker classifies unknown halt-prompt
# while its record alone still reads busy, that crew state reads blocked, that
# a steer's doorbell is not typed into the dialog, and that relaunch and exit
# replace and stop a halted worker. It fails naming the Herdr and qwen versions.
#
# FM_QWEN_BASE_URL (default http://127.0.0.1:11434/v1) names the
# OpenAI-compatible endpoint and FM_QWEN_MODEL (default qwen3-coder:30b) the
# model it serves; the guard skips when that endpoint is unreachable. Prompts
# are submitted, so it is opt-in. Run it after every Herdr or qwen upgrade and
# before trusting docs/verification/runtime-backends.md "Qwen Code". Always
# runs on a private, named, throwaway lab session provisioned and torn down by
# bin/fm-herdr-lab.sh, never the default one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_QWEN_LOOP_DIALOG_LIVE herdr qwen jq curl git

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

VERSION="herdr $(herdr --version 2>&1 | head -1 | sed 's/^herdr //'), qwen $(qwen --version 2>/dev/null)"
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
pass() { printf 'ok - %s: %s\n' "$VERSION" "$1"; }

BASE_URL=${FM_QWEN_BASE_URL:-http://127.0.0.1:11434/v1}
MODEL=${FM_QWEN_MODEL:-qwen3-coder:30b}
if ! curl -fsS --max-time 5 "$BASE_URL/models" >/dev/null 2>&1; then
  printf 'skip: live: %s has no reachable model endpoint at %s\n' "$VERSION" "$BASE_URL"
  exit 0
fi

SESSION=$(fm_herdr_lab_name qwen-loop)
ID="qwen-loop-live-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/qld.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
PANE_ID=
TARGET=
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
cleanup() {
  local status=$?
  if [ -n "$PANE_ID" ]; then
    lab pane send-keys "$PANE_ID" escape >/dev/null 2>&1 || true
    lab pane send-keys "$PANE_ID" ctrl+u >/dev/null 2>&1 || true
    lab pane send-text "$PANE_ID" '/quit' >/dev/null 2>&1 || true
    lab pane send-keys "$PANE_ID" enter >/dev/null 2>&1 || true
    sleep 2
  fi
  herdr_safe_stop_and_delete "$SESSION" || status=1
  # fm-spawn writes the per-task hooks read-only.
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB" "/tmp/fm-$ID" "/tmp/fm-$ID+"*
  exit "$status"
}
trap cleanup EXIT
fm_herdr_lab_provision "$SESSION" >/dev/null || fail "could not provision the isolated Herdr lab session"

mkdir -p "$H/state" "$H/data/$ID" "$H/config" "$H/projects" "$LAB/user-home/.qwen"
fm_git_worktree "$PROJ" "$WT" "fm/$ID"
touch "$H/state/.last-watcher-beat"
printf 'OPENAI_API_KEY=ollama\nOPENAI_BASE_URL=%s\nOPENAI_MODEL=%s\n' "$BASE_URL" "$MODEL" > "$LAB/user-home/.qwen/.env"
# Self-update off, and a per-turn tool-call cap the plan below exceeds, so the
# loop detector fires; loop detection itself is left at its default, on.
jq -n '{"$version": 4, general: {enableAutoUpdate: false}, model: {maxToolCallsPerTurn: 3}}' \
  > "$LAB/user-home/.qwen/settings.json"
cat > "$H/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Runtime verification only. Run `date +%N` six times, each as its own shell call, one call at a time. Then reply DONE.

## Firstmate spec
Do not edit any file.
EOF

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
export HERDR_SESSION="$SESSION"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "${CONTAINER_RAW#*$'\t'}") || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
TARGET="$SESSION:$PANE_ID"
fm_write_meta "$H/state/$ID.meta" "window=$TARGET" "endpoint_task_id=$ID" "worktree=$WT" "project=$PROJ" \
  harness=qwen kind=ship mode=no-mistakes yolo=off "branch=fm/$ID" "model=$MODEL" effort=default \
  backend=herdr "herdr_session=$SESSION" "herdr_workspace_id=${CONTAINER#*:}" \
  "herdr_tab_id=$TAB_ID" "herdr_pane_id=$PANE_ID"
# The pane shell is the worker's environment: qwen reads only the guard's home.
lab pane run "$PANE_ID" "export HOME='$LAB/user-home'" >/dev/null 2>&1 || fail "could not set the pane HOME"
sleep 1

control() { env FM_HOME="$H" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" "$ID" "$@" 2>&1; }
tail40() { fm_backend_capture herdr "$TARGET" 40 "fm-$ID" 2>/dev/null; }
halted() { [[ $(tail40) == *'A potential loop was detected'* ]]; }
until_true() {  # <seconds> <condition...>
  local i=0
  while [ "$i" -lt $(( $1 * 2 )) ]; do
    "${@:2}" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

out=$(control relaunch --note 'guard: launch into the loop halt') || fail "relaunch failed: $out"
until_true 240 halted || fail "qwen never opened its loop-detection dialog: $(tail40 | tail -8)"
sleep 3

TAIL=$(tail40)
record=$(fm_busy_classify herdr "$TARGET" qwen "$ID" "$H/state" '')
[ "$record" = 'busy qwen-hook' ] \
  || fail "the busy record alone read '$record', not 'busy qwen-hook', so this halt cannot show the pane read overriding it"
verdict=$(fm_busy_classify herdr "$TARGET" qwen "$ID" "$H/state" "$TAIL")
[ "$verdict" = 'unknown halt-prompt' ] || fail "the halted worker classified '$verdict', not 'unknown halt-prompt': $(printf '%s' "$TAIL" | tail -12)"
dialog=$(fm_composer_blocking_dialog "$TAIL") || dialog=
[ "$dialog" = 'qwen loop-detection dialog' ] || fail "the blocking-dialog check named '$dialog' on the halted pane"
pass "a halted qwen classifies unknown halt-prompt while its record still reads busy"

crew=$(env FM_HOME="$H" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1)
[[ $crew == 'state: blocked'*'halt-prompt'* ]] || fail "crew state did not read blocked on the halt: $crew"
pass "crew state reads the halted qwen as blocked"

env FM_HOME="$H" "$ROOT/bin/fm-send.sh" "$ID" 'guard steer' >/dev/null 2>&1 || fail "the steer was not durably recorded"
[ -f "$H/state/$ID.inbox/001.msg" ] || fail "the steer left no inbox record"
sleep 2
halted || fail "the steer's doorbell reached the loop-detection dialog: $(tail40 | tail -8)"
pass "a steer is recorded and its doorbell is not typed into the dialog"

out=$(control relaunch --note 'guard: relaunch of the halted qwen') || fail "relaunch of the halted qwen failed: $out"
[[ $out == *"relaunched $ID "* ]] || fail "relaunch of the halted qwen did not report a replacement: $out"
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "no replacement qwen is alive after relaunching the halted one"
pass "relaunch replaces a halted qwen on the same endpoint"

until_true 240 halted || fail "the replacement qwen never reached its own loop-detection dialog: $(tail40 | tail -8)"
sleep 3
out=$(control exit) || fail "exit of the halted replacement failed: $out; screen: $(tail40 | tail -12)"
[[ $out == stopped* ]] && [ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail "exit did not stop the halted replacement: $out"
pass "exit stops a halted qwen"
