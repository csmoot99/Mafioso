#!/usr/bin/env bash
# tests/fm-scope.test.sh - declared task scope: out-of-scope report, advisory overlap,
# and interface ownership through the backlog's blocked-by links (bin/fm-scope.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the ownership path)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-scope)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
printf '## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
export FM_HOME="$HOME_DIR"

scope() { "$ROOT/bin/fm-scope.sh" "$@" 2>&1; }
tasks() { "$ROOT/bin/fm-tasks-axi.sh" "$@" 2>&1; }

# A git project with one commit and a worktree-like clone per task.
PROJ="$TMP_ROOT/proj"
git init -q "$PROJ" && git -C "$PROJ" config user.email t@t && git -C "$PROJ" config user.name t
mkdir -p "$PROJ/src/cli" "$PROJ/docs"
echo a > "$PROJ/src/cli/main.ts"; echo b > "$PROJ/docs/INDEX.md"; echo c > "$PROJ/src/schema.ts"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm init

make_task() {  # <id> <scope-csv> <interfaces-csv>
  local id=$1 wt="$TMP_ROOT/wt-$1"
  git clone -q "$PROJ" "$wt" && git -C "$wt" config user.email t@t && git -C "$wt" config user.name t
  {
    echo "kind=ship"; echo "project=$PROJ"; echo "worktree=$wt"
    echo "base_sha=$(git -C "$wt" rev-parse HEAD)"
    [ -z "$2" ] || echo "scope=$2"
    [ -z "$3" ] || echo "interfaces=$3"
  } > "$HOME_DIR/state/$id.meta"
}

test_changed_reports_files_outside_declared_scope() {
  local out
  make_task t-a "src/cli" ""
  echo x >> "$TMP_ROOT/wt-t-a/src/cli/main.ts"
  out=$(scope changed t-a)
  assert_contains "$out" "within declared scope" "a change inside the declared directory is within scope"
  echo y >> "$TMP_ROOT/wt-t-a/docs/INDEX.md"
  echo n > "$TMP_ROOT/wt-t-a/src/new-untracked.ts"
  git -C "$TMP_ROOT/wt-t-a" commit -qam "wip"
  out=$(scope changed t-a)
  assert_contains "$out" "outside declared scope" "a committed change outside the scope is reported"
  assert_contains "$out" "docs/INDEX.md" "the committed outside file is named"
  assert_contains "$out" "src/new-untracked.ts" "an untracked outside file is named"
  assert_not_contains "$out" "src/cli/main.ts" "an in-scope file is not reported"
  make_task t-none "" ""
  echo z >> "$TMP_ROOT/wt-t-none/docs/INDEX.md"
  assert_equals "" "$(scope changed t-none)" "a task with no declared scope prints nothing"
  pass "fm-scope.sh: changed names exactly the files outside the declared scope"
}

test_scope_entries_are_exact_paths_or_directories() {
  local out
  make_task g-a "src/*.ts" ""
  echo x >> "$TMP_ROOT/wt-g-a/src/schema.ts"
  out=$(scope changed g-a)
  assert_contains "$out" "outside declared scope (src/*.ts): src/schema.ts" "a scope entry is a literal path, never a glob"
  make_task g-b "src/schema.ts,docs/" ""
  echo y >> "$TMP_ROOT/wt-g-b/src/schema.ts"
  echo z >> "$TMP_ROOT/wt-g-b/docs/INDEX.md"
  assert_contains "$(scope changed g-b)" "within declared scope" "an exact path and a directory prefix both cover their files"
  pass "fm-scope.sh: scope entries match exact paths and directory prefixes only"
}

test_non_ascii_paths_match_their_scope() {
  local out
  make_task u-a "docs" ""
  echo x > "$TMP_ROOT/wt-u-a/docs/café.md"
  assert_contains "$(scope changed u-a)" "within declared scope" "an untracked non-ASCII path is matched unquoted"
  git -C "$TMP_ROOT/wt-u-a" add -A && git -C "$TMP_ROOT/wt-u-a" commit -qm wip
  assert_contains "$(scope changed u-a)" "within declared scope" "a committed non-ASCII path is matched unquoted"
  make_task u-b "docs/café.md" ""
  out=$(scope overlap u-b)
  assert_contains "$out" "docs/café.md, which it has already changed" "a non-ASCII changed file is visible to the overlap check"
  pass "fm-scope.sh: non-ASCII paths are compared unquoted"
}

