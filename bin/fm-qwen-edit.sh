#!/usr/bin/env bash
# The steps of a qwen task-kind edit: a qwen worker making a few exactly
# specified edits to named files (.agents/skills/qwen-task-kinds/SKILL.md).
# bin/fm-brief.sh --harness qwen --kind <kind> --edits <file> writes
# data/<task-id>/edit.sh, which assigns this task's values and then sources this
# file; the worker runs only that file, with one of:
#   start      write the working line once and say what comes next
#   publish    check the edits, run the gate, commit the listed files with the
#              task's title, push, open the PR or find the one already open for
#              BRANCH, and write the done line with the URL gh-axi printed
# publish stops the edit on anything the brief never allows: a merge, rebase,
# cherry-pick or revert in progress, a commit publish did not make, a change
# after publish committed, a tracked file outside FILES changed, or a listed
# file losing more existing lines than its bound in MAXDEL; so does a fourth
# refusal. A stop appends the needs-decision line, resets the copy to the commit
# the task started from and removes any new listed file, so it holds no
# unlanded work, records the stop in MARK, and every later call only repeats the
# WAIT text, which a qwen worker reads as waiting for firstmate rather than as
# an error to fix. publish refuses, naming what to fix, when no listed file
# changed, a has or lacks check fails, the gate fails, or the commit or push
# fails. Untracked files outside FILES, such as a gate's output, are never
# committed and never stop it. Only publish writes the done line, and only after
# gh-axi printed a PR URL. Every call first checks the copy is the top of its
# own worktree on BRANCH, else it appends the blocked line and waits. A refusal
# exits 1.
# Inputs, assigned by edit.sh: STATUS (the task's status file), BRANCH, PR_BASE
# (the PR's base branch, empty for the default), MARK (the stop record, beside
# edit.sh), GATE (the command that must exit 0), TITLE, BODY, the arrays FILES
# and MAXDEL (each listed worktree-relative path and the most existing lines its
# edits may remove or rewrite), and the arrays CHECK, CPATH and CTEXT (each
# check's kind, has or lacks, its listed file, and the fixed string it looks
# for).
# Never run this file directly.
# shellcheck disable=SC2154 # edit.sh assigns every input before sourcing this file.
set -u

[ "${BASH_SOURCE[0]}" != "$0" ] || { echo "error: $0 is sourced by a data/<task-id>/edit.sh that bin/fm-brief.sh --kind writes; never run it directly" >&2; exit 2; }

halt() { printf 'WAIT: %s, and firstmate has been told. Reply with exactly: waiting for firstmate. Then call no more tools; the answer arrives in your terminal.\n' "$1"; exit 0; }
finished() { halt "this edit needs firstmate's answer before anything else can run"; }
git_dir_file() { git rev-parse --git-path "fm-edit/$1"; }
words() { paste -sd ' ' -; }
# own: the commits on this copy that no origin ref holds except the task branch,
# which publish itself pushes, oldest last.
own() { git rev-list HEAD --not --exclude="origin/$BRANCH" --remotes=origin; }
stop() {
  local base
  base=$(own | tail -1)
  base=$(git rev-parse -q --verify "${base:-HEAD}${base:+^}" || git rev-parse HEAD)
  echo "needs-decision [at=$(date +%s)]: edit stopped: $1; the copy is reset to ${base:0:7}" >> "$STATUS"
  git reset -q --hard "$base"
  git clean -fq -- "${FILES[@]}"
  echo stopped > "$MARK"
  finished
}
refuse() {
  local f n
  f=$(git_dir_file refusals) n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
  [ "$n" -lt 4 ] || stop "publish refused four times, the last: $*"
  mkdir -p "$(dirname "$f")" && echo "$n" > "$f"
  printf 'refused: %s\n' "$*"
  exit 1
}

[ ! -f "$MARK" ] || finished
if [ "$(pwd -P)" != "$(git rev-parse --show-toplevel 2>/dev/null)" ] || [ "$(git branch --show-current)" != "$BRANCH" ]; then
  echo "blocked [at=$(date +%s)]: launched in primary checkout, not an isolated worktree" >> "$STATUS"
  halt "this is not your own copy on the branch $BRANCH"
