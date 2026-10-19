#!/usr/bin/env bash
# Qwen Code on Herdr lifecycle-control guard. Opt in with FM_QWEN_HERDR_CONTROL_LIVE=1.
#
# Herdr never registers qwen, and qwen draws its composer glyph in a dark
# truecolor the ghost strip removes, so `fm-control exit` and `relaunch` on a
# running qwen under Herdr depend on two vendor facts no fixture can prove: the
# pane's foreground process identifies qwen, and the composer row reads empty
# only when it is. This guard launches a REAL qwen worker through the real
# control plane onto an isolated Herdr lab session and proves that an idle
# composer reads empty, a typed draft reads pending and refuses exit, and the
# worker exits and relaunches both idle and mid-turn with its task record and
# brief intact. It fails naming the Herdr and qwen versions.
#
# FM_QWEN_BASE_URL (default http://127.0.0.1:11434/v1) names the
# OpenAI-compatible endpoint and FM_QWEN_MODEL (default qwen3-coder:30b) the
# model it serves; the guard skips when that endpoint is unreachable. Prompts
# are submitted, so it is opt-in. Run it after every Herdr or qwen upgrade and
# before trusting docs/verification/runtime-backends.md "Herdr composer and
# lifecycle control". Always runs on a private, named, throwaway lab session
# provisioned and torn down by bin/fm-herdr-lab.sh, never the default one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_QWEN_HERDR_CONTROL_LIVE herdr qwen jq curl git

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

SESSION=$(fm_herdr_lab_name qwen-control)
ID="qwen-herdr-live-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/qhc.XXXXXX")
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
git -C "$WT" config user.name 'Qwen Herdr Guard'
git -C "$WT" config user.email qwen-herdr-guard@example.invalid
touch "$H/state/.last-watcher-beat"
# The operator's documented one-time precondition.
printf 'OPENAI_API_KEY=ollama\nOPENAI_BASE_URL=%s\nOPENAI_MODEL=%s\n' "$BASE_URL" "$MODEL" > "$LAB/user-home/.qwen/.env"
# Self-update off, so a run never changes the installed qwen under test.
jq -n '{"$version": 4, general: {enableAutoUpdate: false}}' > "$LAB/user-home/.qwen/settings.json"
cat > "$H/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Runtime verification only. Reply with the single word READY and nothing else. Do not call any tool.

## Firstmate spec
Do not call any tool and do not edit any file.
EOF

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
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
screen() { fm_backend_herdr_visible_capture "$TARGET" 2>/dev/null; }
until_screen() {  # <seconds> <condition...>
  local i=0
  while [ "$i" -lt $(( $1 * 2 )) ]; do
    "${@:2}" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
is_idle() { local s; s=$(screen); [[ $s != *'esc to cancel'* && $s == *'Type your message'* ]]; }
is_busy() { [[ $(screen) == *'esc to cancel'* ]]; }
launch() {  # <note>
  local out
  out=$(control relaunch --note "$1") || fail "relaunch ($1) failed: $out"
  until_screen 180 is_idle || fail "qwen never settled idle after relaunch ($1): $(screen | tail -8)"
  sleep 2
}
long_turn() {
  lab pane send-text "$PANE_ID" 'Write the integers from 1 to 800 in English words, one per line, with no other text. Do not call any tool.' >/dev/null 2>&1
  sleep 0.5
  lab pane send-keys "$PANE_ID" enter >/dev/null 2>&1
  until_screen 90 is_busy || fail "the long turn never showed its busy footer"
  sleep 2
}
meta_identity() { grep -E '^(window|endpoint_task_id|worktree|harness|herdr_pane_id)=' "$H/state/$ID.meta" | sort; }
META0=$(meta_identity)

launch 'guard: first launch onto an agent-free pane'
[ "$(fm_backend_composer_state herdr "$TARGET")" = empty ] \
  || fail "an idle qwen composer read '$(fm_backend_composer_state herdr "$TARGET")', not empty; identity '$(fm_backend_herdr_composer_identity "$TARGET" | tr '\t' ' ')'"
pass "an idle unregistered qwen composer reads empty"

lab pane send-text "$PANE_ID" 'guard draft' >/dev/null 2>&1
sleep 1
[ "$(fm_backend_composer_state herdr "$TARGET")" = pending ] || fail "a typed draft did not read pending"
if out=$(control exit); then fail "exit typed over a draft: $out"; fi
[[ $(screen) == *'guard draft'* ]] || fail "the refused exit lost the draft"
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "qwen did not survive the refused exit"
lab pane send-keys "$PANE_ID" ctrl+u >/dev/null 2>&1
sleep 1
pass "a typed draft reads pending and exit refuses without touching it"

out=$(control exit) || fail "idle exit failed: $out"
[[ $out == stopped* ]] && [ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail "idle exit did not stop qwen: $out"
pass "exit stops an idle qwen"

launch 'guard: relaunch after idle exit'
long_turn
out=$(control exit) || fail "mid-turn exit failed: $out"
[[ $out == stopped* ]] && [ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail "mid-turn exit did not stop qwen: $out"
pass "exit interrupts and stops a qwen in the middle of a long turn"

launch 'guard: relaunch after mid-turn exit'
long_turn
out=$(control relaunch --note 'guard: relaunch of a running qwen mid-turn') || fail "mid-turn relaunch failed: $out"
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "no replacement qwen is alive after the mid-turn relaunch"
until_screen 180 is_idle || fail "the replacement qwen never settled idle"
sleep 2
out=$(control exit) || fail "final exit failed: $out"
pass "relaunch replaces a running mid-turn qwen on the same endpoint"

[ "$(meta_identity)" = "$META0" ] || fail "the task record's identity changed: $(meta_identity)"
grep -q 'Reply with the single word READY' "$H/data/$ID/brief.md" || fail "the original brief text was not preserved"
[ "$(grep -c '^## Progress note' "$H/data/$ID/brief.md")" -eq 4 ] || fail "expected one progress note per relaunch"
pass "the task record and brief are intact after every exit and relaunch"
