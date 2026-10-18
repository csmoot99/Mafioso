#!/usr/bin/env bash
# Drives the combined-merge skill's "Land" step 5 against the real
# bin/fm-teardown.sh: folded tasks and the integrator whose heads landed on
# base_branch=staging through a merge-commit combined PR are torn down without
# --force, and a folded task with a later unfolded commit is still refused.
# Fixture helpers are lifted verbatim from tests/fm-teardown.test.sh (lines
# before the first test_ function).
# Usage: combined-merge-teardown.sh <repo-root>
set -u
REPO=$1
HELPERS="$REPO/tests/.combined-merge-td-helpers.$$.sh"
first_test=$(grep -n '^test_' "$REPO/tests/fm-teardown.test.sh" | head -1 | cut -d: -f1)
head -n $((first_test - 1)) "$REPO/tests/fm-teardown.test.sh" > "$HELPERS"
# shellcheck disable=SC1090
. "$HELPERS"
rm -f "$HELPERS"
set +e
G() { git -c user.email=t@t -c user.name=t "$@"; }

# Build: origin has main and staging (staging carries a shared CHANGELOG.md).
# The folded task's worktree (task-x1) commits A on fm/task-x1 off staging;
# another worker's PR head B also edits CHANGELOG.md, so A and B conflict.
# The integrator cuts combined off staging, merges A and B with --no-ff,
# resolves the CHANGELOG conflict once, and GitHub's `--merge` lands combined
# into staging with a merge commit.
# Args: case_dir role(folded|integrator) head_branch(kept|deleted) staging_ref(fresh|stale) extra_commit(yes|no)
build() {
  local c=$1 role=$2 headb=$3 stg=$4 extra=$5 tmp a b comb
  tmp="$c/_int"
  G clone -q "$c/origin.git" "$tmp"
  printf 'changelog\n' > "$tmp/CHANGELOG.md"; G -C "$tmp" add CHANGELOG.md
  G -C "$tmp" commit -q -m "staging baseline"; G -C "$tmp" push -q origin HEAD:refs/heads/staging
  G -C "$c/project" fetch -q origin
  # Folded task worktree: recreate fm/task-x1 off origin/staging.
  G -C "$c/wt" checkout -q -B fm/task-x1 origin/staging
  printf 'changelog\n- A: feature a\n' > "$c/wt/CHANGELOG.md"; printf 'a\n' > "$c/wt/a.txt"
  G -C "$c/wt" add -A; G -C "$c/wt" commit -q -m "A: feature a"
  a=$(G -C "$c/wt" rev-parse HEAD)
  G -C "$c/wt" push -q origin fm/task-x1           # PR #7 head on the forge
  # Other worker's PR head B.
  G -C "$tmp" fetch -q origin
  G -C "$tmp" checkout -q -b fm/task-y2 origin/staging
  printf 'changelog\n- B: feature b\n' > "$tmp/CHANGELOG.md"; printf 'b\n' > "$tmp/b.txt"
  G -C "$tmp" add -A; G -C "$tmp" commit -q -m "B: feature b"
  b=$(G -C "$tmp" rev-parse HEAD)
  # Integrator: combined branch, --no-ff merges in order, one conflict resolution.
  G -C "$tmp" checkout -q -b fm/task-y2-combined origin/staging
  G -C "$tmp" merge -q --no-ff -m "Merge A" "$a" >/dev/null 2>&1
  G -C "$tmp" merge -q --no-ff -m "Merge B" "$b" >/dev/null 2>&1
  printf 'changelog\n- A: feature a\n- B: feature b\n' > "$tmp/CHANGELOG.md"
  G -C "$tmp" add CHANGELOG.md; G -C "$tmp" commit -q --no-edit
  comb=$(G -C "$tmp" rev-parse HEAD)
  G -C "$tmp" push -q origin fm/task-y2-combined
  # GitHub `gh pr merge --merge` of the combined PR: a merge commit on staging.
  G -C "$tmp" checkout -q staging 2>/dev/null || G -C "$tmp" checkout -q -b staging origin/staging
  G -C "$tmp" merge -q --no-ff -m "Merge pull request #90 (combined)" "$comb"
  G -C "$tmp" push -q origin staging
  echo "  folded head A=$a  other head B=$b  combined head=$comb"
  echo "  is A an ancestor of origin staging? $(G -C "$tmp" merge-base --is-ancestor "$a" origin/staging && echo yes)"
  if [ "$role" = integrator ]; then
    G -C "$c/project" fetch -q origin fm/task-y2-combined
    G -C "$c/wt" checkout -q -B fm/task-x1-combined "$comb"
    printf '%s\n' 'pr=https://github.com/example/repo/pull/7' "pr_head=$comb" >> "$c/state/task-x1.meta"
    add_gh_pr_merged_for_head "$c" "$comb"
    G -C "$tmp" push -q origin --delete fm/task-y2-combined
    G -C "$c/project" update-ref -d refs/remotes/origin/fm/task-y2-combined
  else
    printf '%s\n' 'pr=https://github.com/example/repo/pull/7' "pr_head=$a" >> "$c/state/task-x1.meta"
    add_gh_pr_merged_for_head "$c" "$a"
  fi
  if [ "$headb" = deleted ]; then
    G -C "$tmp" push -q origin --delete fm/task-x1
    G -C "$c/project" update-ref -d refs/remotes/origin/fm/task-x1
  fi
  if [ "$extra" = yes ]; then
    printf 'unfolded\n' > "$c/wt/later.txt"; G -C "$c/wt" add later.txt
    G -C "$c/wt" commit -q -m "later local commit the combined PR never carried"
  fi
  if [ "$stg" = fresh ]; then G -C "$c/project" fetch -q origin staging; fi
  echo "  project's origin/staging: $(G -C "$c/project" rev-parse --short origin/staging) (remote: $(G -C "$tmp" rev-parse --short origin/staging))"
  rm -rf "$tmp"
}

run_case() {
  local name=$1 role=$2 headb=$3 stg=$4 extra=$5 expect=$6 c rc
  echo "== case $name: role=$role head-branch=$headb local-staging=$stg extra-unfolded-commit=$extra (expect $expect)"
  c=$(make_case "$name")
  write_meta "$c" no-mistakes ship
  printf 'base_branch=staging\n' >> "$c/state/task-x1.meta"
  build "$c" "$role" "$headb" "$stg" "$extra"
  echo "  \$ bin/fm-teardown.sh task-x1"
  run_teardown "$c" > "$c/stdout" 2> "$c/stderr"; rc=$?
  sed 's/^/  | /' "$c/stderr" | grep -v '^  | *$' | head -12
  echo "  exit=$rc  meta-retained=$([ -f "$c/state/task-x1.meta" ] && echo yes || echo no)"
  if { [ "$expect" = ALLOW ] && [ "$rc" -eq 0 ]; } || { [ "$expect" = REFUSE ] && [ "$rc" -ne 0 ] && grep -q REFUSED "$c/stderr"; }; then
    echo "  RESULT: PASS ($expect)"
  else
    echo "  RESULT: FAIL (expected $expect)"; FAILED=1
  fi
  echo
}

FAILED=0
run_case folded-head-kept      folded     kept    fresh no  ALLOW
run_case folded-head-deleted   folded     deleted fresh no  ALLOW
run_case folded-stale-staging  folded     deleted stale no  ALLOW
run_case integrator-combined   integrator deleted fresh no  ALLOW
run_case folded-unfolded-extra folded     deleted fresh yes REFUSE
echo "overall: $([ "$FAILED" = 0 ] && echo PASS || echo FAIL)"
exit "$FAILED"
