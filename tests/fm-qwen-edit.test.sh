#!/usr/bin/env bash
# Behavior tests for bin/fm-qwen-edit.sh, the steps of a qwen task-kind edit,
# driven the way a qwen worker drives them: through the data/<id>/edit.sh that
# bin/fm-brief.sh --harness qwen --kind writes, in a real copy of a project
# whose docs/run.md holds `Port: 8080` and whose edits file lets the worker
# change one line of it and create docs/new.md. The contracts pinned here:
#   1. start writes the working line once and prints the project's setup file
#      for the kind; a publish before start does the same and refuses once,
#      uncounted. publish refuses, naming what to fix,
#      while no listed file changed, a has or lacks check fails, or the gate
#      fails; then it puts back a final newline the edit dropped, commits
#      only the listed files with the task's title,
#      pushes, opens the PR, and writes the done line carrying the URL gh-axi
#      printed. An untracked file outside the list is never committed and never
#      stops it, and a repeated publish finds the PR already open.
#   2. A tracked file outside the list, a listed file losing more lines than its
#      bound, a commit publish did not make, a change after publish committed,
#      and a fourth refusal each append needs-decision, reset the copy to the
#      commit the task started from with any new listed file removed, and leave
#      every later call printing only WAIT; nothing is published after a stop.
#   3. A call outside the copy's top level or off its branch writes the blocked
#      line and waits.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-qwen-edit)
fm_git_identity

# edit_fixture <name> [fm-brief args...]: the project, its origin, the copy on
# its task branch, the task's brief and edit.sh, and a fake forge holding one PR
# at most. Sets WT, ES, STATUS, MARK, BASE, ORIGIN, GH_ARGS, FAKEBIN and
# GATE_FLAG.
edit_fixture() {
  local name=$1 repo home id=qe-$1 edits
  repo="$TMP_ROOT/$name-repo" WT="$TMP_ROOT/$name-wt" home="$TMP_ROOT/$name-home"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/docs" "$repo/ai-map/qwen" "$TMP_ROOT/projects/r/ai-map/qwen"
  printf '# Run\nPort: 8080\nHost: local\n' > "$repo/docs/run.md"
  printf 'Keep each port on its own line.\n' > "$repo/ai-map/qwen/text-edit.md"
  git -C "$repo" add docs ai-map && git -C "$repo" commit -qm docs
  BASE=$(git -C "$repo" rev-parse HEAD) ORIGIN="$repo.origin.git"
  fm_git_add_origin "$repo" "$ORIGIN"
  git -C "$repo" fetch -q origin
  git -C "$repo" worktree add --quiet -b "fm/$id" "$WT" main
  : > "$TMP_ROOT/projects/r/ai-map/qwen/text-edit.md"
  mkdir -p "$home/data" "$home/state"
  edits="$TMP_ROOT/$name.edits" GATE_FLAG="$TMP_ROOT/$name-gate-fails"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  printf '%s\n' 'title docs: move the port to 9090' 'file docs/run.md 1' '   Replace `8080` with `9090`.' \
    'file docs/new.md 0' '   Create it with the line `# New`.' \
    'has docs/run.md Port: 9090' 'lacks docs/run.md Port: 8080' 'has docs/new.md # New' > "$edits"
  FM_HOME="$home" FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects" "$ROOT/bin/fm-brief.sh" "$id" r --mode direct-PR --harness qwen \
    --kind text-edit --edits "$edits" --done-command "test ! -e '$GATE_FLAG' || { echo gate-says-no; false; }" "${@:2}" >/dev/null \
    || fail "fm-brief.sh --kind refused the $name fixture"
  ES="$home/data/$id/edit.sh" STATUS="$home/state/$id.status" MARK="$home/data/$id/edit-stopped"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/$name") GH_ARGS="$TMP_ROOT/$name-gh.args"
  cat > "$FAKEBIN/gh-axi" <<EOF
#!/usr/bin/env bash
if [ "\$2" = list ]; then
  case " \$* " in *" --head fm/$id "*) [ ! -e $(printf %q "$GH_ARGS") ] || printf 'pull_requests[1]{url}:\n  "https://github.com/o/r/pull/30"\n' ;; esac
  exit 0
