#!/usr/bin/env bash
# tests/fm-spawn-launch-env.test.sh - every agent this fleet launches must start
# with the NAME=value assignments listed in config/launch-env, and a file that
# could break the launch contract must refuse before anything mutates.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane actually received, under a synthetic pane environment, with
# the harness binary replaced by a probe that prints the environment it was
# started with. Values are synthetic and non-secret; one of them carries spaces,
# single and double quotes, and a literal `$` so byte-for-byte delivery is what
# gets asserted, not a trimmed or expanded approximation.
#
# The remote second-mate route reads the same file from the inherited copy on
# its own host, so its coverage is the inheritance case below plus the delivery
# path tests/fm-spawn-compact-adviser-disable-remote.test.sh already drives.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-env)

# The synthetic assignments under test. LAUNCHENV_TEST_PCT models the
# real-world compaction threshold; the pane carries a CONTRARY value for it so
# a launch that merely forwarded the ambient environment is caught.
PCT_VALUE=40
CONTRARY=99
QUOTED_VALUE="it's a \"quoted\"  value with \$HOME and  two  spaces "
LAUNCH_ENV_FILE="# synthetic non-secret values
LAUNCHENV_TEST_PCT=$PCT_VALUE

LAUNCHENV_TEST_QUOTED=$QUOTED_VALUE
LAUNCHENV_TEST_EMPTY="
# The probe ends with a sentinel line so the empty value survives command
# substitution's trailing-newline strip as its own empty line.
EXPECTED="$PCT_VALUE
$QUOTED_VALUE

END"

write_launch_env() {  # <home>
  printf '%s\n' "$LAUNCH_ENV_FILE" > "$1/config/launch-env"
}

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# Replace the harness binary with a probe that reports the three assignments
# under test, one per line, so executing the emitted launch answers "what would
# the agent have seen". An unset name prints `unset`, which is how an empty
# value stays distinguishable from a dropped one.
install_env_probe() {  # <dir> <name>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s\n' "${LAUNCHENV_TEST_PCT-unset}" "${LAUNCHENV_TEST_QUOTED-unset}" "${LAUNCHENV_TEST_EMPTY-unset}" END
SH
  chmod +x "$1/$2"
}

# Run the emitted launch command in a synthetic pane shell carrying the
# CONTRARY value, with the pane's own pre-launch exports replayed first when
# <shape> is preamble and skipped when it is bare.
#   emitted_launch_env <fakebin> <launch-log> <pane-log> <preamble|bare>
emitted_launch_env() {
  local fakebin=$1 launchlog=$2 panelog=$3 shape=$4 launch preamble=''
  launch=$(cat "$launchlog")
  [ "$shape" = bare ] || preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane LAUNCHENV_TEST_PCT="$CONTRARY" \
    /bin/sh -c "$preamble
$launch"
}

assert_pane_exports() {  # <pane-log> <label>
  local panelog=$1 label=$2 gotmp pct
  [ "$(grep -c '^export LAUNCHENV_TEST_PCT=' "$panelog")" = 1 ] \
    || fail "$label: the pane shell should receive exactly one export per assignment"
  gotmp=$(grep -n '^export GOTMPDIR=' "$panelog" | tail -1 | cut -d: -f1)
  pct=$(grep -n '^export LAUNCHENV_TEST_PCT=' "$panelog" | tail -1 | cut -d: -f1)
  [ -n "$gotmp" ] && [ -n "$pct" ] || fail "$label: the pane log is missing the pre-launch exports"
  [ "$pct" -gt "$gotmp" ] \
    || fail "$label: the launch-env export must ride the GOTMPDIR pre-launch site (gotmp=$gotmp pct=$pct)"
}

assert_probe_saw_values() {  # <seen> <label>
  [ "$1" = "$EXPECTED" ] \
    || fail "$2: the agent did not receive the configured values byte for byte; expected [$EXPECTED] got [$1]"
}