fi
case ${1:-} in
  start)
    started=$(git_dir_file started)
    if [ ! -f "$started" ]; then
      mkdir -p "$(dirname "$started")" && : > "$started"
      echo "working [at=$(date +%s)]: started" >> "$STATUS"
    fi
    printf 'Started. Make the edits under # The edits, then run: bash %q publish\n' "$0" ;;
  publish)
    for h in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
      ! git rev-parse -q --verify "$h" >/dev/null || stop "a git operation is in progress ($h)"
    done
    for d in rebase-merge rebase-apply; do
      [ ! -e "$(git rev-parse --git-path "$d")" ] || stop "a rebase is in progress"
    done
    rec=$(cat "$(git_dir_file commit)" 2>/dev/null)
    mine=$(own)
    changed=$(git diff --no-renames --name-only HEAD)
    if [ -n "$mine" ]; then
      [ "$mine" = "$rec" ] || stop "the copy holds a commit publish did not make: $(git log -1 --format=%s "$(printf '%s\n' "$mine" | head -1)")"
      [ -z "$changed" ] || stop "files changed after publish committed: $(printf '%s\n' "$changed" | words)"
    else
      other=$(printf '%s\n' "$changed" | grep -vxF -f <(printf '%s\n' "${FILES[@]}"))
      [ -z "$other" ] || stop "a file the brief does not list changed: $(printf '%s\n' "$other" | words)"
      for i in "${!FILES[@]}"; do
        del=$(git diff --numstat HEAD -- "${FILES[i]}" | awk '{ print $2 }')
        [ "${del:-0}" = - ] || [ "${del:-0}" -le "${MAXDEL[i]}" ] \
          || stop "${FILES[i]} lost $del existing lines, more than the ${MAXDEL[i]} its edits change"
      done
      [ -n "$changed$(git ls-files --others --exclude-standard -- "${FILES[@]}")" ] || refuse "no listed file changed: make the edits under # The edits first"
      for i in "${!CHECK[@]}"; do
        if [ "${CHECK[i]}" = has ]; then
          grep -qF -- "${CTEXT[i]}" "${CPATH[i]}" 2>/dev/null || refuse "${CPATH[i]} does not contain this exact text yet: ${CTEXT[i]}"
        else
          ! grep -qF -- "${CTEXT[i]}" "${CPATH[i]}" 2>/dev/null || refuse "${CPATH[i]} still contains this text, which must go: ${CTEXT[i]}"
        fi
      done
      out=$( (eval "$GATE") 2>&1) || { printf '%s\n' "$out" | tail -20; refuse "the project check failed: fix the first failure above, in a listed file"; }
      git add -A -- "${FILES[@]}"
      out=$(git commit -q -m "$TITLE" 2>&1) || { printf '%s\n' "$out" | tail -20; refuse "git commit failed: fix the first failure above, in a listed file"; }
      mkdir -p "$(dirname "$(git_dir_file commit)")" && git rev-parse HEAD > "$(git_dir_file commit)"
    fi
    git push -q -u origin "$BRANCH" || refuse "git push failed"
    # A repeated publish finds the PR the first one opened rather than opening another.
    url=$(gh-axi pr list --state open --head "$BRANCH" --fields url 2>/dev/null | grep -m1 -o 'https://[^ "]*/pull/[0-9]*') || {
      out=$(gh-axi pr create ${PR_BASE:+--base "$PR_BASE"} --title "$TITLE" --body "$BODY") || refuse "gh-axi pr create failed"
      url=$(printf '%s\n' "$out" | grep -m1 -o 'https://[^ ]*/pull/[0-9]*') || refuse "gh-axi printed no PR URL: $out"
    }
    echo "done [at=$(date +%s)]: PR $url" | tee -a "$STATUS"
    echo "Published. Reply with one line and call no more tools." ;;
  *) printf 'refused: usage: start | publish\n'; exit 1 ;;
esac
