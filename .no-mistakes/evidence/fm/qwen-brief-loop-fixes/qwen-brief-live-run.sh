#!/usr/bin/env bash
# Live check of the compact qwen brief (no-mistakes test phase evidence driver).
# Usage: qwen-brief-live-run.sh <worktree-root> <out-dir> <note|spawn> [include]
#   note  : launch the real qwen worker with `fm-control.sh relaunch --note`, the
#           flow fm-crew-state prescribes after a loop halt (note goes above # Start).
#   spawn : launch with `fm-spawn.sh --relaunch` onto the agent-free pane (no note).
#   include: also give the lab home a config/brief-include.md.
# Runs only in a named fm-lab-* Herdr session provisioned/torn down via
# bin/fm-herdr-lab.sh, with a throwaway FM_HOME, project, bare origin and a stub gh-axi.
set -u
ROOT=$1 OUT=$2 HOW=$3 INCLUDE=${4:-} STEER=${5:-}
mkdir -p "$OUT"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
log() { printf '%s\n' "$*" | tee -a "$OUT/run.log"; }

SESSION=$(fm_herdr_lab_name qwen-brief)
ID="qwen-brief-$HOW-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/qbr.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
H="$LAB/home" WT="$LAB/wt" PROJ="$LAB/project" FAKEBIN="$LAB/bin"
PANE_ID= TARGET=
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
cleanup() {
  if [ -n "$PANE_ID" ]; then
    lab pane send-keys "$PANE_ID" escape >/dev/null 2>&1 || true
    lab pane send-keys "$PANE_ID" ctrl+u >/dev/null 2>&1 || true
    lab pane send-text "$PANE_ID" '/quit' >/dev/null 2>&1 || true
    lab pane send-keys "$PANE_ID" enter >/dev/null 2>&1 || true
    sleep 2
  fi
  herdr_safe_stop_and_delete "$SESSION" && log "teardown: $SESSION stopped and deleted"
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB" "/tmp/fm-$ID" "/tmp/fm-$ID+"*
}
trap cleanup EXIT
log "session=$SESSION id=$ID how=$HOW include=${INCLUDE:-no}"
fm_herdr_lab_provision "$SESSION" >/dev/null || { log "provision failed"; exit 1; }

mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects" "$LAB/user-home/.qwen" "$FAKEBIN"
# Project on main with two existing files, a local bare origin, task worktree.
fm_git_init_commit "$PROJ"
mkdir -p "$PROJ/src"
cat > "$PROJ/src/names.js" <<'EOF'
function fullName(first, last) {
  return first + ' ' + last;
}

module.exports = { fullName };
EOF
cat > "$PROJ/src/index.js" <<'EOF'
const { fullName } = require('./names');

console.log(fullName('Ada', 'Lovelace'));
EOF
git -C "$PROJ" add -A && git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm 'add names'
fm_git_add_origin "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" worktree add --quiet -b "fm/$ID" "$WT"
touch "$H/state/.last-watcher-beat"

printf 'OPENAI_API_KEY=ollama\nOPENAI_BASE_URL=http://127.0.0.1:11434/v1\nOPENAI_MODEL=qwen3-coder:30b\n' > "$LAB/user-home/.qwen/.env"
jq -n '{"$version": 4, general: {enableAutoUpdate: false}}' > "$LAB/user-home/.qwen/settings.json"
printf '#!/usr/bin/env bash\necho "$*" >> %q\nprintf "created:\\n  number: 7\\n  url: https://github.com/o/r/pull/7\\nhelp[1]:\\n  Run gh-axi pr view 7\\n"\n' "$LAB/gh-axi.calls" > "$FAKEBIN/gh-axi"
chmod +x "$FAKEBIN/gh-axi"
[ "$INCLUDE" != include ] || printf 'Keep every commit message under 72 characters.\n' > "$H/config/brief-include.md"

cat > "$LAB/plan.md" <<'EOF'
1. Create `src/initials.js` with exactly this content:

```js
function initials(first, last) {
  return first[0] + '.' + last[0] + '.';
}

module.exports = { initials };
```

2. In `src/names.js`, add this function below `fullName`, and export it next to `fullName` so the last line reads `module.exports = { fullName, reversed };`:

```js
function reversed(first, last) {
  return last + ', ' + first;
}
```

3. In `src/index.js`, also require `initials` from `./initials` and `reversed` from `./names`, and after the existing `console.log` line add two lines:

```js
console.log(initials('Ada', 'Lovelace'));
console.log(reversed('Ada', 'Lovelace'));
```
EOF
DONE='node src/index.js | diff - <(printf '"'"'Ada Lovelace\nA.L.\nLovelace, Ada\n'"'"')'
FM_HOME="$H" "$ROOT/bin/fm-brief.sh" "$ID" project --mode direct-PR --harness qwen --plan "$LAB/plan.md" \
  --files 'src/initials.js src/names.js src/index.js' --done-command "$DONE" 2>&1 | tee -a "$OUT/run.log"
