# Sourced helper: run a command in the lab's clean environment, as bin/fm-live-lab.sh lab_run does.
ROOT=/tmp/fmlab.mqamTx; LAB=$ROOT/home
N=labd660c6604ef5
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
E=/home/work/.no-mistakes/evidence/01M6J7PKV256GMHCCDMF1HB193
# run <label...> -- show a command and its rc in transcript form, with $LAB shortened
run() { printf '$ %s\n' "$(printf '%s ' "${@##*/}")"; lab "$@" 2>&1 | grep -v '^●'; local rc=${PIPESTATUS[0]}; echo "[rc=$rc]"; }
bl() { lab "$LAB/bin/fm-tasks-axi.sh" show "$1" 2>&1 | grep -E '^  (state|blocked|blocked_by|held):'; }
meta() { grep -E '^(base_sha|scope|interfaces|mode|worktree)=' "$LAB/state/$1.meta"; }
st() { cat "$LAB/state/$1.status" 2>/dev/null; }
sc() { lab "$LAB/bin/fm-scope.sh" "$@"; }
WTOF() { sed -n 's/^worktree=//p' $LAB/state/$1.meta; }
g() { git -c user.name=lab -c user.email=lab@example.invalid "$@"; }
mkp() { local proj=$1 id=$2 title=$3 mode=$4
  lab "$LAB/bin/fm-brief.sh" "$id" $proj --mode $mode >/dev/null || return 1
  TASK_TEXT=$5 SPEC_TEXT=$6 python3 - "$LAB/data/$id/brief.md" <<'PY'
import os, sys
p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("{TASK}",os.environ["TASK_TEXT"],1).replace("{FIRSTMATE_SPEC}",os.environ["SPEC_TEXT"],1)
open(p,"w",encoding="utf-8").write(t)
PY
  lab "$LAB/bin/fm-tasks-axi.sh" add "$id" "$title" --kind ship --repo $proj >/dev/null
}
spawnp() { local proj=$1 id=$2 mode=$3 yolo=$4; shift 4
  lab "$LAB/bin/fm-spawn.sh" "$id" "$LAB/projects/$proj" --mode $mode --yolo $yolo --harness claude --model sonnet --effort low "$@"; }
