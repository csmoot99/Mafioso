# Sourced helper: run a command in the lab's clean environment, as bin/fm-live-lab.sh lab_run does.
ROOT=/tmp/fmlab.eUna19; LAB=$ROOT/home
N=lab5602d5264ff0
TMUX_DIR=$(sed -n 's/^tmux_dir=//p' "$ROOT/.fm-live-lab" | head -1)
lab() { (cd "$LAB" && env -i HOME="$HOME" USER="${USER:-work}" LOGNAME="${USER:-work}" PATH="$PATH" SHELL=/bin/zsh TERM=xterm-256color LANG="${LANG:-en_US.UTF-8}" TMUX_TMPDIR="$TMUX_DIR" TREEHOUSE_ROOT="$ROOT/treehouse" FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 FM_HOME="$LAB" "$@"); }
ltmux() { env -u TMUX TMUX_TMPDIR="$TMUX_DIR" tmux "$@"; }
# mk <id> <title> <task> <spec>: scaffold a real brief and a queued backlog row
mk() { local id=$1 title=$2
  lab "$LAB/bin/fm-brief.sh" "$id" notes --mode local-only >/dev/null || return 1
  TASK_TEXT=$3 SPEC_TEXT=$4 python3 - "$LAB/data/$id/brief.md" <<'PY'
import os, sys
p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("{TASK}",os.environ["TASK_TEXT"],1).replace("{FIRSTMATE_SPEC}",os.environ["SPEC_TEXT"],1)
open(p,"w",encoding="utf-8").write(t)
PY
  lab "$LAB/bin/fm-tasks-axi.sh" add "$id" "$title" --kind ship --repo notes >/dev/null
}
spawn() { local id=$1; shift
  lab "$LAB/bin/fm-spawn.sh" "$id" "$LAB/projects/notes" --mode local-only --yolo on --harness claude --model sonnet --effort low "$@"; }