test_ship_allowlist_absent() {
  local rec out status seen
  rec=$(make_case ship-open codex ship-open-a1)
  read_case "$rec"
  write_launch_env "$HOME_DIR"
  out=$(run_case_spawn ship-open-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn without an allowlist should succeed: $out"
  assert_pane_exports "$PANE_LOG" "ship, allowlist absent"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" preamble) \
    || fail "ship, allowlist absent: the emitted launch failed to run"
  assert_probe_saw_values "$seen" "ship, allowlist absent, with pane exports"
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" bare) \
    || fail "ship, allowlist absent: the launch command failed to run on its own"
  assert_probe_saw_values "$seen" "ship, allowlist absent, launch command alone"
  pass "ship launch with no allowlist starts its agent with the configured values, from the pane export and the launch command alike"
}

test_ship_allowlist_enabled() {
  local rec out status seen launch
  rec=$(make_case ship-filtered codex ship-filtered-a1)
  read_case "$rec"
  write_launch_env "$HOME_DIR"
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_case_spawn ship-filtered-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn under an allowlist should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '/usr/bin/env -i' \
    "an enabled allowlist should launch under a cleared environment"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" preamble) \
    || fail "ship, allowlist enabled: the emitted launch failed to run"
  assert_probe_saw_values "$seen" "ship, allowlist enabled, with pane exports"
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" bare) \
    || fail "ship, allowlist enabled: the launch command failed to run on its own"
  assert_probe_saw_values "$seen" "ship, allowlist enabled, launch command alone"
  pass "ship launch under an enabled allowlist carries the configured values through the cleared environment, overriding a contrary pane value"
}

test_absent_file_adds_nothing() {
  local rec out status seen
  rec=$(make_case ship-unset codex ship-unset-a1)
  read_case "$rec"
  out=$(run_case_spawn ship-unset-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn without config/launch-env should succeed: $out"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" preamble) \
    || fail "absent file: the emitted launch failed to run"
  assert_equals "$CONTRARY
unset
unset
END" "$seen" "with no config/launch-env the launch must leave the ambient environment alone"
  pass "an absent config/launch-env changes nothing about the launch"
}

test_secondmate_inherits_and_launches_with_values() {
  local rec sm out status seen
  rec=$(make_case secondmate codex sm-values)
  read_case "$rec"
  write_launch_env "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf 'sm-values\n' > "$sm/.fm-secondmate-home"
  printf 'charter for sm-values\n' > "$sm/data/charter.md"
  out=$(run_case_spawn sm-values "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed: $out"
  cmp -s "$HOME_DIR/config/launch-env" "$sm/config/launch-env" \
    || fail "the secondmate home did not inherit config/launch-env from the primary"
  assert_pane_exports "$PANE_LOG" "secondmate"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" preamble) \
    || fail "secondmate: the emitted launch failed to run"
  assert_probe_saw_values "$seen" "secondmate"
  pass "a secondmate inherits config/launch-env and its own launch starts with the values"
}

test_raw_compound_launch_command_carries_values() {
  local rec out status seen launch probe_dir
  rec=$(make_case raw-compound claude raw-compound-a1)
  read_case "$rec"
  write_launch_env "$HOME_DIR"
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$HOME_DIR/config/crew-dispatch.json"
  probe_dir="$CASE_DIR/agent-cwd"
  mkdir -p "$probe_dir"
  install_env_probe "$probe_dir" probe
  out=$(run_case_spawn raw-compound-a1 "$PROJ_DIR" --mode no-mistakes --yolo off \
    "cd $probe_dir && ./probe")
  status=$?
  expect_code 0 "$status" "raw compound launch spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  [ -n "$launch" ] || fail "raw compound launch spawn sent no launch command"
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" bare) \
    || fail "raw compound launch: the emitted launch failed to run"
  assert_probe_saw_values "$seen" "raw compound launch"
  pass "a compound raw launch command still starts its agent with the configured values"
}

# --- refusals ---------------------------------------------------------------
#
# Every refusal must happen before the spawn creates anything: no task record,
# no launch text in the pane, and a message naming the file and the reason.
assert_refused_clean() {  # <status> <out> <needle> <label>
  local status=$1 out=$2 needle=$3 label=$4
  [ "$status" -ne 0 ] || fail "$label: the spawn should have refused: $out"
  assert_contains "$out" 'config/launch-env' "$label: the refusal must identify the config file"
  assert_contains "$out" "$needle" "$label: the refusal must say why"
  [ ! -s "$LAUNCH_LOG" ] || fail "$label: the pane received a launch command despite the refusal"
  [ ! -s "$PANE_LOG" ] || fail "$label: the pane received pre-launch text despite the refusal"
  [ ! -e "$HOME_DIR/state/$5.meta" ] || fail "$label: a task record was created despite the refusal"
}

test_malformed_line_refuses() {
  local rec out status
  rec=$(make_case malformed codex malformed-a1)
  read_case "$rec"
  printf 'LAUNCHENV_TEST_PCT=40\nnot an assignment\n' > "$HOME_DIR/config/launch-env"
  out=$(run_case_spawn malformed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  assert_refused_clean "$status" "$out" 'line 2' 'malformed line' malformed-a1
  printf '1BAD=value\n' > "$HOME_DIR/config/launch-env"
  out=$(run_case_spawn malformed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  assert_refused_clean "$status" "$out" 'NAME=value' 'invalid name' malformed-a1
  printf 'LAUNCHENV_TEST_PCT=40\nLAUNCHENV_TEST_PCT=50\n' > "$HOME_DIR/config/launch-env"
  out=$(run_case_spawn malformed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  assert_refused_clean "$status" "$out" 'twice' 'duplicate name' malformed-a1
  rm "$HOME_DIR/config/launch-env"
  mkdir "$HOME_DIR/config/launch-env"
  out=$(run_case_spawn malformed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  assert_refused_clean "$status" "$out" 'readable regular file' 'non-regular file' malformed-a1
  pass "a malformed line, an invalid or repeated name, or a non-regular file refuses the launch before anything mutates"
}

test_reserved_name_refuses() {
  local rec out status name
  rec=$(make_case reserved codex reserved-a1)
  read_case "$rec"
  # One from each reserved class: the FM_ prefix, a pane and floor assignment,
  # and a harness marker the launch templates clear.
  for name in FM_TASK_ID FM_HOME COMPACT_ADVISER_DISABLE TRACEPARENT GOTMPDIR CLAUDECODE; do
    printf 'LAUNCHENV_TEST_PCT=40\n%s=anything\n' "$name" > "$HOME_DIR/config/launch-env"
    out=$(run_case_spawn reserved-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    assert_refused_clean "$status" "$out" "may not set $name" "reserved $name" reserved-a1
  done
  pass "a reserved name refuses the launch and names the offending assignment"
}

# --- relaunch ---------------------------------------------------------------
#
# bin/fm-control.sh relaunch stops the agent and rebuilds the launch through
# bin/fm-spawn.sh --relaunch, so this drives the operator-facing verb rather
# than the rebuild alone, with the same pane-lifecycle stub the compact-adviser
# suite uses.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'codex' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

test_relaunch_rebuilds_the_values() {
  local setting dir home proj wt id out status seen launch preamble
  for setting in absent enabled; do
    id="relaunch-$setting-a1"
    dir="$TMP_ROOT/relaunch-$setting"
    home="$dir/home"
    proj="$dir/proj"
    wt="$dir/wt"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake"
    touch "$home/state/.last-watcher-beat"
    write_launch_env "$home"
    [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
    make_relaunch_stub "$dir"
    fm_git_worktree "$proj" "$wt" "wt-relaunch-$setting"
    fm_test_spawn_brief "$home" "$id"
    : > "$dir/fake/literal"
    : > "$dir/fake/keys"
    printf 'codex' > "$dir/fake/command"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$wt" > "$dir/fake/cwd"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$wt"
      echo "project=$proj"
      echo "harness=codex"
      echo "kind=ship"
      echo "mode=no-mistakes"
      echo "yolo=off"
      echo "tasktmp=$dir/tasktmp"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"

    mkdir -p "$dir/user-home"
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
    status=$?
    expect_code 0 "$status" "relaunch with allowlist=$setting should succeed: $out"
    grep -q '^export LAUNCHENV_TEST_PCT=' "$dir/fake/keys" \
      || fail "relaunch with allowlist=$setting did not re-export the configured values into the pane"
    launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
    [ -n "$launch" ] || fail "relaunch with allowlist=$setting sent no replacement launch command"
    install_env_probe "$dir/fakebin" codex
    preamble=$(grep '^export ' "$dir/fake/keys")
    seen=$(env -i HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" TERM=xterm \
      TMUX=synthetic-pane LAUNCHENV_TEST_PCT="$CONTRARY" \
      /bin/sh -c "$preamble
$launch") \
      || fail "relaunch with allowlist=$setting: the replacement launch failed to run"
    assert_probe_saw_values "$seen" "relaunch, allowlist $setting"
  done
  pass "relaunch rebuilds the configured values for the replacement agent in both allowlist postures"
}

test_ship_allowlist_absent
test_ship_allowlist_enabled
test_absent_file_adds_nothing
test_secondmate_inherits_and_launches_with_values
test_raw_compound_launch_command_carries_values
test_malformed_line_refuses
test_reserved_name_refuses
test_relaunch_rebuilds_the_values
