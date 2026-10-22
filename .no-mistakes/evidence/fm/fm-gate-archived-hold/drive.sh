#!/usr/bin/env bash
# Live driver: replays the cooked-business-card completion against real
# fm-captain-hold.sh / fm-teardown.sh / tasks-axi in a marked lab home.
# Usage: drive.sh <fm-root> <scenario>
set -u
ROOT=$1 SCEN=$2
WT=/home/work/.no-mistakes/worktrees/5f69104d19ce/01M5JFZV7WTWQ1NWPR41MVG9HH
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 9
# External collaborators teardown would touch for a real worktree (treehouse pool,
# no-mistakes runs, gh) are shadowed so the lab never reaches the operator's
# real pool; tmux is the real lab server this driver runs inside.
mkdir -p "$LAB/stubbin"
for t in treehouse no-mistakes gh gh-axi; do printf '#!/bin/sh\nexit 0\n' > "$LAB/stubbin/$t"; chmod +x "$LAB/stubbin/$t"; done
export PATH="$LAB/stubbin:$PATH"
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
cp "$WT/.tasks.toml" "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
ARCH="$LAB/data/done-archive.md"
say() { printf '\n$ %s\n' "$*"; }
run() { say "$*"; "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return $rc; }
tx() { (cd "$LAB" && tasks-axi "$@"); }
cap() { "$ROOT/bin/fm-captain-hold.sh" "$@"; }
scout_meta() {  # <scout> <keys>
  mkdir -p "$LAB/data/$1"
  printf '%s\n' "window=firstmate:fm-$1" "worktree=$LAB/projects/missing-$1" \
    "project=$LAB/projects/sample" harness=codex kind=scout "spawn_gen=lab-$1" \
    decisions_reviewed=1 "decision_keys=$2" > "$LAB/state/$1.meta"
  printf 'done: report complete\n' > "$LAB/state/$1.status"
  printf '# Report\n\nThe investigation finished.\n' > "$LAB/data/$1/report.md"
}
add_scout() { tx add "$1" "Review the card" --kind scout --repo sample --start >/dev/null; scout_meta "$1" "$2"; }
hold() { cap hold "$1" --title "Approve the card color" --reason "card needs approval" --origin "$2" --repo sample >/dev/null; }
answer() { printf 'I approve the business card.\n' > "$LAB/decision.txt"; cap answer "$1" --decision-file "$LAB/decision.txt" >/dev/null; }
prune() { tx prune --keep 0 >/dev/null; }
echo "### root=$ROOT scenario=$SCEN lab=$LAB"
case "$SCEN" in
  business-card)
    S=cooked-business-card C=cooked-card-color-approval
    add_scout "$S" "$C"; hold "$C" "$S"; answer "$C"; prune
    run tx show "$C"
    say "grep -n -A3 '$C' done-archive.md"; grep -n -A6 "$C" "$ARCH"
    before=$(sha256sum "$ARCH")
    run cap verify "$S"
    run cap complete "$S" "$C"
    run "$ROOT/bin/fm-teardown.sh" "$S"
    say "archive unchanged?"; [ "$before" = "$(sha256sum "$ARCH")" ] && echo "archive sha256 unchanged" || echo "ARCHIVE MUTATED"
    say "ls state/"; ls "$LAB/state" ;;
  unanswered)
    S=card-scout C=card-call
    add_scout "$S" "$C"; hold "$C" "$S"; tx done "$C" >/dev/null; prune
    say "grep archive"; grep -n -A4 "$C" "$ARCH"
    run cap verify "$S"; run cap complete "$S" "$C"; run "$ROOT/bin/fm-teardown.sh" "$S"
    say "origin meta still present?"; ls "$LAB/state/$S.meta" ;;
  missing)
    S=card-scout C=never-held-call
    add_scout "$S" "$C"
    run cap verify "$S"; run cap complete "$S" "$C"; run "$ROOT/bin/fm-teardown.sh" "$S" ;;
  reused)
    C=reused-call
    for o in first-scout second-scout; do add_scout "$o" "$C"; hold "$C" "$o"; answer "$C"; prune; done
    say "grep -c archive rows"; grep -n "$C" "$ARCH"
    run cap complete second-scout "$C"; run cap verify second-scout; run cap verify first-scout ;;
  legacy)
    S=legacy-scout C=legacy-call
    tx add "$C" "Old unanswered call" --repo sample >/dev/null; tx done "$C" >/dev/null; prune
    add_scout "$S" "$C"; hold "$S-decision-$C" "$S"
    run cap complete "$S" "$C" ;;
  answer-intake)
    S=card-scout C=card-call
    add_scout "$S" "$C"; hold "$C" "$S"; answer "$C"; prune
    before=$(sha256sum "$ARCH")
    printf 'Second answer.\n' > "$LAB/d2.txt"
    run cap answer "$C" --decision-file "$LAB/d2.txt"
    say "archive unchanged?"; [ "$before" = "$(sha256sum "$ARCH")" ] && echo "archive sha256 unchanged" || echo "ARCHIVE MUTATED" ;;
esac
rm -rf "$LAB"
echo "### lab removed: $( [ -e "$LAB" ] && echo no || echo yes)"
