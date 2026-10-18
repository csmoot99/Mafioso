#!/usr/bin/env bash
# Drives the combined-merge skill's "Land" steps 1 and 3 against the real
# bin/fm-pr-merge.sh and bin/fm-pr-check.sh, with the repo's own forge mocks
# (helpers lifted verbatim from tests/fm-pr-merge.test.sh, lines before the
# first test_ function).
# Usage: combined-merge-landing.sh <repo-root>
set -u
REPO=$1
HELPERS="$REPO/tests/.combined-merge-helpers.$$.sh"
first_test=$(grep -n '^test_' "$REPO/tests/fm-pr-merge.test.sh" | head -1 | cut -d: -f1)
head -n $((first_test - 1)) "$REPO/tests/fm-pr-merge.test.sh" > "$HELPERS"
cd "$REPO/tests"
# shellcheck disable=SC1090
. "$HELPERS"
set +e

FOLDED=https://github.com/example/repo/pull/80
COMBINED=https://github.com/example/repo/pull/90
HEAD_SHA=9090909090909090909090909090909090909090

echo "== setup: integrator task task-x1 is a reused worker still bound to its own folded PR"
case_dir=$(make_case combined-integrator)
add_gh_mocks "$case_dir" "$HEAD_SHA"
: > "$case_dir/gh-axi.log"
printf 'pr=%s\n' "$FOLDED" >> "$case_dir/state/task-x1.meta"
cat "$case_dir/state/task-x1.meta"

echo
echo "== step A (adversarial): merge the combined PR before registering it"
echo "\$ bin/fm-pr-merge.sh task-x1 $COMBINED -- --merge"
run_pr_merge "$case_dir" task-x1 "$COMBINED" -- --merge > "$case_dir/a.out" 2> "$case_dir/a.err"
rc=$?
cat "$case_dir/a.out" "$case_dir/a.err"
echo "exit=$rc"
echo "gh pr merge calls so far: $(grep -c '^pr merge' "$case_dir/gh.log")"

echo
echo "== step B: register the combined PR on the integrator task (Land step 1)"
echo "\$ bin/fm-pr-check.sh task-x1 $COMBINED"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_LOG="$case_dir/gh.log" FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_VIEW_JSON="$case_dir/github-view.json" FM_TEST_GH_HEAD="$case_dir/github-head" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" FM_TEST_GH_RULES="$case_dir/github-rules" \
  HOME="$case_dir/user-home" PATH="$case_dir/fakebin:$PATH" \
  "$ROOT/bin/fm-pr-check.sh" task-x1 "$COMBINED"
echo "exit=$?"
echo "-- meta pr=/pr_head= after registration:"
grep -E '^pr(_head)?=' "$case_dir/state/task-x1.meta"

echo
echo "== step C: merge the combined PR with a merge commit (Land step 3)"
echo "\$ bin/fm-pr-merge.sh task-x1 $COMBINED -- --merge"
run_pr_merge "$case_dir" task-x1 "$COMBINED" -- --merge > "$case_dir/c.out" 2> "$case_dir/c.err"
rc=$?
cat "$case_dir/c.out" "$case_dir/c.err"
echo "exit=$rc"
echo "-- forge merge call(s) the script issued:"
grep '^pr merge' "$case_dir/gh.log"
rm -f "$HELPERS"
