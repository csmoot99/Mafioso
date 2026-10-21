#!/usr/bin/env bash
# capture.sh <lab> <id> <handoff-config-lines> <launch-env-lines> [harness]
# Builds a real fm-spawn launch for a task in lab home <lab> against a fake pane,
# writing <lab>/cases/<id>/launch.log. Uses the repo's own spawn fixtures.
set -u
ROOT=${FM_DRV_ROOT:-/home/work/.no-mistakes/worktrees/5f69104d19ce/01M5GBFE0QEKRV5P3XY7Y8JVGE}
. "$ROOT/tests/fixtures.sh"
lab=$1 id=$2 cfg=$3 env=$4 harness=${5:-codex}
case_dir="$lab/cases/$id"; mkdir -p "$case_dir"
fm_test_spawn_home "$lab" "$harness"
printf '%b' "$env" > "$lab/config/launch-env"
printf '%b' "$cfg" > "$lab/config/worker-context-handoff"
[ -f "$lab/data/$id/brief.md" ] || fm_test_spawn_brief "$lab" "$id" "Run the shell commands the Firstmate spec lists, one tool call each."
fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
fm_git_worktree "$case_dir/project" "$case_dir/wt" "wt-$id" >/dev/null 2>&1
: > "$case_dir/launch.log"
shift 5 2>/dev/null || shift $#
CODEX_HOME="$HOME/.codex" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
  fm_test_run_spawn "$lab" "$case_dir/wt" "$fakebin" "$id" "$case_dir/project" --model gpt-6-sol --mode no-mistakes --yolo off
echo "spawn rc=$?"
