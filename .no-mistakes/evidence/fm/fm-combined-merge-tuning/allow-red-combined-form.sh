#!/usr/bin/env bash
# Runs bin/fm-pr-merge.sh with the combined-merge skill's exact Land step 3 form,
# `<task> <combined-url> --allow-red <check> -- --merge`, against the repo's own
# stubbed-gh fixture from tests/fm-pr-merge.test.sh.
T=tests/fm-pr-merge.test.sh
. <(sed '/^test_verified_merge_records_pr_and_head$/,$d' "$T" | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#tests#")
set +e
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case_dir=$(make_case combined-allow-red); mkdir -p "$case_dir/wt"
add_gh_mocks "$case_dir" "$head"; write_github_red_json "$case_dir" "$head" "Behavior portable serial 2"
echo "--- without waiver:"
run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/90 -- --merge; echo "exit $?"
case_dir=$(make_case combined-allow-red-2); mkdir -p "$case_dir/wt"
add_gh_mocks "$case_dir" "$head"; write_github_red_json "$case_dir" "$head" "Behavior portable serial 2"
echo "--- with skill form --allow-red 'Behavior portable serial 2' -- --merge:"
run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/91 --allow-red "Behavior portable serial 2" -- --merge; echo "exit $?"
echo "gh merge call logged:"; grep '^pr merge ' "$case_dir/gh.log"
assert_logged_gh_merge "$case_dir" 91 example/repo --merge && echo "ASSERT OK: merged with --merge at the verified head"