fi
[ ! -e $(printf %q "$GH_ARGS") ] || { echo "error: a pull request for fm/$id already exists"; exit 1; }
printf '%s\n' "\$@" > $(printf %q "$GH_ARGS")
printf 'created:\n  url: https://github.com/o/r/pull/30\n'
EOF
  chmod +x "$FAKEBIN/gh-axi"
}

step() { # <args...>: run edit.sh as the worker does, from the copy's top
  (cd "$WT" && PATH="$FAKEBIN:$PATH" bash "$ES" "$@")
}

good_edits() {
  sed -i 's/8080/9090/' "$WT/docs/run.md"
  printf '# New\n' > "$WT/docs/new.md"
}

# assert_stopped <why>: the stop line names why, the copy is back at BASE with
# nothing changed or left from a listed file, nothing reached the forge, and
# every later call only waits.
assert_stopped() {
  local out
  assert_contains "$(tail -1 "$STATUS")" "needs-decision [at=" "the stop wrote no needs-decision line"
  assert_contains "$(tail -1 "$STATUS")" "edit stopped: $1; the copy is reset to ${BASE:0:7}" "the stop line does not name why: $(tail -1 "$STATUS")"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail "the stop did not reset the copy to the base"
  [ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ] || fail "the stop left a tracked change"
  [ ! -e "$WT/docs/new.md" ] || fail "the stop left the new listed file"
  [ -f "$MARK" ] || fail "the stop was not recorded"
  [ ! -e "$GH_ARGS" ] || fail "a stopped edit reached the forge"
  for c in start publish; do
    out=$(step "$c") || fail "$c after a stop failed: $out"
    assert_contains "$out" "WAIT: this edit needs firstmate's answer" "$c after a stop did not wait"
  done
  assert_contains "$(tail -1 "$STATUS")" "needs-decision [at=" "a call after the stop wrote a status line"
}

test_an_edit_publishes_once_checked() {
  local out
  edit_fixture publish --base-branch release
  out=$(step start) || fail "start failed: $out"
  assert_contains "$out" "Keep each port on its own line." "start did not print the project's setup file"
  assert_contains "$out" "Follow it to make the edits under # The edits, then run: bash" "start did not say what comes next"
  step start >/dev/null
  [ "$(grep -c '^working \[at=[0-9]*\]: started$' "$STATUS")" -eq 1 ] || fail "start did not write the working line exactly once"
  out=$(step publish); [ "$?" -eq 1 ] || fail "publish ran with nothing changed"
  assert_contains "$out" "refused: no listed file changed" "publish with nothing changed did not say so"
  sed -i 's/8080/9091/' "$WT/docs/run.md"
  printf '# New\n' > "$WT/docs/new.md"
  out=$(step publish); [ "$?" -eq 1 ] || fail "publish passed a failed has check"
  assert_contains "$out" "refused: docs/run.md does not contain this exact text yet: Port: 9090" "a failed has check was not named"
  sed -i 's/9091/9090/' "$WT/docs/run.md"
  : > "$GATE_FLAG"
  out=$(step publish); [ "$?" -eq 1 ] || fail "publish passed a failed gate"
  assert_contains "$out" "gate-says-no" "a failed gate's output was not shown"
  assert_contains "$out" "refused: the project check failed" "a failed gate was not named"
  rm -f "$GATE_FLAG"
  printf 'scratch\n' > "$WT/gate-output.log"
  printf '# New' > "$WT/docs/new.md"
  truncate -s -1 "$WT/docs/run.md"
  out=$(step publish) || fail "a checked edit did not publish: $out"
  git -C "$WT" show HEAD:docs/run.md | cmp -s - <(printf '# Run\nPort: 9090\nHost: local\n') || fail "publish did not put back the final newline an edit dropped"
  git -C "$WT" show HEAD:docs/new.md | cmp -s - <(printf '# New\n') || fail "publish did not end a new file with a newline"
  assert_contains "$out" "done [at=" "publish did not print the done line"
  assert_contains "$out" "Published." "publish did not say it published"
  [ "$(git -C "$WT" log -1 --format=%s)" = "docs: move the port to 9090" ] || fail "the commit does not carry the task's title"
  [ "$(git -C "$WT" diff-tree --no-commit-id --name-only -r HEAD | tr '\n' ' ')" = "docs/new.md docs/run.md " ] || fail "the commit holds more or less than the listed files"
  [ "$(git -C "$WT" rev-parse HEAD^)" = "$BASE" ] || fail "publish made more than one commit"
  [ "$(git --git-dir="$ORIGIN" rev-parse "fm/qe-publish")" = "$(git -C "$WT" rev-parse HEAD)" ] || fail "publish did not push the branch"
  assert_contains "$(cat "$GH_ARGS")" $'--base\nrelease\n--title\ndocs: move the port to 9090' "the PR was not opened against the base branch with the title"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks must stay literal
  assert_contains "$(cat "$GH_ARGS")" '- `docs/run.md` no longer contains: Port: 8080' "the PR body does not list the checks"
  grep -qx 'done \[at=[0-9]*\]: PR https://github.com/o/r/pull/30' "$STATUS" || fail "the done line does not carry the PR URL"
  out=$(step publish) || fail "a repeated publish failed: $out"
  assert_contains "$out" "Published." "a repeated publish did not find the open PR"
  [ "$(grep -c '^done ' "$STATUS")" -eq 2 ] && [ ! -e "$MARK" ] || fail "a repeated publish stopped or wrote no done line"
  pass "publish refuses until the edits, checks and gate pass, then commits only the listed files, opens the PR and writes the done line"
}

