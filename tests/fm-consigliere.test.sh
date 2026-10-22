#!/usr/bin/env bash
# Consigliere readiness for the current head and opt-in configuration behavior.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-consigliere-lib.sh
. "$ROOT/bin/fm-consigliere-lib.sh"

TASK_HOME=$(fm_test_tmproot fm-consigliere)
mkdir -p "$TASK_HOME/config" "$TASK_HOME/data/task"
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
PR_URL=https://github.com/owner/repo/pull/1
RECEIPT="$TASK_HOME/data/task/consigliere.json"
printf 'review evidence\n' > "$TASK_HOME/report.md"
printf 'gate evidence\n' > "$TASK_HOME/gates.md"

require_review() {
  fm_consigliere_require_review "$TASK_HOME" task "$PR_URL" "$HEAD_SHA"
}
write_receipt() {
  jq -n --arg pr "$PR_URL" --arg head "$HEAD_SHA" --arg root "$TASK_HOME" '
    {pr: $pr, head: $head, round: 1, verdict: "clear", blocker: 0, major: 0,
     minor: 2, builder_family: "anthropic", reviewer_family: "openai",
     report: ($root + "/report.md"), gates: ($root + "/gates.md")}' > "$RECEIPT"
}
reject_receipt() {
  local filter=$1
  write_receipt
  jq "$filter" "$RECEIPT" > "$RECEIPT.tmp"
  mv "$RECEIPT.tmp" "$RECEIPT"
  if require_review 2> "$TASK_HOME/error"; then
    fail "accepted invalid receipt: $filter"
  fi
}

assert_equals off "$(fm_consigliere_mode "$TASK_HOME")" "missing config defaults off"
require_review || fail "default off required a receipt"
printf 'off\n' > "$TASK_HOME/config/consigliere"
require_review || fail "explicit off required a receipt"
for invalid in '' yes ON 'on off'; do
  printf '%s\n' "$invalid" > "$TASK_HOME/config/consigliere"
  if require_review 2> "$TASK_HOME/error"; then fail "accepted invalid switch '$invalid'"; fi
done
printf 'on\noff\n' > "$TASK_HOME/config/consigliere"
if require_review 2> "$TASK_HOME/error"; then fail "accepted multiline switch"; fi
rm "$TASK_HOME/config/consigliere"
ln -s "$TASK_HOME/missing" "$TASK_HOME/config/consigliere"
if require_review 2> "$TASK_HOME/error"; then fail "dangling config disabled review"; fi
rm "$TASK_HOME/config/consigliere"
printf 'on\n' > "$TASK_HOME/config/consigliere"
if require_review 2> "$TASK_HOME/error"; then fail "missing review cleared readiness"; fi
printf '{broken' > "$RECEIPT"
if require_review 2> "$TASK_HOME/error"; then fail "malformed review cleared readiness"; fi
pass "review is opt-in and malformed configuration or absent evidence refuses readiness"

write_receipt
cat "$RECEIPT" "$RECEIPT" > "$RECEIPT.tmp"
mv "$RECEIPT.tmp" "$RECEIPT"
if require_review 2> "$TASK_HOME/error"; then fail "multiple receipts cleared readiness"; fi
write_receipt
require_review || fail "cross-family clear review with minor notes was rejected"
for filter in '.head = "old"' '.pr += "0"' '.verdict = "pending"' \
  '.blocker = 1' '.major = 1' '.minor = -1' '.minor = 0.5' '.minor = "0"' \
  '.round = 3' '.round = 0' '.reviewer_family = ""' '.reviewer_family = .builder_family' \
  '.report = "relative.md"' '.gates = "/missing"' '.report += "\nextra"'; do
  reject_receipt "$filter"
done
write_receipt
: > "$TASK_HOME/gates.md"
if require_review 2> "$TASK_HOME/error"; then fail "empty gate evidence cleared review"; fi
printf 'gates\n' > "$TASK_HOME/gates.md"
pass "receipt must be clear for this PR head, with evidence and valid severity counts"

for exception in opus-independent fable-independent; do
  write_receipt
  jq --arg exception "$exception" '.round = 2 | .reviewer_family = .builder_family |
    .exception = $exception | .reason = "documented independent-brief route"' \
    "$RECEIPT" > "$RECEIPT.tmp"
  mv "$RECEIPT.tmp" "$RECEIPT"
  require_review || fail "documented exception was rejected"
done
reject_receipt '.reviewer_family = .builder_family | .exception = "opus-independent"'
reject_receipt '.reviewer_family = .builder_family | .exception = "unknown" | .reason = "reason"'
pass "only named independent-brief exceptions with grounds permit same-family review"

mkdir -p "$TASK_HOME/overrides/config" "$TASK_HOME/overrides/data/task"
printf 'on\n' > "$TASK_HOME/overrides/config/consigliere"
printf 'off\n' > "$TASK_HOME/config/consigliere"
write_receipt
mv "$RECEIPT" "$TASK_HOME/overrides/data/task/consigliere.json"
FM_CONFIG_OVERRIDE="$TASK_HOME/overrides/config" FM_DATA_OVERRIDE="$TASK_HOME/overrides/data" \
  require_review || fail "explicit config/data roots were not used"
if FM_CONFIG_OVERRIDE="$TASK_HOME/overrides/config" require_review 2> "$TASK_HOME/error"; then
  fail "enabled override used a missing default receipt"
fi
pass "configuration and evidence honor the home overrides"
