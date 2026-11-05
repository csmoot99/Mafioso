#!/usr/bin/env bash
# Behavioral coverage for bin/fm-test-failure.sh and the capture step of
# bin/fm-heavy.sh: the reporter parsers against captured vitest, jest, Playwright,
# node:test and bats output, a run with no parsable failures, classify linking and
# refusals, report counts, and that keeping a job's output leaves the wrapper's
# streams, exit status and job record as they were.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-failure)
LEDGER="$ROOT/bin/fm-test-failure.sh"
FIXTURES="$ROOT/tests/fixtures/test-failure"

command -v jq >/dev/null 2>&1 || { echo "# skip: jq is not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "# skip: python3 is not installed"; exit 0; }

make_home() {  # <name>
  mkdir -p "$TMP_ROOT/$1/state" "$TMP_ROOT/$1/config" "$TMP_ROOT/$1/data"
  printf '%s\n' "$TMP_ROOT/$1"
}

# A systemd-run that runs the command with no scope.
make_unscoped_systemd_run() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/systemd-run" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in --user|--scope|-q) shift ;; -p) shift 2 ;; --unit=*) shift ;; *) break ;; esac; done
exec "$@"
SH
  chmod +x "$fakebin/systemd-run"
  printf '%s\n' "$fakebin"
}

capture() {  # <home> <log> <task> [project]
  ( cd "$TMP_ROOT" && FM_HOME="$1" "$LEDGER" capture --log "$2" --job job-1 --task "$3" \
      --project "${4:-demo}" --class test --command "npm test" )
}

# Prints each failure as file|test|error.
parsed() {  # <fixture>
  local home
  home=$(make_home "parse-$1")
  capture "$home" "$FIXTURES/$1.txt" t1 || fail "capture of $1 failed"
  jq -r '[.file // "-", .test, .error // "-"] | join("|")' "$home/data/test-failures/demo.jsonl"
}

assert_parsed() {  # <fixture> <expected lines>
  local got
  got=$(parsed "$1")
  [ "$got" = "$2" ] || fail "$1 parsed as:
$got
expected:
$2"
}

test_parsers() {
  assert_parsed vitest 'src/cart.test.ts|cart > totals the items|AssertionError: expected 3 to be 4 // Object.is equality
src/cart.test.ts|cart > applies tax|TypeError: cannot read tax of undefined'
  assert_parsed vitest-load-error 'src/broken.test.ts|Test suite failed to run|Error: Failed to resolve import "./gone" from "src/broken.test.ts".'
  assert_parsed vitest-marks-only 'src/cart.test.ts|cart > totals the items|→ expected 3 to be 4'
  assert_parsed jest 'src/math.test.js|math > divides|expect(received).toBe(expected) // Object.is equality'
  assert_parsed playwright 'tests/login.spec.ts|login > rejects a bad password|Error: expect(received).toBe(expected)'
  assert_parsed node-tap '/repo/test/a.test.js|inner fails|expected true
/repo/test/b.test.js|multi line|first line of the error'
  assert_parsed node-spec 'test/c.test.js|fails|AssertionError [ERR_ASSERTION]: expected true'
  assert_parsed node-spec-nested 'test/a.test.js|inner fails|AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:
test/a.test.js|deeper fails|Error: boom deep
test/a.test.js|child fails|Error: boom child
test/a.test.js|fails|Error: a fails
test/b.test.js|fails|Error: b fails'
  assert_parsed pnpm-workspace 'packages/api/src/cart.test.ts|cart > totals the items|AssertionError: expected 3 to be 4 // Object.is equality
packages/api/src/cart.test.ts|cart > applies tax|TypeError: cannot read tax of undefined
packages/web/src/math.test.js|math > divides|expect(received).toBe(expected) // Object.is equality'
  assert_parsed pnpm-interleaved 'apps/admin/lib/proxy.test.ts|proxy > strips headers|Error: admin-error
apps/storefront/lib/proxy.test.ts|proxy > strips headers|Error: storefront-error'
  assert_parsed bats 'tests/flags.bats|refuses a bad flag|`[ "$status" -eq 2 ]'"'"' failed'
  assert_parsed unparsed '-|(unparsed)|Error: could not start the database'
  pass "capture: names failing tests from each reporter, and a run with none parsable still leaves a line"
}

