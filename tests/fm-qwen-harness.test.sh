#!/usr/bin/env bash
# Behavior tests for the Qwen Code harness adapter.
#
# The facts pinned here are the ones a Qwen Code release could silently change
# and the ones a wrong guess would make dangerous:
#   1. QWEN_CODE_CLI is qwen's own child/tool-process marker, whose VALUE is
#      the CLI entry script's absolute path (verified live on qwen 0.25.1), and
#      it outranks an inherited CLAUDECODE, because qwen does NOT clear one
#      (a tool process under a claude launcher carried both).
#   2. A bare `1`, an unrelated path, and the launcher's inherited AI_AGENT
#      are NOT a qwen identity and must never claim it.
#   3. The installed CLI is a node bundle whose live process reports comm as
#      MainThread on modern Node/Linux, so ancestry does NOT reach it and the
#      marker is the only detection path. The comm-name arm is pinned for a
#      future natively-named binary.
#   4. qwen is a crewmate/scout adapter only: it has no primary supervision
#      protocol, so its control mechanics are verified while a secondmate
#      launch on it is refused.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-qwen-lib.sh
. "$ROOT/bin/fm-qwen-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-qwen-harness)
QWEN_MARKER='/home/u/.local/lib/node_modules/@qwen-code/qwen-code/cli-entry.js'
SCRUB=(-u GEMINI_CLI -u QWEN_CODE_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u GROK_AGENT)

test_qwen_marker_outranks_inherited_claudecode() {
  local out fakebin base_path
  base_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  fakebin=$(fm_fakebin "$TMP_ROOT/marker-ordering")
  fm_fake_blind_ancestry "$fakebin"
  # This is the exact hazard: qwen does not clear an inherited CLAUDECODE, so
  # a qwen worker under a claude primary carries both markers at once.
  out=$(PATH="$fakebin:$base_path" CLAUDECODE=1 QWEN_CODE_CLI="$QWEN_MARKER" "$HARNESS")
  [ "$out" = qwen ] || fail "CLAUDECODE + QWEN_CODE_CLI must detect qwen, got '$out'"
  # Drive the two signals apart so the case above cannot go quietly vacuous:
  # each marker alone must still produce its own verdict.
  out=$(env -u CLAUDECODE PATH="$fakebin:$base_path" QWEN_CODE_CLI="$QWEN_MARKER" "$HARNESS")
  [ "$out" = qwen ] || fail "QWEN_CODE_CLI alone must detect qwen, got '$out'"
  out=$(env -u QWEN_CODE_CLI PATH="$fakebin:$base_path" CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude, got '$out'"
  # Cursor's and gemini's markers still outrank qwen's, preserving the documented order.
  out=$(PATH="$fakebin:$base_path" CURSOR_AGENT=1 QWEN_CODE_CLI="$QWEN_MARKER" "$HARNESS")
  [ "$out" = cursor ] || fail "CURSOR_AGENT must still outrank QWEN_CODE_CLI, got '$out'"
  out=$(PATH="$fakebin:$base_path" GEMINI_CLI=1 QWEN_CODE_CLI="$QWEN_MARKER" "$HARNESS")
  [ "$out" = gemini ] || fail "GEMINI_CLI must still outrank QWEN_CODE_CLI, got '$out'"
  pass "fm-harness.sh: qwen's marker outranks an inherited CLAUDECODE"
}

test_qwen_marker_value_must_be_the_cli_entry_path() {
  local out fakebin base_path
  base_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  # Positives need a blinded ancestry: under a real claude session a structural
  # claude ancestor rightly outranks any marker, which is not the fact under test.
  fakebin=$(fm_fakebin "$TMP_ROOT/marker-value")
  fm_fake_blind_ancestry "$fakebin"
  # The marker is a path, not a flag: a bare `1` is not the verified value and
  # must not claim the identity, nor may an unrelated path or a relative one.
  for bad in 1 true qwen cli-entry.js /usr/bin/node '/home/u/qwen-notes/cli-entry.js'; do
    out=$(env "${SCRUB[@]}" QWEN_CODE_CLI="$bad" "$HARNESS")
    [ "$out" != qwen ] || fail "QWEN_CODE_CLI='$bad' must not claim the qwen identity"
  done
  # A natively-named entry path and the published package tree both count.
  for good in /usr/local/bin/qwen "$QWEN_MARKER"; do
    out=$(env "${SCRUB[@]}" PATH="$fakebin:$base_path" QWEN_CODE_CLI="$good" "$HARNESS")
    [ "$out" = qwen ] || fail "QWEN_CODE_CLI='$good' must detect qwen, got '$out'"
  done
  # AI_AGENT carried the launcher's value inside a qwen tool process, so it
  # proves nothing about which harness is running.
  out=$(env "${SCRUB[@]}" AI_AGENT=qwen-code_0-25-1_agent "$HARNESS")
  [ "$out" != qwen ] || fail "AI_AGENT must never claim the qwen identity, got '$out'"
  # Per-session qwen variables are paths, not identities.
  out=$(env "${SCRUB[@]}" QWEN_CODE_SESSION_ID=abc QWEN_CODE_PROJECT_DIR=/home/u/.qwen/projects/x "$HARNESS")
  [ "$out" != qwen ] || fail "session variables must never claim the qwen identity, got '$out'"
  pass "fm-harness.sh: only the CLI entry path value of QWEN_CODE_CLI identifies qwen"
}

test_qwen_ancestry_matches_only_a_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH2'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/qwen'; exit 0 ;;
  *"args="*) printf '%s\n' 'qwen -y'; exit 0 ;;
