#!/usr/bin/env bash
# Live guard for the codex crewmate launch's hook posture.
#
# The verdict here comes from the installed codex, not from a stub: a stub can
# only confirm the assumption already written into it, and what this guard
# protects is exactly a vendor-owned surface. A crewmate runs codex's hook
# layer the way a claude worker runs its hooks: --enable hooks plus
# --dangerously-bypass-hook-trust, so the machine's ~/.codex/hooks.json and a
# project's .codex/hooks.json run without the unanswerable "Hooks need review"
# modal, and Firstmate's own busy-state, turn-end, and context-handoff hooks
# ride the launch as `-c hooks.<Event>=...` session flags (bin/fm-spawn.sh's
# launch template owns the flags).
#
# The guard replays the REAL launch flags fm-spawn builds - captured from a
# spawn driven through a fake pane - against the installed codex. It asks
# codex whether hooks ended up enabled, and asks codex's app-server which hooks
# it loaded: every Firstmate hook must come back as a session-flag hook with
# exactly the command the launch carries. A release that renames the feature,
# the bypass flag, or the session-flag hook shape fails here naming the harness
# and version, instead of codex silently ignoring an unknown key and a worker
# losing its turn-end signal.
#
# The same captured flags carry the crewmate's safety posture: codex's
# workspace-write sandbox with network off, its automatic approval reviewer
# instead of a pane prompt, writable roots limited to the task's steering inbox
# and data directory, and the task-worker trust statement. The guard replays the
# flags through `codex debug prompt-input`, which renders exactly what the model
# would be told, and fails naming the version if any of that stops rendering -
# for example a release that renames a config key, which would otherwise be
# ignored as an unknown key and quietly restore pane prompts.
#
# It spends no model tokens (`codex features list`, the app-server's
# `hooks/list`, and `codex debug prompt-input` resolve configuration only), so
# it runs by default wherever codex is installed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CODEX_HOOK_LAYER_LIVE codex

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a codex crewmate
# against a fake pane and echoes the literal launch command firstmate sent. The
# home opts into the context handoff at 40 percent, so the launch carries every
# hook Firstmate can wire.
capture_codex_launch() {
  local name=$1
  shift
  local case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-hook-layer-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  printf 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40\n' > "$home/config/launch-env"
  : > "$home/config/worker-context-handoff"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" >/dev/null 2>&1 ||
    fail "codex $CODEX_VERSION: fm-spawn could not build a crewmate launch"
  cat "$launchlog"
}

# codex_global_flags <launch command>: the flags between the codex executable
# and the positional brief, which is everything codex itself is configured by.
codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  flags=${flags%%\"\$(*}
  printf '%s' "$flags"
}

test_installed_codex_enables_hooks_for_the_captured_crewmate_launch() {
  local launch flags state
  launch=$(capture_codex_launch ship --mode no-mistakes --yolo off)
  flags=$(codex_global_flags "$launch")

  # Every flag firstmate will launch with, handed to the real codex, must be
  # accepted and leave the hook layer on. `features list` reports the effective
  # state after those flags are applied and contacts no model.
  state=$(eval "codex $flags features list" 2>&1) ||
    fail "codex $CODEX_VERSION rejected firstmate's crewmate launch flags: $state"
  printf '%s\n' "$state" | awk '$1 == "hooks" { print $NF }' | grep -qx true ||
    fail "codex $CODEX_VERSION left hooks disabled for firstmate's crewmate launch flags, so the worker has no busy state or turn-end signal"

  printf 'ok - codex %s accepts a firstmate crewmate launch with its hook layer enabled\n' "$CODEX_VERSION"
}

