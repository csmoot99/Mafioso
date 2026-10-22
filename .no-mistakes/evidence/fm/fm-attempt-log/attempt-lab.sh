#!/usr/bin/env bash
# Disposable attempt-log lab: lab home built from the gate worktree HEAD (same
# layout/record as bin/fm-live-lab.sh so `fm-live-lab.sh down` tears it down),
# with real bin/fm-spawn.sh / fm-control.sh / fm-teardown.sh driven directly.
# Usage: attempt-lab.sh setup <src-worktree>      -> prints ROOT
#        attempt-lab.sh run <ROOT> <cmd...>       -> run inside lab env (cwd = lab home)
#        attempt-lab.sh brief <ROOT> <id> <task>  -> scaffold brief + backlog item
set -u
cmd=$1; shift
lab_env() {
  env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" SHELL=/bin/zsh TERM=xterm-256color \
    LANG="${LANG:-en_US.UTF-8}" TMUX_TMPDIR="$TMUX_DIR" TREEHOUSE_ROOT="$ROOT/treehouse" \
    FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 FM_HOME="$LAB" "$@"
}
load() { ROOT=$1; LAB=$ROOT/home; TMUX_DIR=$(sed -n 's/^tmux_dir=//p' "$ROOT/.fm-live-lab"); }
case "$cmd" in
setup)
  SRC=$1
  ROOT=$(mktemp -d /tmp/fmlab.XXXXXX); ROOT=$(cd -P "$ROOT" && pwd -P); LAB=$ROOT/home
  NONCE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
  ls -1A "$HOME/.treehouse" 2>/dev/null | sort > "$ROOT/.treehouse-before"
  {
    echo 'fm-live-lab v1'; echo harness=claude; echo "home=$LAB"; echo expect_host=no; echo host_off=no
    echo mate=no; echo worker=no; echo "nonce=$NONCE"; echo mate_id=; echo "worker_id=lab${NONCE:0:12}-w1"
    echo gate=; echo "pi_trust=$( [ -f "$HOME/.pi/agent/trust.json" ] && shasum -a 256 "$HOME/.pi/agent/trust.json" | awk '{print $1}' || echo absent)"
    echo claude_config_dir=; echo "claude_store=$HOME/.claude.json"; echo "pi_trust_store=$HOME/.pi/agent/trust.json"
    echo "treehouse_dir=$HOME/.treehouse"
  } > "$ROOT/.fm-live-lab"
  "$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  git -C "$LAB" init -q -b main && git -C "$LAB" fetch -q "$SRC" HEAD && git -C "$LAB" checkout -q -f -B main FETCH_HEAD || exit 1
  git -C "$LAB" config user.name lab && git -C "$LAB" config user.email lab@example.invalid
  mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects" "$ROOT/treehouse"
  printf 'tmux\n' > "$LAB/config/backend"; printf 'claude\n' > "$LAB/config/crew-harness"
  printf 'auto\n' > "$LAB/config/claude-permission-mode"
  TMUX_DIR=$("$LAB/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
  echo "tmux_dir=$TMUX_DIR" >> "$ROOT/.fm-live-lab"
  lab_env tmux -f /dev/null new-session -d -s firstmate -n lab -x 220 -y 60 -c "$ROOT" || exit 1
  pid=$(env -u TMUX TMUX_TMPDIR="$TMUX_DIR" tmux display-message -p '#{pid}')
  printf 'launch_pid=%s\nlaunch_start=%s\n' "$pid" "$(ps -o lstart= -p "$pid" | awk '{$1=$1;print}')" >> "$ROOT/.fm-live-lab"
  # notes project with a lab-private bare origin
  seed=$ROOT/origins/notes-seed; mkdir -p "$seed/notes" "$seed/tests"; git init -q -b main "$seed"
  printf '"""Tiny notes lib."""\n\nNOTES = []\n\n\ndef add_note(text):\n    NOTES.append(text)\n    return len(NOTES) - 1\n' > "$seed/notes/__init__.py"
  printf 'import unittest\n\nimport notes\n\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        notes.NOTES.clear()\n        self.assertEqual(notes.add_note("x"), 0)\n' > "$seed/tests/test_notes.py"
  printf '# notes\nRun `python3 -m unittest discover -s tests`.\n' > "$seed/README.md"
  git -C "$seed" add -A && git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -qm seed
  git clone -q --bare "$seed" "$ROOT/origins/notes.git"; rm -rf "$seed"
  git clone -q "$ROOT/origins/notes.git" "$LAB/projects/notes"
  printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes library\n' > "$LAB/data/projects.md"
  echo "$ROOT"
  ;;
run) load "$1"; shift; cd "$LAB" && lab_env "$@" ;;
pid) load "$1"; shift; pid=$1
  printf 'launch_pid=%s\nlaunch_start=%s\n' "$pid" "$(ps -o lstart= -p "$pid" | awk '{$1=$1;print}')" >> "$ROOT/.fm-live-lab" ;;
brief) load "$1"; id=$2; task=$3
  (cd "$LAB" && lab_env "$LAB/bin/fm-brief.sh" "$id" notes --mode local-only) >/dev/null || exit 1
  TASK_TEXT="$task" python3 - "$LAB/data/$id/brief.md" <<'PY' || exit 1
import os, sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("{TASK}", os.environ["TASK_TEXT"], 1).replace("{FIRSTMATE_SPEC}", "Keep it minimal: edit, run python3 -m unittest discover -s tests, commit, report done. Nothing else is in scope.", 1)
open(p, "w").write(t)
PY
  (cd "$LAB" && lab_env "$LAB/bin/fm-tasks-axi.sh" add "$id" "lab attempt worker $id" --kind ship --repo notes) >/dev/null
  ;;
esac