esac
exit 1
SH2
  chmod +x "$fakebin/ps"
  out=$(env "${SCRUB[@]}" PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = qwen ] \
    || fail "a natively-named qwen command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named qwen command"
}

test_qwen_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH2'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH2
  chmod +x "$fakebin/ps"
  out=$(env "${SCRUB[@]}" FAKE_PS_COMM=qwen-helper FAKE_PS_ARGS='qwen-helper --serve' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != qwen ] || fail "an unrelated qwen-helper command must not detect qwen, got '$out'"
  # A model name is the most likely later mention: a pi or opencode worker
  # running qwen3-coder through a provider must never read as the qwen harness.
  out=$(env "${SCRUB[@]}" FAKE_PS_COMM=node FAKE_PS_ARGS='node server.js --model qwen3-coder:30b' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != qwen ] || fail "a later node argument naming a qwen model must not detect qwen, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated qwen mentions"
}

test_qwen_node_bundle_is_marker_detected() {
  command -v node >/dev/null 2>&1 || return 0
  local dir="$TMP_ROOT/ancestry" out comm
  mkdir -p "$dir"
  comm=$(node -e 'const{execSync}=require("child_process");process.stdout.write(execSync("ps -o comm= -p "+process.pid).toString().trim())' 2>/dev/null)
  [ -n "$comm" ] || return 0
  cat > "$dir/qwen" <<'JS'
const { spawnSync } = require('child_process');
const env = { ...process.env };
for (const k of ['GEMINI_CLI', 'QWEN_CODE_CLI', 'CLAUDECODE', 'CURSOR_AGENT', 'CURSOR_INVOKED_AS',
                 'PI_CODING_AGENT', 'GROK_AGENT']) delete env[k];
const r = spawnSync(process.env.FM_HARNESS_BIN, { env, encoding: 'utf8' });
process.stdout.write(r.stdout || '');
JS
  out=$(FM_HARNESS_BIN="$HARNESS" node "$dir/qwen" 2>/dev/null | tr -d '\n')
  case "$(basename -- "$comm")" in node*)
    # A platform whose comm basename matches production's `node*` interpreter
    # arm reaches that arm, and there the qwen script path must win.
    [ "$out" = qwen ] \
      || fail "where node reports comm=$comm, a qwen script path must detect qwen, got '$out'"
    pass "fm-harness.sh: this platform's node reports comm=$comm and ancestry reaches qwen"
    return 0
    ;;
  esac
  # The measured case (comm=MainThread): ancestry cannot see the bundle, so
  # nobody may later document ancestry as covering qwen or "fix" it by
  # matching MainThread.
  [ "$out" != qwen ] \
    || fail "node reports comm=$comm here, so ancestry must not be claiming qwen; got '$out'"
  # And the marker closes exactly that gap on the same process shape; the
  # ancestry is blinded so a claude primary running this suite cannot outrank
  # the marker structurally (node passes PATH down to fm-harness.sh's ps).
  local fakebin node_bin
  node_bin=$(command -v node)
  fakebin=$(fm_fakebin "$TMP_ROOT/bundle-marker")
  fm_fake_blind_ancestry "$fakebin"
  out=$(PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
    FM_HARNESS_BIN="$HARNESS" QWEN_CODE_CLI="$QWEN_MARKER" "$node_bin" -e '
const { spawnSync } = require("child_process");
const r = spawnSync(process.env.FM_HARNESS_BIN, { encoding: "utf8" });
process.stdout.write(r.stdout || "");' 2>/dev/null | tr -d '\n')
  [ "$out" = qwen ] || fail "QWEN_CODE_CLI must identify a node-bundle qwen worker, got '$out'"
  pass "fm-harness.sh: the node bundle is marker-detected, never ancestry-detected"
}

