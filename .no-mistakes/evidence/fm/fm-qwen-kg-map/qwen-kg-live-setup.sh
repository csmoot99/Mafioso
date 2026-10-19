#!/usr/bin/env bash
# Live check: a REAL qwen worker (qwen3-coder:30b on local Ollama) launched by
# the change's bin/fm-spawn.sh (through bin/fm-control.sh relaunch) on a pane of
# an fm-lab-* Herdr session, against a disposable clone of 420usa (the priority
# project) whose fresh worktree has no node_modules and no kg graph.
# Usage: qwen-kg-live-setup.sh <worktree-root> <state-file>
set -u
ROOT=$1 STATEF=$2
. "$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/lib.sh" 2>/dev/null || true
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS

BASE_URL=http://127.0.0.1:11434/v1
MODEL=qwen3-coder:30b
SESSION=$(fm_herdr_lab_name qwen-kg)
ID="qwen-kg-live-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/qkg.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
H="$LAB/home"
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || { echo "lab home create failed"; exit 1; }
PROJ="$H/projects/420usa"
WT="$LAB/wt"
printf 'SESSION=%s\nID=%s\nLAB=%s\nH=%s\nPROJ=%s\nWT=%s\n' "$SESSION" "$ID" "$LAB" "$H" "$PROJ" "$WT" > "$STATEF"

"$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" >/dev/null || { echo "provision failed"; exit 1; }

# Disposable 420usa: local bare origin cloned from the operator clone (read only).
git clone --quiet --bare "$HOME/firstmate/projects/420usa" "$LAB/origin.git"
git clone --quiet "$LAB/origin.git" "$PROJ"
git -C "$PROJ" worktree add --quiet -b "fm/$ID" "$WT" origin/HEAD
git -C "$WT" config user.name 'Qwen KG Live'
git -C "$WT" config user.email qwen-kg-live@example.invalid
mkdir -p "$H/data/$ID" "$LAB/user-home/.qwen" "$LAB/stubbin"
touch "$H/state/.last-watcher-beat"
printf 'auto\n' > "$H/config/qwen-approval-mode"
printf 'OPENAI_API_KEY=ollama\nOPENAI_BASE_URL=%s\nOPENAI_MODEL=%s\n' "$BASE_URL" "$MODEL" > "$LAB/user-home/.qwen/.env"
jq -n '{"$version": 4, general: {enableAutoUpdate: false}}' > "$LAB/user-home/.qwen/settings.json"
# Stub forge CLIs so the worker can never open a real PR.
for t in gh gh-axi; do
  printf '%s\n' '#!/usr/bin/env bash' 'echo "$0 $*" >> "'"$LAB"'/forge.log"; echo https://example.invalid/pr/1' > "$LAB/stubbin/$t"
  chmod +x "$LAB/stubbin/$t"
done

cat > "$LAB/plan.md" <<'EOF'
Find where the function `publishedNap` is defined in this repository.
Write `x.txt` holding exactly one line: that definition's `<path>:<start>-<end>`, where `<path>` is relative to the repository root.
EOF
FM_HOME="$H" "$ROOT/bin/fm-brief.sh" "$ID" 420usa --mode direct-PR --harness qwen \
  --plan "$LAB/plan.md" --files x.txt --done-command 'grep -q "nap.ts:" x.txt' || { echo "brief failed"; exit 1; }
sed -i -e 's/^{TASK}$/Record where publishedNap is defined./' -e 's/^{FIRSTMATE_SPEC}$/Follow the plan./' "$H/data/$ID/brief.md"

. "$ROOT/bin/fm-backend.sh"
export HERDR_SESSION="$SESSION"
fm_backend_source herdr || { echo "backend source failed"; exit 1; }
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || { echo "container_ensure failed"; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "${CONTAINER_RAW#*$'\t'}") || { echo "create_task failed"; exit 1; }
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
printf 'PANE_ID=%s\nTARGET=%s\n' "$PANE_ID" "$SESSION:$PANE_ID" >> "$STATEF"
cat > "$H/state/$ID.meta" <<EOF
window=$SESSION:$PANE_ID
endpoint_task_id=$ID
worktree=$WT
project=$PROJ
harness=qwen
kind=ship
mode=direct-PR
yolo=off
branch=fm/$ID
model=$MODEL
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=${CONTAINER#*:}
herdr_tab_id=$TAB_ID
herdr_pane_id=$PANE_ID
EOF
fm_herdr_lab_cli "$SESSION" pane run "$PANE_ID" "export HOME='$LAB/user-home' PATH='$LAB/stubbin':\$PATH" >/dev/null 2>&1
sleep 1
echo "setup ok: session=$SESSION id=$ID lab=$LAB"
echo "pre-launch: node_modules=$([ -e "$WT/node_modules" ] && echo yes || echo no) kg.db=$([ -e "$WT/ai-map/kg.db" ] && echo yes || echo no)"
start=$SECONDS
FM_HOME="$H" "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'live kg check: first launch' 2>&1
echo "relaunch exit=$? after $((SECONDS - start))s"
