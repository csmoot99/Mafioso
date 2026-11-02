#!/usr/bin/env bash
# Behavior of the targeted pull-request checks: bin/fm-ci-select.sh and the
# fm-test-run.sh --changed --strict / --only-from options it drives.
#
# A pull request may run less than the full suite only when its change maps
# precisely onto tests (or, for lint, onto nothing lint reads); every other
# event and every change that cannot be mapped must select the complete set.
# Each case runs the real selector in a throwaway clone of this repository with
# the current bin/fm-ci-select.sh and bin/fm-test-run.sh overlaid, so the map is
# the real one and nothing about the live checkout is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECT=bin/fm-ci-select.sh
RUNNER=bin/fm-test-run.sh
TMP=$(fm_test_tmproot ci-select)
REPO=$TMP/repo

git clone -q --no-hardlinks "$ROOT" "$REPO" || fail "could not clone the repository"
cp "$ROOT/bin/fm-ci-select.sh" "$ROOT/bin/fm-test-run.sh" "$REPO/bin/"
git -C "$REPO" config user.name tester
git -C "$REPO" config user.email tester@example.invalid
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base || fail "could not commit the base"
BASE=$(git -C "$REPO" rev-parse HEAD)

# Reset the clone to the base commit, then apply one change as the pull request.
change() {  # <path> [content]  (appends a line, or writes the content)
  git -C "$REPO" reset -q --hard "$BASE"
  mkdir -p "$(dirname "$REPO/$1")"
  if [ "$#" -gt 1 ]; then
    printf '%s\n' "$2" >"$REPO/$1"
  else
    printf '# changed\n' >>"$REPO/$1"
  fi
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m change
}

# select <event> <kind> [selector args...]: print the selector's stdout.
select_for() {
  local event=$1
  shift
  (cd "$REPO" && GITHUB_EVENT_NAME=$event FM_CI_BASE_SHA=$BASE FM_CI_SELECT_LIST=$TMP/list \
    bash "$SELECT" "$@" 2>/dev/null)
}

assert_complete() {  # <selector output> <message>
  assert_contains "$1" "run=true" "$2: the job must run"
  printf '%s\n' "$1" | grep -qx 'list=' || fail "$2: the complete set must carry no restriction: $1"
}

# Print the lane (or family) names a selected script belongs to.
lanes_holding() {  # <script>
  local lane
  for lane in portable-parallel-1 portable-parallel-2 $(seq -f 'portable-serial-%gof10' 1 10); do
    (cd "$REPO" && bash "$RUNNER" --list --lane "$lane") | grep -qx "$1" && printf '%s\n' "$lane"
  done
  (cd "$REPO" && bash "$RUNNER" --list --family real-herdr-gated) | grep -qx "$1" && printf 'family\n'
  return 0
}

test_only_pull_requests_may_run_less() {
  local event out
  change tests/fm-pr-merge.test.sh
  for event in push schedule workflow_dispatch; do
    out=$(select_for "$event" tests --lane portable-parallel-1)
    assert_complete "$out" "$event"
    out=$(select_for "$event" lint)
    assert_complete "$out" "$event lint"
  done
  out=$(cd "$REPO" && GITHUB_EVENT_NAME=pull_request bash "$SELECT" tests --lane portable-parallel-1 2>/dev/null)
  assert_complete "$out" "a pull request without a base commit"
  pass "push, schedule, dispatch, and a base-less pull request select the complete set"
}

test_a_changed_test_runs_only_in_its_own_job() {
  local lane holders running=0 out
  change tests/fm-pr-merge.test.sh
  holders=$(lanes_holding tests/fm-pr-merge.test.sh)
  [ "$(printf '%s\n' "$holders" | wc -l | tr -d ' ')" = 1 ] \
    || fail "fm-pr-merge.test.sh must belong to exactly one job, got: $holders"
  for lane in portable-parallel-1 portable-parallel-2 portable-serial-1of10 portable-serial-7of10; do
    out=$(select_for pull_request tests --lane "$lane")
    case "$out" in
      *run=true*) running=$((running + 1)); [ "$lane" = "$holders" ] || fail "unexpected job selected: $lane" ;;
      *run=false*) [ "$lane" != "$holders" ] || fail "the job holding the changed test was skipped: $lane" ;;
      *) fail "selector printed no run decision for $lane: $out" ;;
    esac
  done
  out=$(select_for pull_request tests --family real-herdr-gated)
  assert_contains "$out" "run=false" "the Herdr job has no selected script"
  grep -qx tests/fm-pr-merge.test.sh "$TMP/list" || fail "the selection list must name the changed test"
  pass "a pull request that changes one test runs it in its own job and skips the others"
}