test_pnpm_log_cut_before_its_start_lines() {
  local home
  home=$(make_home pnpm-tail)
  grep -v ' test\$ ' "$FIXTURES/pnpm-workspace.txt" > "$TMP_ROOT/pnpm-tail.log"
  capture "$home" "$TMP_ROOT/pnpm-tail.log" t1 || fail "capture failed"
  [ "$(jq -r .test "$home/data/test-failures/demo.jsonl")" = "cart > totals the items
cart > applies tax
math > divides" ] || fail "a pnpm log without start lines parsed as: $(cat "$home/data/test-failures/demo.jsonl")"
  pass "capture: a pnpm log cut before its start lines still names its failures"
}

test_marks_of_two_files_stay_separate() {
  local home
  home=$(make_home marks-two-files)
  printf ' ❯ a.test.ts (1 test | 1 failed)\n   × same\n ❯ b.test.ts (1 test | 1 failed)\n   × same\n' > "$TMP_ROOT/two-files.log"
  capture "$home" "$TMP_ROOT/two-files.log" t1 || fail "capture failed"
  [ "$(jq -r .file "$home/data/test-failures/demo.jsonl")" = "a.test.ts
b.test.ts" ] || fail "same-named marks collapsed: $(cat "$home/data/test-failures/demo.jsonl")"
  pass "capture: same-named marks in two files stay two failures"
}

test_failure_line_fields() {
  local home repo row
  home=$(make_home fields)
  repo="$TMP_ROOT/fields-repo"
  git init -q -b work "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
  printf 'not ok 1 - fails\n  ---\n  location: %s/a.test.js:1:1\n  ...\n' "$(cd "$repo" && pwd -P)" > "$TMP_ROOT/fields.log"
  ( cd "$repo" && FM_HOME="$home" "$LEDGER" capture --log "$TMP_ROOT/fields.log" --job job-9 --task t9 \
      --project 'we/ird' --class e2e --command "npx playwright test" ) || fail "capture failed"
  row=$(cat "$home/data/test-failures/we_ird.jsonl")
  [ "$(jq -r .branch <<<"$row")" = work ] || fail "branch missing: $row"
  [ "$(jq -r .head <<<"$row")" = "$(git -C "$repo" rev-parse HEAD)" ] || fail "head missing: $row"
  [ "$(jq -r '[.project,.task,.class,.command,.job,.log,.file] | join("|")' <<<"$row")" \
    = "we_ird|t9|e2e|npx playwright test|job-9|$TMP_ROOT/fields.log|a.test.js" ] || fail "fields wrong: $row"
  jq -e '.ts | type == "number"' <<<"$row" >/dev/null || fail "ts missing: $row"
  pass "capture: a failure line carries its job, branch, head and a worktree-relative file"
}

test_classify() {
  local home ledger out rc
  home=$(make_home classify)
  ledger="$home/data/test-failures/demo.jsonl"
  capture "$home" "$FIXTURES/vitest.txt" t1
  printf '{"kind":"failure","ts":1,"project":"demo","task":"t1","test":"cart > applies tax","file":"old.ts","job":"job-0"}\n' >> "$ledger"
  capture "$home" "$FIXTURES/vitest.txt" other

  FM_HOME="$home" "$LEDGER" classify t1 --test "applies tax" --class stale --cause $'renamed\n  field' \
    || fail "classify failed"
  [ "$(tail -1 "$ledger" | jq -r '[.kind,.task,.test,.file,.class,.cause,.job] | join("|")')" \
    = "classification|t1|cart > applies tax|src/cart.test.ts|stale|renamed field|job-1" ] \
    || fail "classification did not link the most recent failure: $(tail -1 "$ledger")"

  FM_HOME="$home" "$LEDGER" classify t1 --test "cart > applies tax" --file old.ts --class flaky --cause "timing" \
    || fail "classify --file failed"
  [ "$(tail -1 "$ledger" | jq -r '[.file,.job] | join("|")')" = "old.ts|job-0" ] || fail "--file did not narrow the match"

  rc=0
  out=$(FM_HOME="$home" "$LEDGER" classify t1 --test x --class wrong --cause c 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "a bad class exited $rc: $out"
  [ "$(grep -c '"wrong"' "$ledger")" = 0 ] || fail "a bad class was written"

  out=$(FM_HOME="$home" "$LEDGER" classify t1 --test "seen only in a pipeline round" --class new-code --cause c 2>&1) \
    || fail "an unrecorded test was refused"
  assert_contains "$out" "unlinked" "an unlinked classification must say so"
  [ "$(tail -1 "$ledger" | jq -r .job)" = null ] || fail "an unmatched classification was linked"

  rc=0
  FM_HOME="$home" "$LEDGER" classify ghost --test x --class flaky --cause c >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "a task with no ledger exited $rc"

  printf 'project=/somewhere/projects/fresh/\n' > "$home/state/fresh-task.meta"
  FM_HOME="$home" "$LEDGER" classify fresh-task --test x --class flaky --cause c 2>/dev/null \
    || fail "a task with only a task record was refused"
  [ -s "$home/data/test-failures/fresh.jsonl" ] || fail "the task record did not choose the ledger"
  pass "classify: links the latest matching failure, refuses a bad class, keeps unrecorded tests unlinked"
}

test_classify_file_in_a_pnpm_package() {
  local home ledger out
  home=$(make_home classify-package)
  ledger="$home/data/test-failures/demo.jsonl"
  capture "$home" "$FIXTURES/pnpm-interleaved.txt" t1
  out=$(FM_HOME="$home" "$LEDGER" classify t1 --test "proxy > strips headers" \
    --file apps/admin/lib/proxy.test.ts --class stale --cause c 2>&1) || fail "classify failed: $out"
  [ "$(tail -1 "$ledger" | jq -r '[.file,.job] | join("|")')" = "apps/admin/lib/proxy.test.ts|job-1" ] \
    || fail "--file did not link the package's failure: $(tail -1 "$ledger")"
  out=$(FM_HOME="$home" "$LEDGER" report) || fail "report failed"
  assert_contains "$out" "unclassified: 1 of 2 (50%)" "a classification must cover only its own package's failure"
  pass "classify: --file with the repo path links the failure of that pnpm package"
}

test_classify_repo_path_of_a_package_relative_row() {
  local home ledger out
  home=$(make_home classify-relative)
  ledger="$home/data/test-failures/demo.jsonl"
  capture "$home" "$FIXTURES/vitest.txt" t1

  out=$(FM_HOME="$home" "$LEDGER" classify t1 --test "applies tax" --file packages/api/xsrc/cart.test.ts \
    --class stale --cause c 2>&1) || fail "classify failed: $out"
  assert_contains "$out" "unlinked" "a path that differs inside a component must not link"
  out=$(FM_HOME="$home" "$LEDGER" classify t1 --test "applies tax" --file art.test.ts \
    --class stale --cause c 2>&1) || fail "classify failed: $out"
  assert_contains "$out" "unlinked" "part of a file name must not link"

  out=$(FM_HOME="$home" "$LEDGER" classify t1 --test "applies tax" --file packages/api/src/cart.test.ts \
    --class stale --cause c 2>&1) || fail "classify failed: $out"
  [ "$(tail -1 "$ledger" | jq -r '[.file,.job] | join("|")')" = "src/cart.test.ts|job-1" ] \
    || fail "a repo path did not link the package-relative row: $(tail -1 "$ledger")"
  out=$(FM_HOME="$home" "$LEDGER" report) || fail "report failed"
  assert_contains "$out" "unclassified: 1 of 2 (50%)" "the linked failure must count as classified"
  pass "classify: a repo --file links a package-relative row at a path boundary only"
}

test_report_covers_both_path_shapes() {
  local home ledger out
  home=$(make_home report-shapes)
  ledger="$home/data/test-failures/demo.jsonl"
  grep -v '^apps/storefront' "$FIXTURES/pnpm-interleaved.txt" > "$TMP_ROOT/recursive.log"
  printf ' FAIL  lib/proxy.test.ts > proxy > strips headers\nError: filtered\n' > "$TMP_ROOT/filtered.log"
  capture "$home" "$TMP_ROOT/recursive.log" t1
  capture "$home" "$TMP_ROOT/filtered.log" t1
  [ "$(jq -r .file "$ledger")" = "apps/admin/lib/proxy.test.ts
lib/proxy.test.ts" ] || fail "the two runs stored: $(cat "$ledger")"
  out=$(FM_HOME="$home" "$LEDGER" classify t1 --test "proxy > strips headers" \
    --file apps/admin/lib/proxy.test.ts --class stale --cause c 2>&1) || fail "classify failed: $out"
  out=$(FM_HOME="$home" "$LEDGER" report) || fail "report failed"
  assert_contains "$out" "unclassified: 0 of 2 (0%)" "one classification must cover both shapes of a path"

  home=$(make_home report-no-file)
  capture "$home" "$FIXTURES/unparsed.txt" t1
  out=$(FM_HOME="$home" "$LEDGER" classify t1 --test "(unparsed)" --class flaky --cause c 2>&1) \
    || fail "classify failed: $out"
  out=$(FM_HOME="$home" "$LEDGER" report) || fail "report failed"
  assert_contains "$out" "unclassified: 0 of 1 (0%)" "a classification must cover a failure with no file"
  pass "report: one classification covers both path shapes of a failure, and a failure with no file"
}

test_classify_title_as_printed() {
  local home ledger out
  home=$(make_home classify-title)
  ledger="$home/data/test-failures/demo.jsonl"
  capture "$home" "$FIXTURES/playwright.txt" t1
  out=$(FM_HOME="$home" "$LEDGER" classify t1 --test 'login › rejects a bad password' --class stale --cause c 2>&1) \
    || fail "classify failed: $out"
  [ "$(tail -1 "$ledger" | jq -r '[.test,.job] | join("|")')" = "login > rejects a bad password|job-1" ] \
    || fail "a title with › did not link: $(tail -1 "$ledger")"
  out=$(FM_HOME="$home" "$LEDGER" report) || fail "report failed"
  assert_contains "$out" "unclassified: 0 of 1 (0%)" "a title with › must classify its failure"

  FM_HOME="$home" "$LEDGER" classify t1 --test 'checkout › never recorded' --class flaky --cause c 2>/dev/null \
    || fail "an unrecorded title was refused"
  [ "$(tail -1 "$ledger" | jq -r .test)" = "checkout > never recorded" ] || fail "an unlinked title kept its separator"
  pass "classify: a title copied from reporter output links like the stored name"
}

test_report_and_recent() {
  local home out now
  home=$(make_home report)
  now=$(date +%s)
  mkdir -p "$home/data/test-failures"
  {
    printf '{"kind":"failure","ts":%s,"project":"a","task":"t1","test":"one","file":"f1","job":"j1"}\n' "$((now - 100))"
    printf '{"kind":"failure","ts":%s,"project":"a","task":"t1","test":"one","file":"f1","job":"j2"}\n' "$((now - 90))"
    printf '{"kind":"classification","ts":%s,"project":"a","task":"t1","test":"one","file":"f1","class":"regression","cause":"c","job":"j2"}\n' "$((now - 80))"
    printf '{"kind":"failure","ts":%s,"project":"a","task":"t1","test":"one","file":"f1","error":"late","job":"j3"}\n' "$((now - 70))"
    printf '{"kind":"failure","ts":%s,"project":"a","task":"t0","test":"ancient","file":"f9","job":"j0"}\n' "$((now - 864000))"
    printf 'torn line\n'
  } > "$home/data/test-failures/a.jsonl"
  printf '{"kind":"failure","ts":%s,"project":"b","task":"t2","test":"two","file":null,"job":"j4"}\n' "$((now - 60))" \
    > "$home/data/test-failures/b.jsonl"

  out=$(FM_HOME="$home" "$LEDGER" report --since 7d) || fail "report failed"
  assert_contains "$out" "failures: 4" "the window must drop older failures"
  assert_contains "$out" "unclassified: 2 of 4 (50%)" "a classification covers earlier failures of the test only"
  assert_contains "$out" "  3  a" "per-project count wrong"
  assert_contains "$out" "  1  regression" "per-class count wrong"
  assert_contains "$out" "  3  f1 > one" "repeated-test count wrong"
  assert_contains "$out" "  3  f1" "file count wrong"
  case "$out" in *ancient*) fail "--since kept an old failure" ;; esac

  out=$(FM_HOME="$home" "$LEDGER" report --project b) || fail "report --project failed"
  assert_contains "$out" "failures: 1" "--project must filter"
  out=$(FM_HOME="$home" "$LEDGER" report --since soon 2>&1) && fail "a bad --since was accepted"
  out=$(FM_HOME="$(make_home empty)" "$LEDGER" report) || fail "an empty report failed"
  assert_contains "$out" "no test failures recorded" "an empty report must say so"

  out=$(FM_HOME="$home" "$LEDGER" recent --limit 2) || fail "recent failed"
  [ "$(wc -l <<<"$out")" = 2 ] || fail "recent --limit printed: $out"
  assert_contains "$(head -1 <<<"$out")" "late" "recent must end at the newest line"
  assert_contains "$(tail -1 <<<"$out")" "two" "recent must end at the newest line"
  pass "report and recent: counts, window, project filter, unclassified share"
}

test_heavy_capture() {
  local home lock fakebin out err rc job log
  for tool in flock systemd-run; do
    command -v "$tool" >/dev/null 2>&1 || { echo "# skip: $tool is not installed"; return 0; }
  done
  home=$(make_home heavy)
  lock="$TMP_ROOT/heavy.lock"
  fakebin=$(make_unscoped_systemd_run "$TMP_ROOT/heavy-bin")
  run_heavy() { PATH="$fakebin:$PATH" FM_HOME="$home" FM_HEAVY_LOCK="$lock" "$ROOT/bin/fm-heavy.sh" "$@"; }

  rc=0
  run_heavy --class test --task t1 --project demo -- bash -c \
    "cat '$FIXTURES/jest.txt'; echo on-stderr >&2; exit 7" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || rc=$?
  [ "$rc" = 7 ] || fail "the exit status changed to $rc"
  out=$(cat "$TMP_ROOT/out"); err=$(cat "$TMP_ROOT/err")
  assert_contains "$out" "math › divides" "stdout must still pass through"
  [ "$err" = on-stderr ] || fail "stderr must stay separate, got: $err"
  case "$out" in *on-stderr*) fail "stderr leaked into stdout" ;; esac

  job=$(jq -r .job "$home/data/test-failures/demo.jsonl")
  log=$(jq -r .log "$home/data/test-failures/demo.jsonl")
  [ "$log" = "$home/state/heavy-logs/$job.log" ] || fail "the failure line points at $log"
  assert_grep "on-stderr" "$log" "the job log must hold both streams"
  assert_grep "math › divides" "$log" "the job log must hold both streams"
  [ "$(jq -r '[.task,.class,.test,.file] | join("|")' "$home/data/test-failures/demo.jsonl")" \
    = "t1|test|math > divides|src/math.test.js" ] || fail "the wrapper recorded the wrong failure"
  [ "$(jq -r '.exit' "$home/state/heavy-jobs.jsonl")" = 7 ] || fail "the job record changed"

  run_heavy --class test --project passing -- true || fail "a passing job failed"
  [ ! -e "$home/data/test-failures/passing.jsonl" ] || fail "a passing job wrote the ledger"

  rc=0
  run_heavy --class build --project built -- bash -c 'echo not-kept; exit 3' >/dev/null || rc=$?
  [ "$rc" = 3 ] || fail "a build's exit status changed to $rc"
  [ ! -e "$home/data/test-failures/built.jsonl" ] || fail "a build wrote the ledger"
  [ -z "$(grep -rl not-kept "$home/state/heavy-logs")" ] || fail "a build's output was kept"

  rc=0
  run_heavy --class test --project unnamed-exit -- sh -c 'exit 5' || rc=$?
  [ "$rc" = 5 ] || fail "a silent failure exited $rc"
  [ "$(jq -r .test "$home/data/test-failures/unnamed-exit.jsonl")" = "(unparsed)" ] || fail "a silent failure left no line"

  rc=0
  mkdir -p "$TMP_ROOT/drive"
  printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/drive/no-mistakes"
  chmod +x "$TMP_ROOT/drive/no-mistakes"
  PATH="$TMP_ROOT/drive:$PATH" run_heavy --class test --project drive -- no-mistakes axi run || rc=$?
  [ "$rc" = 1 ] || fail "a drive call exited $rc"
  [ ! -e "$home/data/test-failures/drive.jsonl" ] || fail "a drive call wrote the ledger"

  run_heavy --class test --project big -- bash -c \
    'head -c 3000000 /dev/zero | tr "\0" "a" | fold -w 100; echo; echo last-line' >/dev/null || fail "the long job failed"
  log=$(ls -t "$home"/state/heavy-logs/*.log | head -1)
  [ "$(wc -c < "$log")" -lt 2100000 ] || fail "the job log is not capped"
  [ "$(head -1 "$log")" = "[fm-heavy: earlier output dropped]" ] || fail "the marker is missing: $(head -c 80 "$log")"
  [ "$(tail -1 "$log")" = last-line ] || fail "the newest output was dropped"

  pass "fm-heavy: keeps test output and records failures without changing streams, status or the job record"
}

test_lingering_process_frees_the_slot() {
  local home lock fakebin start elapsed
  command -v flock >/dev/null 2>&1 || return 0
  home=$(make_home lingering)
  lock="$TMP_ROOT/linger.lock"
  fakebin=$(make_unscoped_systemd_run "$TMP_ROOT/linger-bin")
  start=$(date +%s)
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HEAVY_LOCK="$lock" "$ROOT/bin/fm-heavy.sh" --class test --project p -- \
    bash -c 'sleep 8 & exit 4' > "$TMP_ROOT/linger.out" 2>&1
  [ "$?" = 4 ] || fail "the exit status changed"
  elapsed=$(($(date +%s) - start))
  [ "$elapsed" -lt 6 ] || fail "a process holding the output kept the wrapper for ${elapsed}s"
  flock -n "$lock" true || fail "a process holding the output kept the slot"
  [ "$(jq -r .test "$home/data/test-failures/p.jsonl")" = "(unparsed)" ] || fail "the job left no ledger line"

  start=$(date +%s)
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_HEAVY_LOCK="$lock" "$ROOT/bin/fm-heavy.sh" --class test --project detached -- \
    bash -c 'sleep 8 >/dev/null 2>&1 & printf "not ok 1 - named\n"; exit 4' >/dev/null 2>&1
  [ "$(($(date +%s) - start))" -lt 2 ] || fail "a process with its own output delayed the wrapper"
  [ "$(jq -r .test "$home/data/test-failures/detached.jsonl")" = named ] || fail "a detached process cost the job its parsing"
  pass "fm-heavy: a process that outlives the command cannot hold the wrapper or the slot"
}

test_brief_rule() {
  local home brief
  home=$(make_home brief)
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" rule-ship some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/rule-ship/brief.md"
  assert_grep "bin/fm-test-failure.sh' classify rule-ship --test <name>" "$brief" "the ship brief must carry the classify rule"
  assert_grep "pipeline fix rounds" "$brief" "the ship brief must cover pipeline fix rounds"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" rule-scout some-proj --scout >/dev/null 2>&1
  assert_no_grep "fm-test-failure.sh" "$home/data/rule-scout/brief.md" "a scout fixes no tests"
  pass "fm-brief: ship briefs tell the fixer to classify"
}

test_parsers
test_pnpm_log_cut_before_its_start_lines
test_marks_of_two_files_stay_separate
test_failure_line_fields
test_classify
test_classify_file_in_a_pnpm_package
test_classify_repo_path_of_a_package_relative_row
test_report_covers_both_path_shapes
test_classify_title_as_printed
test_report_and_recent
test_heavy_capture
test_lingering_process_frees_the_slot
test_brief_rule