# codex_session_flag_hooks <case-dir>: the hooks/list result codex's app-server
# reports for the captured launch's `-c hooks.*` session flags, from the case's
# worktree.
codex_session_flag_hooks() {
  local case_dir=$1 wt line prev a hookargs=()
  wt="$case_dir/wt"
  fm_test_codex_launch_argv "$case_dir/launch.log" "$case_dir/argv" ||
    fail "codex $CODEX_VERSION: the captured launch did not run against an argument recorder"
  prev=
  while IFS= read -r -d '' a; do
    if [ "$prev" = -c ]; then
      case "$a" in hooks.*) hookargs+=(-c "$a") ;; esac
    fi
    prev=$a
  done < "$case_dir/argv/args"
  [ "${#hookargs[@]}" -gt 0 ] || fail "codex $CODEX_VERSION: the captured launch carries no session-flag hooks"
  coproc CODEX_AS { cd "$wt" && exec timeout 60 codex app-server --listen stdio:// -c features.hooks=true "${hookargs[@]}" 2>/dev/null; }
  printf '%s\n' \
    '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"fm-codex-hook-layer-live","version":"0"}}}' \
    '{"method":"initialized"}' \
    "{\"id\":2,\"method\":\"hooks/list\",\"params\":{\"cwds\":[\"$wt\"]}}" >&"${CODEX_AS[1]}"
  while IFS= read -r -t 30 line <&"${CODEX_AS[0]}"; do
    case "$line" in *'"id":2'*) break ;; esac
    line=
  done
  kill "$CODEX_AS_PID" 2>/dev/null
  wait "$CODEX_AS_PID" 2>/dev/null
  [ -n "${line:-}" ] || fail "codex $CODEX_VERSION app-server did not answer hooks/list"
  printf '%s' "$line"
}

test_installed_codex_loads_every_firstmate_hook_from_the_captured_launch() {
  local case_dir listing event name want got
  capture_codex_launch hooks --mode no-mistakes --yolo off >/dev/null
  case_dir="$TMP_ROOT/hooks"
  listing=$(codex_session_flag_hooks "$case_dir")
  for event in UserPromptSubmit:userPromptSubmit Stop:stop SessionEnd:sessionEnd PreCompact:preCompact PostToolUse:postToolUse; do
    name=${event#*:}
    event=${event%%:*}
    want=$(fm_test_codex_hook_command "$case_dir/launch.log" "$event" "$case_dir/parse") ||
      fail "codex $CODEX_VERSION: the captured launch carries no $event hook"
    got=$(printf '%s' "$listing" | jq -r --arg e "$name" \
      '[.result.data[]?.hooks[]? | select(.source == "sessionFlags" and .eventName == $e and .enabled == true)] | if length == 1 then .[0].command else empty end')
    [ -n "$got" ] ||
      fail "codex $CODEX_VERSION did not load exactly one enabled session-flag $event hook from firstmate's crewmate launch"
    [ "$got" = "$want" ] ||
      fail "codex $CODEX_VERSION parsed firstmate's $event hook as '$got', not the command the launch carries: '$want'"
  done

  printf 'ok - codex %s loads every firstmate session-flag hook from the crewmate launch with its exact command\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature() {
  local listing
  listing=$(codex features list 2>&1) ||
    fail "codex $CODEX_VERSION could not list its feature flags: $listing"
  printf '%s\n' "$listing" | awk '{ print $1 }' | grep -qx hooks ||
    fail "codex $CODEX_VERSION no longer publishes a hook feature flag; firstmate's crewmate launch needs a new control"

  printf 'ok - codex %s still publishes the hook feature flag firstmate enables\n' "$CODEX_VERSION"
}

test_installed_codex_renders_the_captured_crewmate_safety_posture() {
  local launch flags case_dir inbox data rendered expect
  launch=$(capture_codex_launch safety --mode no-mistakes --yolo off)
  flags=$(codex_global_flags "$launch")
  case_dir="$TMP_ROOT/safety"
  inbox="$(cd "$case_dir/home/state" && pwd -P)/codex-hook-layer-safety.inbox"
  data="$(cd "$case_dir/home/data" && pwd -P)/codex-hook-layer-safety"

  rendered=$(cd "$case_dir/wt" && eval "codex $flags debug prompt-input fm-probe" 2>&1) ||
    fail "codex $CODEX_VERSION could not render a prompt for firstmate's crewmate launch flags: $rendered"
  # The backticks are literal text in codex's rendered permissions block.
  # shellcheck disable=SC2016
  for expect in \
    '`sandbox_mode` is `workspace-write`' \
    'Network access is restricted.' \
    '`approvals_reviewer` is `auto_review`' \
    "\`$inbox\`" \
    "\`$data\`" \
    'You are a task worker launched by Firstmate'; do
    case "$rendered" in
    *"$expect"*) ;;
    *) fail "codex $CODEX_VERSION does not show firstmate's crewmate launch the expected safety posture: missing $expect" ;;
    esac
  done

  printf 'ok - codex %s renders the crewmate launch sandboxed under auto-review with only its task channels writable\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature
test_installed_codex_enables_hooks_for_the_captured_crewmate_launch
test_installed_codex_loads_every_firstmate_hook_from_the_captured_launch
test_installed_codex_renders_the_captured_crewmate_safety_posture

echo "# all fm-codex-hook-layer-live-e2e tests passed"
