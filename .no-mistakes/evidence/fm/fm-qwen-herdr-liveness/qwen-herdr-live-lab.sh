#!/usr/bin/env bash
# Live lab: a real qwen TUI in a guarded fm-lab-* Herdr session, classified by
# the fixed (target) adapter and by the base adapter, then driven through
# bin/fm-control.sh interrupt/exit from a disposable lab FM_HOME.
set -u
ROOT=$1        # worktree (target commit)
BASE=$2        # extracted base commit tree
EVID=$3        # evidence dir

. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION=$(bin_name=$("$ROOT/bin/fm-herdr-lab.sh" name qwenlive) && printf '%s' "$bin_name")
[ -n "$SESSION" ] || SESSION="fm-lab-qwenlive-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-qwen-lab.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup_all() {
  local status=$?
  herdr_safe_stop_and_delete "$SESSION" && echo "# teardown of $SESSION ok" || echo "# teardown of $SESSION FAILED"
  chmod -R u+w "$SCRATCH" "$LAB" /tmp/fm-qwenlab /tmp/fm-qwenlab+* 2>/dev/null; rm -rf "$SCRATCH" "$LAB" /tmp/fm-qwenlab /tmp/fm-qwenlab+*
  exit "$status"
}
trap cleanup_all EXIT

say() { printf '%s\n' "$*"; }
say "# herdr $(herdr --version | head -1), qwen $(qwen --version 2>/dev/null | head -1), lab session $SESSION"
fm_herdr_lab_prepare "$SESSION" || { say "prepare failed"; exit 1; }

. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || exit 1
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }

fm_backend_herdr_server_ensure "$SESSION" || { say "server ensure failed"; exit 1; }

# A real task worktree so the lab FM_HOME record validates like a crew worker.
git init -q "$SCRATCH/proj" && git -C "$SCRATCH/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$SCRATCH/proj" worktree add -q -b task-qwenlab "$SCRATCH/wt"

WS=$(lab workspace create --label fm-qwen-lab --cwd "$SCRATCH/wt" 2>&1) || { say "ws create failed: $WS"; exit 1; }
PANE_ID=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id // empty')
WS_ID=$(printf '%s' "$WS" | jq -r '.result.workspace.workspace_id // .result.workspace_id // empty')
TAB_ID=$(printf '%s' "$WS" | jq -r '.result.tab.tab_id // .result.root_pane.tab_id // empty')
say "# workspace=$WS_ID tab=$TAB_ID pane=$PANE_ID"
TARGET="$SESSION:$PANE_ID"

classify() {  # <label> <impl-root>
  local label=$1 impl=$2
  env -u HERDR_SESSION SESSION="$SESSION" PANE_ID="$PANE_ID" TARGET="$TARGET" IMPL="$impl" LABEL="$label" bash -c '
    . "$IMPL/bin/fm-backend.sh"
    fm_backend_source herdr >/dev/null 2>&1
    printf "%-6s process_state=%s pane_agent_state=%s backend_agent_state=%s\n" "$LABEL" \
      "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" \
      "$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")" \
      "$(fm_backend_agent_state herdr "$TARGET")"'
}
screen() { herdr pane read "$PANE_ID" --source visible --format text --session "$SESSION" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -${1:-14}; }

say ""
say "## Scenario A: real qwen running in the pane, never registered by Herdr"
lab pane run "$PANE_ID" qwen >/dev/null 2>&1 || { say "pane run qwen failed"; exit 1; }
for _ in $(seq 1 75); do
  [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" = agent ] && break
  sleep 0.2
done
sleep 3
say "\$ herdr agent get $PANE_ID   (registration as Herdr sees it)"
herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -c . 2>/dev/null || true
say "\$ herdr pane process-info --pane $PANE_ID  (foreground)"
herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null \
  | jq -c '[.result.process_info.foreground_processes[] | {pid, name, argv0, argv}]'
QWEN_PID=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '[.result.process_info.foreground_processes[] | select((.argv // []) | map(test("qwen")) | any) | .pid][0] // empty')
say "lab qwen pid=$QWEN_PID: $(ps -o pid=,args= -p "$QWEN_PID" 2>/dev/null)"
classify base "$BASE"
classify fixed "$ROOT"
say "\$ herdr pane read (qwen TUI, last lines)"
screen

# Lab FM_HOME and a qwen ship record pointing at the live pane.
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
ID=qwenlab
mkdir -p "$LAB/data/$ID"
printf '# Task\n## Captain'"'"'s intent\nLive qwen herdr liveness lab.\n\n## Firstmate spec\nNone.\n' > "$LAB/data/$ID/brief.md"
{
  echo "window=$TARGET"
  echo "endpoint_task_id=$ID"
  echo "worktree=$SCRATCH/wt"
  echo "project=$SCRATCH/proj"
  echo "harness=qwen"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "tasktmp=/tmp/fm-$ID"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WS_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$LAB/state/$ID.meta"

fmctl() {  # <impl-root> <args...>
  local impl=$1; shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" "$impl/bin/fm-control.sh" "$@"
}

say ""
say "## Scenario B: fm-control.sh interrupt on the live qwen worker"
say "\$ [base]  fm-control.sh $ID interrupt"
fmctl "$BASE" "$ID" interrupt 2>&1; say "(exit $?)"
say "\$ [fixed] fm-control.sh $ID interrupt"
fmctl "$ROOT" "$ID" interrupt 2>&1; say "(exit $?)"
sleep 1
say "qwen still alive after interrupt: $(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")"

