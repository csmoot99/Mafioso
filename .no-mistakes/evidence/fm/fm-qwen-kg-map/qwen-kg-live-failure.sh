#!/usr/bin/env bash
# Adversarial live check in the same lab: a second qwen-shaped task on a fresh
# 420usa worktree (no node_modules, no graph) whose dependency install fails
# (pnpm on the spawn's PATH exits 1, as an offline cache miss would). The spawn
# must drop the kg-query line, keep the kg server connected (not excluded),
# print why, and still launch qwen with no MCP approval dialog. Also scaffolds
# a qwen brief for a project without a kg or ai-map to show no lookup lines.
# Usage: qwen-kg-live-failure.sh <worktree-root> <state-file>
set -u
ROOT=$1 STATEF=$2
. "$STATEF"
. "$ROOT/bin/fm-herdr-lab.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
ID2="$ID-fail"
WT2="$LAB/wt2"
git -C "$PROJ" worktree add --quiet -b "fm/$ID2" "$WT2" origin/HEAD
mkdir -p "$H/data/$ID2" "$LAB/failbin"
printf '%s\n' '#!/usr/bin/env bash' 'echo "ERR_PNPM_NO_OFFLINE_TARBALL simulated install failure" >&2; exit 1' > "$LAB/failbin/pnpm"
chmod +x "$LAB/failbin/pnpm"
FM_HOME="$H" "$ROOT/bin/fm-brief.sh" "$ID2" 420usa --mode direct-PR --harness qwen \
  --plan "$LAB/plan.md" --files x.txt --done-command 'grep -q "nap.ts:" x.txt' >/dev/null || { echo "brief failed"; exit 1; }
sed -i -e 's/^{TASK}$/Record where publishedNap is defined./' -e 's/^{FIRSTMATE_SPEC}$/Follow the plan./' "$H/data/$ID2/brief.md"
echo "scaffolded brief rule 3 (before spawn):"
awk '/^3\. /{on=1} /^4\. /{on=0} on' "$H/data/$ID2/brief.md"

. "$ROOT/bin/fm-backend.sh"
export HERDR_SESSION="$SESSION"
fm_backend_source herdr || exit 1
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT2") || { echo "container_ensure failed"; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID2" "$WT2" "${CONTAINER_RAW#*$'\t'}") || { echo "create_task failed"; exit 1; }
read -r TAB_ID PANE2 <<EOF
$TASK_IDS
EOF
printf 'ID2=%s\nWT2=%s\nPANE2=%s\n' "$ID2" "$WT2" "$PANE2" >> "$STATEF"
cat > "$H/state/$ID2.meta" <<EOF
window=$SESSION:$PANE2
endpoint_task_id=$ID2
worktree=$WT2
project=$PROJ
harness=qwen
kind=ship
mode=direct-PR
yolo=off
branch=fm/$ID2
model=qwen3-coder:30b
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=${CONTAINER#*:}
herdr_tab_id=$TAB_ID
herdr_pane_id=$PANE2
EOF
fm_herdr_lab_cli "$SESSION" pane run "$PANE2" "export HOME='$LAB/user-home' PATH='$LAB/stubbin':\$PATH" >/dev/null 2>&1
sleep 1
echo "pre-launch: node_modules=$([ -e "$WT2/node_modules" ] && echo yes || echo no)"
PATH="$LAB/failbin:$PATH" FM_HOME="$H" "$ROOT/bin/fm-control.sh" "$ID2" relaunch --note 'live kg check: install fails' 2>&1
echo "relaunch exit=$?"
echo "--- launch-brief rule 3 (after spawn):"
awk '/^3\. /{on=1} /^4\. /{on=0} on' "$H/data/$ID2/launch-brief.md"
echo "--- settings MCP keys:"
jq -c '{mcpServers, mcp}' "$H/state/$ID2.qwen-settings.json"
echo "--- kg-ingest.log:"
cat "$H/state/$ID2.kg-ingest.log"

# No-kg project: brief only.
mkdir -p "$H/projects/plain"
git -C "$H/projects/plain" init --quiet
FM_HOME="$H" "$ROOT/bin/fm-brief.sh" plain-qwen plain --mode direct-PR --harness qwen \
  --plan "$LAB/plan.md" --files x.txt --done-command 'test -s x.txt' >/dev/null || { echo "plain brief failed"; exit 1; }
echo "--- no-kg project brief rule 3:"
awk '/^3\. /{on=1} /^4\. /{on=0} on' "$H/data/plain-qwen/brief.md"