BRIEF="$H/data/$ID/brief.md"
sed -i 's/{TASK}/Add an initials helper and a reversed-name helper and print both from src\/index.js./; s/{FIRSTMATE_SPEC}/Follow the plan exactly. Edit only the three listed files./' "$BRIEF"
cp "$BRIEF" "$OUT/brief-scaffolded.md"
log "scaffolded brief: $(wc -c < "$BRIEF") chars; last heading: $(grep '^# ' "$BRIEF" | tail -1)"

. "$ROOT/bin/fm-backend.sh"
export HERDR_SESSION="$SESSION"
fm_backend_source herdr || { log "backend source failed"; exit 1; }
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || { log "container_ensure failed"; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "${CONTAINER_RAW#*$'\t'}") || { log "create_task failed"; exit 1; }
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
TARGET="$SESSION:$PANE_ID"
fm_write_meta "$H/state/$ID.meta" "window=$TARGET" "endpoint_task_id=$ID" "worktree=$WT" "project=$PROJ" \
  harness=qwen kind=ship mode=direct-PR yolo=off "branch=fm/$ID" model=qwen3-coder:30b effort=default \
  backend=herdr "herdr_session=$SESSION" "herdr_workspace_id=${CONTAINER#*:}" \
  "herdr_tab_id=$TAB_ID" "herdr_pane_id=$PANE_ID"
lab pane run "$PANE_ID" "export HOME='$LAB/user-home' PATH='$FAKEBIN':\"\$PATH\" GIT_AUTHOR_NAME=fmlab GIT_AUTHOR_EMAIL=fmlab@example.invalid GIT_COMMITTER_NAME=fmlab GIT_COMMITTER_EMAIL=fmlab@example.invalid" >/dev/null 2>&1
sleep 1

if [ -n "$STEER" ]; then
  mkdir -p "$H/state/$ID.inbox/handled"
  printf 'From firstmate: use exactly the commit title "feat: add name helpers" for this task.\n' > "$H/state/$ID.inbox/001.msg"
  log "pre-seeded steer 001.msg"
fi
START=$(date +%s)
case "$HOW" in
  note) out=$(env FM_HOME="$H" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Previous worker halted on a qwen loop-detection dialog before editing anything.' 2>&1) ;;
  spawn) out=$(env FM_HOME="$H" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch 2>&1) ;;
esac
log "launch ($HOW) rc=$?: $out"
cp "$BRIEF" "$OUT/brief-as-launched.md"
log "launched brief: $(wc -c < "$BRIEF") chars; last heading: $(grep '^# ' "$BRIEF" | tail -1); '## Progress note' line: $(grep -n '^## Progress note' "$BRIEF" | cut -d: -f1), '# Start' line: $(grep -n -x '# Start' "$BRIEF" | cut -d: -f1)"

STATUS="$H/state/$ID.status"
i=0; first_working=
while [ $i -lt 600 ]; do
  [ -n "$first_working" ] || { grep -q '^working ' "$STATUS" 2>/dev/null && first_working=$(( $(date +%s) - START )) && log "working line after ${first_working}s"; }
  grep -qE '^(done|blocked) ' "$STATUS" 2>/dev/null && break
  sleep 2; i=$((i + 2))
done
sleep 10
END=$(date +%s)
log "elapsed: $((END - START))s"
log "--- status file"; cat "$STATUS" 2>/dev/null | tee -a "$OUT/run.log"
log "--- crew state"; env FM_HOME="$H" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1 | tee -a "$OUT/run.log"
log "--- origin branch diff vs main"; git -C "$PROJ.origin.git" diff --stat main "fm/$ID" 2>&1 | tee -a "$OUT/run.log"
log "--- done command in worktree"; (cd "$WT" && bash -c "$DONE" && echo "done command exit 0") 2>&1 | tee -a "$OUT/run.log"
log "--- gh-axi calls"; cat "$LAB/gh-axi.calls" 2>/dev/null | tee -a "$OUT/run.log"
log "--- qwen edit-guard refusals in session logs"
grep -rhoE 'has not been read in this session|modified since you last read it' "$LAB/user-home/.qwen" 2>/dev/null | sort | uniq -c | tee -a "$OUT/run.log"
log "(none above means zero refusals)"
log "--- qwen requests (api request events)"; grep -rho '"type":"api_request\|qwen-code.api_request' "$LAB/user-home/.qwen" 2>/dev/null | wc -l | tee -a "$OUT/run.log"
log "--- inbox"; ls -R "$H/state/$ID.inbox" 2>&1 | tee -a "$OUT/run.log"; log "--- commit titles on origin branch"; git -C "$PROJ.origin.git" log --format=%s "main..fm/$ID" 2>&1 | tee -a "$OUT/run.log"
fm_backend_capture herdr "$TARGET" 60 "fm-$ID" > "$OUT/pane-final.txt" 2>/dev/null
log "pane capture saved"
mkdir -p "$OUT/qwen-chats"; find "$LAB/user-home/.qwen/projects" -name "*.jsonl" -exec cp {} "$OUT/qwen-chats/" \; 2>/dev/null; log "qwen chat logs: $(ls "$OUT/qwen-chats" | wc -l) file(s)"