test_unexpected_states_stop_and_reset() {
  local out
  edit_fixture outside
  step start >/dev/null
  good_edits
  printf 'more\n' >> "$WT/README.md"
  step publish >/dev/null
  assert_stopped "a file the brief does not list changed: README.md"

  edit_fixture bound
  good_edits
  sed -i 's/local/remote/' "$WT/docs/run.md"
  step publish >/dev/null
  assert_stopped "docs/run.md lost 2 existing lines, more than the 1 its edits change"

  edit_fixture commit
  good_edits
  git -C "$WT" add -A docs && git -C "$WT" commit -qm "my own commit"
  step publish >/dev/null
  assert_stopped "the copy holds a commit publish did not make: my own commit"

  edit_fixture after
  good_edits
  out=$(step publish); [ "$?" -eq 1 ] || fail "publish before start did not refuse"
  assert_contains "$out" "Keep each port on its own line." "publish before start did not print the setup file"
  assert_contains "$out" "refused: you skipped start" "publish before start did not say so"
  grep -q '^working \[at=[0-9]*\]: started$' "$STATUS" || fail "publish before start did not write the working line"
  step publish >/dev/null || fail "the after fixture did not publish"
  rm -f "$GH_ARGS"
  printf 'later\n' >> "$WT/docs/run.md"
  step publish >/dev/null
  assert_stopped "files changed after publish committed: docs/run.md"

  edit_fixture refusals
  step start >/dev/null
  for _ in 1 2 3; do step publish >/dev/null && fail "publish passed with nothing changed"; done
  [ ! -e "$MARK" ] || fail "three refusals stopped the edit"
  good_edits
  printf 'stray\n' > "$WT/stray.txt"
  sed -i 's/9090/9099/' "$WT/docs/run.md"
  step publish >/dev/null
  assert_stopped "publish refused four times, the last: docs/run.md does not contain this exact text yet: Port: 9090"
  [ -e "$WT/stray.txt" ] || fail "the stop removed an untracked file the brief never listed"
  pass "an unlisted change, a broken line bound, a foreign commit, a change after the commit, and a fourth refusal stop and reset the copy"
}

test_a_call_off_its_copy_waits() {
  local out
  edit_fixture off
  out=$(cd "$WT/docs" && PATH="$FAKEBIN:$PATH" bash "$ES" start) || fail "start from a subdirectory failed: $out"
  assert_contains "$out" "WAIT: this is not your own copy on the branch fm/qe-off" "start from a subdirectory did not wait"
  grep -qx 'blocked \[at=[0-9]*\]: launched in primary checkout, not an isolated worktree' "$STATUS" || fail "start from a subdirectory wrote no blocked line"
  git -C "$WT" checkout -q -b elsewhere
  out=$(step publish) || fail "publish off the branch failed: $out"
  assert_contains "$out" "WAIT: this is not your own copy" "publish off the branch did not wait"
  ! grep -q '^working ' "$STATUS" || fail "a call off its copy wrote the working line"
  pass "a call outside the copy's top level or off its branch writes the blocked line and waits"
}

test_an_edit_publishes_once_checked
test_unexpected_states_stop_and_reset
test_a_call_off_its_copy_waits