test_overlap_explains_and_never_blocks() {
  local out rc
  make_task o-a "src/cli,docs" "cli-registry"
  make_task o-b "src/cli/commands" "cli-registry"
  make_task o-c "src/schema.ts" ""
  echo q >> "$TMP_ROOT/wt-o-c/src/schema.ts"
  make_task o-d "unrelated/dir" ""
  out=$(scope overlap o-a); rc=$?
  expect_code 0 "$rc" "overlap is advisory and exits 0"
  assert_contains "$out" "live task o-b" "a declared-scope overlap names the other task"
  assert_contains "$out" "both change interface cli-registry" "a shared interface is named"
  assert_not_contains "$out" "o-d" "an unrelated task is not mentioned"
  make_task o-e "src/schema.ts" ""
  out=$(scope overlap o-e)
  assert_contains "$out" "src/schema.ts, which it has already changed" "an already changed file inside the declared scope is explained"
  make_task o-f "" ""
  assert_equals "" "$(scope overlap o-f)" "a task that declared nothing has nothing to compare"
  pass "fm-scope.sh: overlap explains shared scope, interfaces, and changed files without blocking"
}

test_ownership_orders_dispatch_through_blocked_by() {
  local out
  tasks add own-1 "owner of the cli contract" >/dev/null
  tasks add dep-1 "dependent one" >/dev/null
  tasks add dep-2 "dependent two" >/dev/null
  out=$(scope own own-1 dep-1 dep-2) || fail "own should record the links: $out"
  assert_contains "$(tasks show dep-1)" "blocked_by: own-1" "the dependent is blocked-by the owner"
  tasks start own-1 >/dev/null
  tasks "done" own-1 >/dev/null
  assert_contains "$(tasks show dep-1)" "blocked: no" "ownership ends when the owner is Done"

  tasks add own-2 "second owner" >/dev/null
  tasks add dep-3 "waits on own-2" >/dev/null
  scope own own-2 dep-3 >/dev/null || fail "own-2/dep-3 should record"
  out=$(scope own dep-3 own-2) && fail "a cycle must be refused"
  assert_contains "$out" "cycle" "the cycle refusal says why"
  tasks add dep-4 "already running" >/dev/null
  tasks start dep-4 >/dev/null
  out=$(scope own own-2 dep-4) && fail "an already dispatched dependent must be refused"
  assert_contains "$out" "already dispatched" "the dispatched-dependent refusal says why"
  out=$(scope own own-1 dep-3) && fail "a Done owner must be refused"
  assert_contains "$out" "already Done" "the finished-owner refusal says why"
  pass "fm-scope.sh: ownership is the backlog blocked-by link and cannot deadlock"
}

test_ownership_refuses_a_cycle_through_a_multi_blocker_task() {
  local out id
  for id in cy-a cy-b cy-c cy-d; do tasks add "$id" "cycle node $id" >/dev/null; done
  scope own cy-a cy-b >/dev/null || fail "cy-b should wait on cy-a"
  scope own cy-c cy-b >/dev/null || fail "cy-b should also wait on cy-c"
  scope own cy-b cy-d >/dev/null || fail "cy-d should wait on cy-b"
  out=$(scope own cy-d cy-a) && fail "a cycle through the first of two blockers must be refused"
  assert_contains "$out" "cycle" "the first-blocker refusal says why"
  out=$(scope own cy-d cy-c) && fail "a cycle through the last of two blockers must be refused"
  assert_contains "$out" "cycle" "the last-blocker refusal says why"
  assert_contains "$(tasks show cy-a)" "blocked: no" "the refused edge is not recorded"
  pass "fm-scope.sh: a cycle through a task with several blockers is refused"
}

test_spawn_scope_flags_are_refused_where_they_do_not_apply() {
  local out
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-spawn.sh" some-id "$PROJ" --scout --scope src 2>&1) && fail "--scope on a scout must be refused"
  assert_contains "$out" "fresh ship dispatch only" "scout refusal"
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-spawn.sh" some-id --relaunch --interface cli 2>&1) && fail "--interface on a relaunch must be refused"
  assert_contains "$out" "fresh ship dispatch only" "relaunch refusal"
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-spawn.sh" some-id "$PROJ" --mode no-mistakes --yolo off --scope "a b" 2>&1) && fail "a scope with a space must be refused"
  assert_contains "$out" "without spaces" "value validation"
  pass "fm-spawn.sh: --scope and --interface are refused outside a fresh ship dispatch"
}

test_changed_reports_files_outside_declared_scope
test_scope_entries_are_exact_paths_or_directories
test_non_ascii_paths_match_their_scope
test_overlap_explains_and_never_blocks
test_ownership_orders_dispatch_through_blocked_by
test_ownership_refuses_a_cycle_through_a_multi_blocker_task
test_spawn_scope_flags_are_refused_where_they_do_not_apply