test_qwen_process_identity_reads_the_script_argument() {
  # The live shape measured on qwen 0.25.1 / Node v24.21.0: comm is MainThread
  # and argv[0] is the interpreter, so only argv[1] identifies it.
  fm_qwen_args_are_qwen 'node /home/u/.local/bin/qwen -y -i brief' \
    || fail "the installed launcher shape must be recognized as qwen"
  fm_qwen_args_are_qwen '/home/u/.local/node/bin/node --max-old-space-size=10000 /home/u/.local/bin/qwen -y' \
    || fail "node option flags before the script must be skipped"
  fm_qwen_args_are_qwen "node $QWEN_MARKER" \
    || fail "the published package tree must be recognized as qwen"
  fm_qwen_args_are_qwen 'qwen -y' || fail "a natively-named qwen command must be recognized"

  # Divergence: the negatives are what keep the positives from being vacuous.
  ! fm_qwen_args_are_qwen '/home/u/.local/node/bin/node' \
    || fail "a bare node process must not be claimed as qwen"
  ! fm_qwen_args_are_qwen 'node /home/u/app/server.js' \
    || fail "an unrelated node script must not be claimed as qwen"
  ! fm_qwen_args_are_qwen 'node /home/u/app/server.js --model qwen3-coder:30b' \
    || fail "a later flag value naming a qwen model must not claim the identity"
  ! fm_qwen_args_are_qwen 'node /home/u/.local/bin/gemini -m qwen' \
    || fail "a gemini launch naming a qwen model must not claim the qwen identity"
  ! fm_qwen_args_are_qwen 'node /home/u/qwen/other.js' \
    || fail "a qwen directory component alone must not claim the identity"
  pass "fm-qwen-lib.sh: identity comes from the script argument, never a bare interpreter"
}

test_qwen_process_identity_preserves_whitespace_in_script_path() {
  command -v node >/dev/null 2>&1 || return 0
  [ -r /proc/self/cmdline ] || return 0
  local dir="$TMP_ROOT/path with spaces" node_bin pid attempts=0
  mkdir -p "$dir"
  node_bin=$(command -v node)
  ln -s "$node_bin" "$dir/node"
  printf 'setTimeout(() => {}, 30000);\n' > "$dir/qwen"
  "$dir/node" "$dir/qwen" &
  pid=$!
  while ! fm_qwen_pid_is_qwen "$pid"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 100 ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "qwen interpreter and script paths containing spaces must retain process identity"
    fi
    sleep 0.01
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-qwen-lib.sh: process argv preserves whitespace in interpreter and qwen script paths"
}

