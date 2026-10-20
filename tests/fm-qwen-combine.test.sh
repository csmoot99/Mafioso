#!/usr/bin/env bash
# Behavior tests for bin/fm-qwen-combine.sh, the steps of a qwen combine,
# driven the way a qwen worker drives them: through the data/<id>/combine.sh
# that bin/fm-brief.sh --harness qwen --combine writes, in a real copy of a
# project whose PR heads fork from one base. #11 adds b.txt and merges
# cleanly; #12 and #13 rewrite the same line of a.txt, so folding #13 after
# #12 stops on a conflict there. The contracts pinned here:
#   1. A fold merges the exact head with its merge message, the first fold
#      writes the working line, and a conflicted step commits only once no
#      git conflict-marker line is left, a longer setext underline not being
#      one, and nothing outside its conflicted files changed.
#   2. Only publish writes the done line, after the gate passed, the branch
#      was pushed, and gh-axi printed a PR URL, which the line carries; a
#      repeated publish finds the PR already open for the branch instead of
#      opening another.
#   3. A conflict the step did not expect, a moved base, and the worker's own
#      stop append needs-decision, reset the copy to the base, and leave every
#      later call printing only WAIT; nothing is published after a stop.
#   4. A call outside the copy's top level or off its branch writes the
#      blocked line and waits.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-qwen-combine)
fm_git_identity

# combine_fixture <name> <step 2 conflicts> <step 3 conflicts> [fm-brief args...]:
# a home, a project copy on its task branch, and a combine of #11, #12 and #13
# whose steps 2 and 3 expect the given conflicted files ("-" for a clean step).
# Sets HOME_DIR, ID, WT, CS, STATUS, BASE, H11, H12, H13, FAKEBIN, GH_ARGS and
# GATE_FLAG.
combine_fixture() {
  local name=$1 repo file k paths note
  repo="$TMP_ROOT/$name-repo" WT="$TMP_ROOT/$name-wt" HOME_DIR="$TMP_ROOT/$name-home" ID="qc-$name"
  fm_git_init_commit "$repo"
  printf 'one\ntwo\nthree\n' > "$repo/a.txt"
  git -C "$repo" add a.txt && git -C "$repo" commit -qm base
  BASE=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -qb pr11 && printf 'b\n' > "$repo/b.txt" && git -C "$repo" add b.txt && git -C "$repo" commit -qm b
  H11=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -qb pr12 main && printf 'one\ntwo-12\nthree\n' > "$repo/a.txt" && git -C "$repo" commit -qam 12
  H12=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -qb pr13 main && printf 'one\ntwo-13\nthree\n' > "$repo/a.txt" && git -C "$repo" commit -qam 13
  H13=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" worktree add --quiet -b "fm/$ID" "$WT" main
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
  file="$TMP_ROOT/$name.combine"
  {
    printf 'title Combine #11, #12 and #13\nbase %s\n' "$BASE"
    printf 'fold https://github.com/o/r/pull/11 pr11 %s\n' "$H11"
    for k in 2 3; do
      if [ "$k" = 2 ]; then paths=$2 note="fold https://github.com/o/r/pull/12 pr12 $H12"; else paths=$3 note="fold https://github.com/o/r/pull/13 pr13 $H13"; fi
      if [ "$paths" = - ]; then
        printf '%s\n' "$note"
      else
        printf '%s %s\n   - Keep both lines.\n' "$note" "$paths"
      fi
    done
  } > "$file"
  GATE_FLAG="$TMP_ROOT/$name-gate-fails"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$ID" r --mode direct-PR --harness qwen \
    --combine "$file" --done-command "test ! -e '$GATE_FLAG'" "${@:4}" >/dev/null || fail "fm-brief.sh --combine refused the $name fixture"
  CS="$HOME_DIR/data/$ID/combine.sh" STATUS="$HOME_DIR/state/$ID.status"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/$name") GH_ARGS="$TMP_ROOT/$name-gh.args"
  # A forge holding one PR at most: pr create opens #20 once, and pr list finds
  # it open for the task branch.
  cat > "$FAKEBIN/gh-axi" <<EOF
#!/usr/bin/env bash
if [ "\$2" = list ]; then
  case " \$* " in *" --head fm/$ID "*) [ ! -e $(printf %q "$GH_ARGS") ] || printf 'pull_requests[1]{url}:\n  "https://github.com/o/r/pull/20"\n' ;; esac
  exit 0
fi
[ ! -e $(printf %q "$GH_ARGS") ] || { echo "error: a pull request for fm/$ID already exists"; exit 1; }
printf '%s\n' "\$@" > $(printf %q "$GH_ARGS")
printf 'created:\n  url: https://github.com/o/r/pull/20\n'
EOF
  chmod +x "$FAKEBIN/gh-axi"
}

