#!/usr/bin/env bash
# fm-ci-select.sh - decide how much of the CI suite one job must run.
#
# A pull request runs only the lint and the test scripts its change touches;
# every other event (push to main, schedule, manual dispatch) and every change
# this script cannot map runs the complete set. A failure anywhere in here also
# means the complete set, so a broken selector can only cost minutes, never skip
# a check.
#
# Usage:
#   fm-ci-select.sh tests [<fm-test-run.sh selection args>]
#       e.g. fm-ci-select.sh tests --lane portable-serial-3of10
#       Prints run=true|false (does the selection leave this job any script?)
#       and list=<file>, a script list to pass to fm-test-run.sh --only-from,
#       or an empty list= when the job must run its whole lane.
#   fm-ci-select.sh lint
#       Prints run=true|false: false only when every changed path is a text file
#       no lint input reads (see lint_inert below).
#
# Both print GitHub step-output lines, so a job appends stdout to $GITHUB_OUTPUT.
# Diagnostics go to stderr.
#
# Environment:
#   GITHUB_EVENT_NAME   anything but pull_request selects the complete set.
#   FM_CI_BASE_SHA      the pull request's base commit; absent selects the
#                       complete set.
#   FM_CI_SELECT_LIST   where tests writes its list (default
#                       ${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-ci-select.list).
#
# The path-to-test map, its conservative rules, and the paths that always force
# the complete set belong to bin/fm-test-run.sh (--changed --strict). The lint
# input rule below belongs here because it must stay beside the CI wiring that
# consumes it; bin/fm-lint.sh owns what lint actually reads.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

full() {  # <reason>
  printf 'fm-ci-select: complete set: %s\n' "$*" >&2
  printf 'run=true\nlist=\n'
  exit 0
}

# A pull request with a known base is the only event that may run less.
[ "${GITHUB_EVENT_NAME:-}" = pull_request ] || full "event is ${GITHUB_EVENT_NAME:-unknown}, not a pull request"
BASE=${FM_CI_BASE_SHA:-}
[ -n "$BASE" ] || full "no pull request base commit"
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || full "base commit $BASE is not in this checkout"

# True when no lint input reads this path: Markdown, JSON-family data, the
# license, and static assets are neither shell roots, sourced files, nor
# workflows. Everything else, including every path this list does not name, is
# a lint input. A path a root names in a shellcheck source= directive stays one.
lint_inert() {  # <path>
  case "$1" in
    *.md|*.json|*.jsonl|*.toon|LICENSE|assets/*) ;;
    *) return 1 ;;
  esac
  ! git grep -qF "source=$1" -- 'bin/*.sh' 'tests/*.sh' 2>/dev/null
}

select_lint() {
  local path changed=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    changed=1
    lint_inert "$path" || full "lint input changed: $path"
  done < <(git diff --name-only --no-renames "$BASE...HEAD")
  [ "$changed" -eq 1 ] || full "no changed paths against $BASE"
  printf 'fm-ci-select: lint skipped: only text files changed\n' >&2
  printf 'run=false\nlist=\n'
}

select_tests() {
  local list rc=0 members
  list=${FM_CI_SELECT_LIST:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-ci-select.list}
  bin/fm-test-run.sh --list --changed --strict --base "$BASE" >"$list" || rc=$?
  [ "$rc" -eq 0 ] || full "no precise test selection (fm-test-run status $rc)"
  members=$(bin/fm-test-run.sh --list "$@" --only-from "$list") || full "could not list the lane"
  if [ -z "$members" ]; then
    printf 'fm-ci-select: no selected script belongs to this job\n' >&2
    printf 'run=false\nlist=%s\n' "$list"
  else
    printf 'fm-ci-select: %s of this job'"'"'s scripts selected\n' "$(printf '%s\n' "$members" | wc -l | tr -d ' ')" >&2
    printf 'run=true\nlist=%s\n' "$list"
  fi
}

case "${1:-}" in
  lint) shift; select_lint ;;
  tests) shift; select_tests "$@" ;;
  *) printf 'usage: fm-ci-select.sh lint | tests [<fm-test-run.sh selection args>]\n' >&2; exit 2 ;;
esac