say ""
say "## Scenario C: adversarial - unreadable process view on an unregistered pane"
FAKEPS="$SCRATCH/failps"; printf '#!/bin/sh\nexit 1\n' > "$FAKEPS"; chmod +x "$FAKEPS"
# Bare shell pane in a second workspace so the foreground is shells only and
# the ps read is what decides.
WS2=$(lab workspace create --label fm-qwen-lab-shell --cwd "$SCRATCH/wt" 2>&1)
PANE2=$(printf '%s' "$WS2" | jq -r '.result.root_pane.pane_id // empty')
sleep 2
say "bare shell pane $PANE2, readable ps:   pane_agent_state=$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE2") backend_agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE2")"
say "bare shell pane $PANE2, failing ps:    pane_agent_state=$(FM_HERDR_PS_BIN="$FAKEPS" fm_backend_herdr_pane_agent_state "$SESSION" "$PANE2") backend_agent_state=$(FM_HERDR_PS_BIN="$FAKEPS" fm_backend_agent_state herdr "$SESSION:$PANE2")"
say "tab_is_husk on bare shell (readable): $(fm_backend_herdr_tab_is_husk "$SESSION" "$PANE2" >/dev/null 2>&1; echo rc=$?)  (failing ps): $(FM_HERDR_PS_BIN="$FAKEPS" fm_backend_herdr_tab_is_husk "$SESSION" "$PANE2" >/dev/null 2>&1; echo rc=$?)"

say ""
say "## Scenario D: fm-control.sh exit on the live qwen"
say "screen before exit:"; screen 4
say "\$ [base]  fm-control.sh $ID exit"
fmctl "$BASE" "$ID" exit 2>&1; say "(exit $?)"
say "\$ [fixed] fm-control.sh $ID exit"
fmctl "$ROOT" "$ID" exit 2>&1; say "(exit $?)"
if kill -0 "$QWEN_PID" 2>/dev/null; then say "lab qwen pid $QWEN_PID still running (nothing was typed into it)"; else say "lab qwen pid $QWEN_PID gone"; fi

qwen_pid_of_pane() { herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '[.result.process_info.foreground_processes[] | select((.argv // []) | map(test("qwen")) | any) | .pid][0] // empty'; }
wait_shell() { for _ in $(seq 1 100); do [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" = shell ] && return 0; sleep 0.2; done; return 1; }

say ""
say "## Scenario E: qwen quits to the shell - the agent-free pane still reads dead and interrupt refuses"
lab pane send-text "$PANE_ID" '/quit' >/dev/null 2>&1; sleep 0.6
lab pane send-keys "$PANE_ID" Enter >/dev/null 2>&1
wait_shell || { lab pane send-keys "$PANE_ID" Enter >/dev/null 2>&1; wait_shell; }
if kill -0 "$QWEN_PID" 2>/dev/null; then say "lab qwen pid $QWEN_PID STILL RUNNING"; else say "lab qwen pid $QWEN_PID has exited"; fi
classify base "$BASE"
classify fixed "$ROOT"
say "\$ [fixed] fm-control.sh $ID interrupt"
fmctl "$ROOT" "$ID" interrupt 2>&1; say "(exit $?)"
say "tab_is_husk on the quit-qwen pane (fixed): $(fm_backend_herdr_tab_is_husk "$SESSION" "$PANE_ID" >/dev/null 2>&1; echo rc=$?)"

say ""
say "## Scenario F: fm-control.sh relaunch from the dead pane (fixed) - replacement qwen reads alive"
say "\$ [fixed] FM_CONTROL_LAUNCH_WAIT=60 fm-control.sh $ID relaunch --note 'lab relaunch'"
FM_CONTROL_LAUNCH_WAIT=60 fmctl "$ROOT" "$ID" relaunch --note 'lab relaunch' 2>&1 | grep -v '^●'; say "(exit ${PIPESTATUS[0]})"
NEWPID=$(qwen_pid_of_pane)
say "replacement qwen pid=${NEWPID:-none}: $(ps -o args= -p "${NEWPID:-0}" 2>/dev/null | cut -c1-60)"
herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -c . 2>/dev/null || true
classify base "$BASE"
classify fixed "$ROOT"
say "\$ [fixed] fm-control.sh $ID interrupt"
fmctl "$ROOT" "$ID" interrupt 2>&1; say "(exit $?)"
[ -z "$NEWPID" ] || kill "$NEWPID" 2>/dev/null
wait_shell; say "replacement stopped; pane process state: $(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")"

say ""
say "## Scenario G: the same relaunch with the BASE code - reproduces the reported failure"
say "\$ [base]  FM_CONTROL_LAUNCH_WAIT=20 fm-control.sh $ID relaunch --note 'lab relaunch base'"
FM_CONTROL_LAUNCH_WAIT=20 fmctl "$BASE" "$ID" relaunch --note 'lab relaunch base' 2>&1 | grep -v '^●'; say "(exit ${PIPESTATUS[0]})"
BPID=$(qwen_pid_of_pane)
say "qwen launched by base relaunch: pid=${BPID:-none} $(ps -o args= -p "${BPID:-0}" 2>/dev/null | cut -c1-60)"
classify base "$BASE"
[ -z "$BPID" ] || kill "$BPID" 2>/dev/null