step() { # <args...>: run combine.sh as the worker does, from the copy's top
  (cd "$WT" && PATH="$FAKEBIN:$PATH" bash "$CS" "$@")
}

test_a_combine_folds_resolves_and_publishes() {
  local out
  combine_fixture publish - a.txt --base-branch release
  out=$(step fold 1) || fail "fold 1 failed: $out"
  assert_contains "$out" "Step 1 merged cleanly" "fold 1 did not report a clean merge"
  [ "$(grep -c '^working \[at=[0-9]*\]: started$' "$STATUS")" -eq 1 ] || fail "fold 1 did not write the working line"
  [ "$(git -C "$WT" log -1 --format=%s)" = "Merge #11 from pr11 at $H11" ] || fail "fold 1 did not merge with its merge message"
  out=$(step fold 1) || fail "a repeated fold 1 failed: $out"
  assert_contains "$out" "already folded" "a repeated fold 1 did not say it was already folded"
  out=$(step fold 3); [ "$?" -eq 1 ] || fail "fold 3 ran before step 2"
  assert_contains "$out" "refused: step 2 is not done yet" "fold 3 before step 2 did not name the missing step"
  step fold 2 >/dev/null || fail "fold 2 failed"
  out=$(step fold 3) || fail "fold 3 failed: $out"
  assert_contains "$out" "Step 3 stopped on a conflict in a.txt, as the step says" "fold 3 did not report its expected conflict"
  out=$(step publish); [ "$?" -eq 1 ] || fail "publish ran with a merge still stopped"
  out=$(step commit 3); [ "$?" -eq 1 ] || fail "commit 3 concluded a merge with markers left"
  assert_contains "$out" "conflict markers are left" "commit 3 did not name the markers"
  for left in '=======' '||||||| base'; do
    printf 'one\ntwo-12\n%s\ntwo-13\nthree\n' "$left" > "$WT/a.txt"
    out=$(step commit 3); [ "$?" -eq 1 ] || fail "commit 3 concluded a merge with a '$left' line left"
  done
  printf 'Notes on a\n==========\none\ntwo-12\ntwo-13\nthree\n' > "$WT/a.txt"
  printf 'stray\n' > "$WT/c.txt"
  out=$(step commit 3); [ "$?" -eq 1 ] || fail "commit 3 committed a file outside its conflict"
  assert_contains "$out" "files outside this step's conflict changed: c.txt" "commit 3 did not name the outside file"
  rm "$WT/c.txt"
  out=$(step commit 3) || fail "commit 3 failed once resolved: $out"
  [ "$(git -C "$WT" log -1 --format=%s)" = "Merge #13 from pr13 at $H13" ] || fail "commit 3 did not keep the merge message"

  : > "$GATE_FLAG"
  out=$(step publish); [ "$?" -eq 1 ] || fail "publish ran past a failing gate"
  assert_contains "$out" "the gate failed" "publish did not report the failing gate"
  git -C "$TMP_ROOT/publish-repo.origin.git" rev-parse -q --verify "refs/heads/fm/$ID" >/dev/null && fail "publish pushed past a failing gate"
  rm "$GATE_FLAG"
  mv "$FAKEBIN/gh-axi" "$FAKEBIN/gh-axi.url"
  printf '#!/usr/bin/env bash\necho "error: no remote here"\n' > "$FAKEBIN/gh-axi"
  chmod +x "$FAKEBIN/gh-axi"
  out=$(step publish); [ "$?" -eq 1 ] || fail "publish succeeded when gh-axi printed no URL"
  assert_contains "$out" "gh-axi printed no PR URL" "publish did not report the missing URL"
  ! grep -q '^done ' "$STATUS" || fail "publish wrote done without a PR URL"
  mv "$FAKEBIN/gh-axi.url" "$FAKEBIN/gh-axi"
  out=$(step publish) || fail "publish failed: $out"
  assert_contains "$out" "Published." "publish did not tell the worker it published"
  [ "$(grep -c '^done \[at=[0-9]*\]: PR https://github.com/o/r/pull/20$' "$STATUS")" -eq 1 ] \
    || fail "publish did not write one done line carrying the URL gh-axi printed"
  [ "$(git -C "$TMP_ROOT/publish-repo.origin.git" rev-parse "refs/heads/fm/$ID")" = "$(git -C "$WT" rev-parse HEAD)" ] \
    || fail "publish did not push the combined branch"
  for h in "$H11" "$H12" "$H13"; do
    git -C "$WT" merge-base --is-ancestor "$h" HEAD || fail "the combined branch does not carry head $h"
  done
  grep -qxF -- "- https://github.com/o/r/pull/13 at $H13" "$GH_ARGS" || fail "the PR body does not list each folded PR at its head"
  grep -qxF "Combine #11, #12 and #13" "$GH_ARGS" || fail "the PR does not carry the combine's title"
  [ "$(sed -n 1,4p "$GH_ARGS" | tr '\n' ' ')" = "pr create --base release " ] \
    || fail "the PR does not target the combine's base branch"
  out=$(step publish) || fail "a repeated publish failed instead of finding its open PR: $out"
  [ "$(grep -c '^done \[at=[0-9]*\]: PR https://github.com/o/r/pull/20$' "$STATUS")" -eq 2 ] \
    || fail "a repeated publish did not report the PR already open"
  ! grep -q '^needs-decision\|^blocked' "$STATUS" || fail "a clean combine wrote a decision or blocker"
  pass "fm-qwen-combine.sh: folds each exact head, commits a resolved conflict past a setext underline, writes done only after a real PR, and publishes once"
}