test_qwen_control_mechanics_are_the_verified_ones() {
  local out
  fm_control_harness_supported qwen || fail "qwen must be a supported control harness"
  out=$(fm_control_harness_family qwen-0.25.1)
  [ "$out" = qwen ] || fail "a recorded qwen* harness must resolve to qwen, got '$out'"
  out=$(fm_control_interrupt_key qwen)
  [ "$out" = Escape ] || fail "qwen interrupts on Escape, got '$out'"
  out=$(fm_control_interrupt_repeat qwen)
  [ "$out" = 1 ] || fail "qwen interrupts on a single press, got '$out'"
  out=$(fm_control_interrupt_clear_key qwen)
  [ "$out" = C-u ] || fail "qwen restores the cancelled prompt and clears it with C-u, got '$out'"
  out=$(fm_control_exit_command qwen)
  [ "$out" = /quit ] || fail "qwen exits with /quit, got '$out'"
  pass "fm-control-lib.sh: qwen carries its verified interrupt and exit mechanics"
}

test_qwen_is_crewmate_and_scout_only() {
  fm_control_harness_supports_kind qwen ship || fail "qwen must be verified for ship work"
  fm_control_harness_supports_kind qwen scout || fail "qwen must be verified for scout work"
  ! fm_control_harness_supports_kind qwen secondmate \
    || fail "qwen has no primary supervision protocol and must be refused for secondmates"
  pass "fm-control-lib.sh: qwen is a crewmate/scout adapter only"
}

test_qwen_busy_signature_is_harness_scoped() {
  # The delivery-only rendered footer: qwen's running turn pins
  # `(<n>s · esc to cancel)` to its status row (verified live, 0.25.1).
  printf '.  Thinking... (4s · esc to cancel)\n' | fm_busy_lines_match qwen \
    || fail "harness=qwen must match its own esc-to-cancel status row"
  printf 'YOLO mode (shift + tab to cycle)\n' | fm_busy_lines_match qwen \
    && fail "qwen's idle footer must not read busy" || true
  printf 'esc to cancel\n' | fm_busy_lines_match grok \
    && fail "harness=grok must never borrow qwen's esc token" || true
  printf 'Ctrl+c:cancel\n' | fm_busy_lines_match qwen \
    && fail "harness=qwen must never borrow grok's token" || true
  pass "fm-composer-lib.sh: qwen's delivery signature never crosses harnesses"
}

test_qwen_wiring_stays_outside_the_worktree() {
  local out
  out=$(fm_control_harness_wiring_paths qwen /wt /state task-1)
  [ "$out" = "/state/task-1.qwen-settings.json" ] \
    || fail "qwen's per-task wiring is its firstmate-owned settings file, got '$out'"
  case "$out" in
    /wt/*) fail "qwen must never claim a path inside the worktree: '$out'" ;;
  esac
  pass "fm-control-lib.sh: qwen's wiring stays outside the project worktree"
}

test_qwen_marker_outranks_inherited_claudecode
test_qwen_marker_value_must_be_the_cli_entry_path
test_qwen_ancestry_matches_only_a_native_command_name
test_qwen_ancestry_rejects_unrelated_mentions
test_qwen_node_bundle_is_marker_detected
test_qwen_process_identity_reads_the_script_argument
test_qwen_process_identity_preserves_whitespace_in_script_path
test_qwen_control_mechanics_are_the_verified_ones
test_qwen_is_crewmate_and_scout_only
test_qwen_busy_signature_is_harness_scoped
test_qwen_wiring_stays_outside_the_worktree