test_unmappable_changes_select_the_complete_set() {
  local path out
  for path in README.md .github/workflows/ci.yml bin/fm-ci-select.sh bin/fm-test-run.sh tests/lib.sh; do
    change "$path"
    out=$(select_for pull_request tests --lane portable-serial-1of10)
    assert_complete "$out" "$path"
  done
  change bin/fm-ci-select.sh
  pass "an unmapped path, the workflow, the selector, the runner, and the shared test library select the complete set"
}

test_a_base_missing_from_the_checkout_selects_the_complete_set() {
  local out
  change tests/fm-pr-merge.test.sh
  out=$(cd "$REPO" && GITHUB_EVENT_NAME=pull_request FM_CI_BASE_SHA=0123456789012345678901234567890123456789 \
    bash "$SELECT" tests --lane portable-parallel-1 2>/dev/null)
  assert_complete "$out" "an unknown base"
  pass "an unknown base commit selects the complete set"
}

test_lint_skips_only_text_inputs_nothing_reads() {
  local path out
  for path in README.md docs/new-notes.md data.json assets/logo.txt; do
    case $path in
      assets/*) change "$path" x ;;
      *.json) change "$path" '{}' ;;
      *) change "$path" ;;
    esac
    out=$(select_for pull_request lint)
    assert_contains "$out" "run=false" "$path changes no lint input"
  done
  for path in bin/fm-pr-merge.sh tests/fm-pr-merge.test.sh .github/workflows/ci.yml notes.txt bin/fm-extension.mjs; do
    change "$path"
    out=$(select_for pull_request lint)
    assert_complete "$out" "$path is or may be a lint input"
  done
  # A deleted shell root is still a lint input.
  git -C "$REPO" reset -q --hard "$BASE"
  git -C "$REPO" rm -q bin/fm-pr-merge.sh
  git -C "$REPO" commit -q -m delete
  out=$(select_for pull_request lint)
  assert_complete "$out" "a deleted shell root"
  # A Markdown file a root names in a shellcheck source= directive is an input.
  git -C "$REPO" reset -q --hard "$BASE"
  printf '# shellcheck source=docs/sourced-by-root.md\n' >"$REPO/tests/sourcing-root.sh"
  printf 'x\n' >"$REPO/docs/sourced-by-root.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m sourcing
  BASE=$(git -C "$REPO" rev-parse HEAD)
  change docs/sourced-by-root.md
  out=$(select_for pull_request lint)
  assert_complete "$out" "a file a root sources"
  pass "lint skips only Markdown, JSON, license, and asset changes that no lint input reads"
}

test_runner_strict_and_only_from_contracts() {
  local out rc
  change README.md
  (cd "$REPO" && bash "$RUNNER" --list --changed --strict --base "$BASE") >"$TMP/o" 2>"$TMP/e" && rc=0 || rc=$?
  expect_code 3 "$rc" "an unmapped change must exit 3 under --strict"
  assert_contains "$(cat "$TMP/e")" "full set required" "--strict must explain why the full set is required"

  change tests/fm-pr-merge.test.sh
  out=$(cd "$REPO" && bash "$RUNNER" --list --changed --strict --base "$BASE")
  [ "$out" = tests/fm-pr-merge.test.sh ] || fail "a changed test must select exactly itself, got: $out"

  (cd "$REPO" && bash "$RUNNER" --list --all --strict) >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "--strict without --changed must be refused"

  printf 'tests/fm-pr-merge.test.sh\n' >"$TMP/only"
  out=$(cd "$REPO" && bash "$RUNNER" --list --family pr-forge --only-from "$TMP/only")
  [ "$out" = tests/fm-pr-merge.test.sh ] || fail "--only-from must keep just the listed script, got: $out"
  out=$(cd "$REPO" && bash "$RUNNER" --list --family pr-forge --only-from "")
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -gt 1 ] || fail "an empty --only-from path must keep the whole selection"
  : >"$TMP/none"
  out=$(cd "$REPO" && bash "$RUNNER" --list --family pr-forge --only-from "$TMP/none")
  [ -z "$out" ] || fail "an empty --only-from file must select nothing, got: $out"
  pass "--strict exits 3 for unmapped changes and --only-from narrows a selection"
}

test_only_pull_requests_may_run_less
test_a_changed_test_runs_only_in_its_own_job
test_unmappable_changes_select_the_complete_set
test_a_base_missing_from_the_checkout_selects_the_complete_set
test_lint_skips_only_text_inputs_nothing_reads
test_runner_strict_and_only_from_contracts