test_an_unexpected_conflict_stops_and_waits() {
  local out
  combine_fixture stop - -
  { step fold 1 >/dev/null && step fold 2 >/dev/null; } || fail "the clean folds failed"
  out=$(step fold 3) || fail "an unexpected conflict exited nonzero, which a qwen worker reads as an error to fix"
  assert_contains "$out" "WAIT: step 3 needs firstmate's answer" "an unexpected conflict did not print WAIT"
  grep -q '^needs-decision \[at=[0-9]*\]: combine step 3 stopped: git stopped on a conflict in a.txt, but this step was to merge cleanly; the copy is reset to ' "$STATUS" \
    || fail "an unexpected conflict did not append needs-decision naming the step and file"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail "a stop did not reset the copy to the base"
  ! git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null || fail "a stop left the merge stopped"
  [ -z "$(git -C "$WT" status --porcelain)" ] || fail "a stop left changes in the copy"
  for args in "fold 1" "commit 3" publish; do
    read -r -a argv <<<"$args"
    out=$(step "${argv[@]}") || fail "$args after a stop exited nonzero"
    assert_contains "$out" "WAIT: step 3" "$args after a stop did not repeat the wait"
  done
  [ ! -e "$GH_ARGS" ] || fail "a stopped combine still opened a PR"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail "a call after a stop moved the copy"
  ! grep -q '^done ' "$STATUS" || fail "a stopped combine wrote done"

  combine_fixture own - a.txt
  { step fold 1 >/dev/null && step fold 2 >/dev/null && step fold 3 >/dev/null; } || fail "the folds before the worker's stop failed"
  out=$(step stop 3 "a.txt: one value, two-12 or two-13") || fail "the worker's stop exited nonzero"
  assert_contains "$out" "WAIT:" "the worker's stop did not print WAIT"
  grep -q '^needs-decision \[at=[0-9]*\]: combine step 3 stopped: a.txt: one value, two-12 or two-13;' "$STATUS" \
    || fail "the worker's stop did not carry what each side wants"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail "the worker's stop did not reset the copy to the base"

  combine_fixture moved - a.txt
  git -C "$WT" commit -q --allow-empty -m moved
  out=$(step fold 1) || fail "a moved base exited nonzero"
  assert_contains "$out" "WAIT: step 1" "a moved base did not stop at step 1"
  grep -q '^needs-decision .*: combine step 1 stopped: the copy starts at ' "$STATUS" || fail "a moved base did not append needs-decision"
  ! grep -q '^working ' "$STATUS" || fail "a moved base still wrote the working line"
  pass "fm-qwen-combine.sh: an unexpected conflict, the worker's own stop, and a moved base reset the copy and wait"
}

test_a_call_outside_its_copy_is_blocked() {
  local out
  combine_fixture place - a.txt
  mkdir -p "$WT/sub"
  out=$(cd "$WT/sub" && PATH="$FAKEBIN:$PATH" bash "$CS" fold 1) || fail "a call below the top level exited nonzero"
  assert_contains "$out" "WAIT: this is not your own copy" "a call below the top level did not wait"
  git -C "$WT" checkout -q -b other
  out=$(step fold 1) || fail "a call off the task branch exited nonzero"
  assert_contains "$out" "WAIT: this is not your own copy" "a call off the task branch did not wait"
  [ "$(grep -c '^blocked \[at=[0-9]*\]: launched in primary checkout, not an isolated worktree$' "$STATUS")" -eq 2 ] \
    || fail "a call outside the copy did not write the blocked line"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail "a call outside the copy merged"
  out=$(bash "$ROOT/bin/fm-qwen-combine.sh" fold 1 2>&1); [ "$?" -eq 2 ] || fail "the helper ran directly"
  assert_contains "$out" "never run it directly" "a direct run did not say how the helper is used"
  pass "fm-qwen-combine.sh: a call outside its copy writes the blocked line and waits, and the helper never runs directly"
}

test_a_combine_folds_resolves_and_publishes
test_an_unexpected_conflict_stops_and_waits
test_a_call_outside_its_copy_is_blocked
