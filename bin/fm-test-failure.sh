#!/usr/bin/env bash
# fm-test-failure.sh - the per-project ledger of failing tests.
#
# usage:
#   fm-test-failure.sh classify <task-id> --test <name> [--file <path>] --class <class> --cause "<one line>"
#   fm-test-failure.sh report [--project <p>] [--since <days>d]
#   fm-test-failure.sh recent [--project <p>] [--limit n]
#
# Ledger: data/test-failures/<project>.jsonl in the root Firstmate home, one JSON
# object per line, shared by every local home like the heavy-job log.
# bin/fm-heavy.sh appends a failure line for each failing test of a class test or
# e2e job that exits non-zero; a job with no parsable failures gets one line with
# test "(unparsed)". A job without --project lands in unknown.jsonl.
#
# Failure line: kind "failure", ts (epoch seconds), project, task, class (test or
# e2e), command, branch and head of the working tree, job (the heavy job id), file
# (null when the output names none), test (suite and title joined with " > "),
# error (the first error line, trimmed) and log (the job's kept output in
# state/heavy-logs/).
#
# classify records why a test failed: class is one of regression, stale, brittle,
# new-code, preventable or flaky, and any other value is refused. --test matches a
# failure's whole name or its last " > " parts, and --file narrows by path or path
# suffix. The line is kind "classification" with ts, project, task, test, file,
# class, cause and job, and links the most recent matching failure of that task
# through job, test and file. A test the ledger never saw, such as one fixed in a
# pipeline round, is still counted: its line has job null and its project comes
# from another failure of the task or from state/<task-id>.meta in FM_HOME or the
# root home. With neither the command refuses, because no ledger can be chosen.
#
# report prints failures per project, classifications per class, the ten
# most-repeated tests, the ten most-implicated files and the share of failures
# unclassified. A classification covers its linked failure and that test's earlier
# failures in the same task, so a later failure of the test counts as unclassified.
# --since keeps the last n days. recent prints the latest lines, newest last.
#
# capture is the internal entry bin/fm-heavy.sh calls with a finished job's log.
#
# Exit status: 0 on success, 1 when classify cannot choose a ledger, 2 on a usage
# error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  ''|-h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
esac
# shellcheck source=bin/fm-wake-lib.sh
root=$(. "$SCRIPT_DIR/fm-wake-lib.sh" && fm_firstmate_root_home) || {
  echo "fm-test-failure.sh: cannot resolve the root Firstmate home" >&2; exit 2; }
exec python3 "$SCRIPT_DIR/fm-test-failure.py" "$root" "$@"
