#!/usr/bin/env bash
# The steps of a qwen combine: a qwen worker folding approved PRs into one
# combined PR (.agents/skills/combined-merge/SKILL.md). bin/fm-brief.sh
# --harness qwen --combine writes data/<task-id>/combine.sh, which assigns this
# combine's values and then sources this file; the worker runs only that file,
# with one of:
#   fold <n>     merge step n's exact head with `git merge --no-ff` and its
#                merge message; the first fold also checks the copy starts at
#                the base commit firstmate's trial merge used and writes the
#                working line
#   commit <n>   conclude step n's stopped merge once no conflict marker is left
#                in its conflicted files, every line the resolution wrote that
#                neither side has is one step n's note gives, every line outside
#                the conflict blocks fold saved is kept whole and in order, and
#                nothing outside those files changed, then record the merge
#                commit it made
#   publish      check every fold, and that each conflicted step's merge is the
#                one its commit recorded, run the gate, push, open the PR or find the
#                one already open for BRANCH, and write the done line with the
#                URL gh-axi printed
# A fold whose conflicted files differ from the set firstmate expected (a clean
# step that stops, a conflicted step that merges cleanly, any other file), a
# conflict side line the step's note never names, a merge that fails without a
# conflict, a base that moved, and a conflicted merge concluded outside its
# commit command all stop the combine, so the helper rather
# than the worker judges whether a conflict is the one the step describes: the
# needs-decision line is appended, the copy is reset to the base commit so it
# holds no unlanded commit, the stop is recorded in MARK, and every later call
# only repeats the WAIT text, which a qwen worker reads as waiting for firstmate
# rather than as an error to fix. Only publish writes the done line, and only
# after gh-axi printed a PR URL. Every call first checks the copy is the top of
# its own worktree on BRANCH, else it appends the blocked line and waits. A
# refusal exits 1 and names what to fix.
# Inputs, assigned by combine.sh: STATUS (the task's status file), BRANCH, BASE
# (full commit), PR_BASE (the PR's base branch, empty for the default), MARK
# (the stop record, beside combine.sh), GATE (the command that must exit 0),
# TITLE, BODY, and the arrays HEADS, MSGS, EXPECT and NOTES, indexed from 1 by
# step, holding each step's full head, merge message, space-separated expected
# conflicted files (empty for a clean step), and the resolution note firstmate
# wrote under its fold.
# Never run this file directly.
# shellcheck disable=SC2154 # combine.sh assigns every input before sourcing this file.
set -u

[ "${BASH_SOURCE[0]}" != "$0" ] || { echo "error: $0 is sourced by a data/<task-id>/combine.sh that bin/fm-brief.sh --combine writes; never run it directly" >&2; exit 2; }

N=$((${#HEADS[@]} - 1))
refuse() { printf 'refused: %s\n' "$*"; exit 1; }
halt() { printf 'WAIT: %s, and firstmate has been told. Reply with exactly: waiting for firstmate. Then call no more tools; the answer arrives in your terminal.\n' "$1"; exit 0; }
finished() { halt "step $1 needs firstmate's answer before anything else can run"; }
merging() { git rev-parse -q --verify MERGE_HEAD >/dev/null; }
stop() {
  echo "needs-decision [at=$(date +%s)]: combine step $n stopped: $1; the copy is reset to ${BASE:0:7}" >> "$STATUS"
  git reset -q --hard "$BASE" 2>/dev/null || ! merging || git merge --abort
  echo "$n" > "$MARK"
  finished "$n"
}
unmerged() { git diff --name-only --diff-filter=U | sort -u | tr '\n' ' ' | sed 's/ $//'; }
# A marker line is git's: seven marker characters, then whitespace or the line's
# end, so a longer setext or reStructuredText underline is not one. A file the
# resolution or a later fold deleted holds none.
markers() {
  local f left=0
  for f in "$@"; do
    [ ! -f "$f" ] || ! grep -HnE '^(<<<<<<<|=======|>>>>>>>|[|]{7})([[:space:]]|$)' -- "$f" || left=1
  done
  return "$left"
}
# sides <file>: each line of either side of the file's conflict blocks, trimmed;
# a diff3 base section is neither side.
sides() {
  awk 'function m(c) { return substr($0, 1, 7) == c && (length($0) == 7 || substr($0, 8, 1) ~ /[ \t]/) }
    m("<<<<<<<") { b = s = 1; next } b && m("|||||||") { s = 0; next } b && m("=======") { s = 1; next }
    b && m(">>>>>>>") { b = s = 0; next } s' "$1" | trim
}
# kept <saved> <file>: fail, printing the first line outside the conflict blocks
# of <saved>, the conflicted file as git left it, that <file> no longer keeps; the
# lines before, between and after the blocks must stay whole and in order, and
# only the blocks may be replaced.
kept() {
  awk 'function m(c) { return substr($0, 1, 7) == c && (length($0) == 7 || substr($0, 8, 1) ~ /[ \t]/) }
    function miss(l) { print l; exit 1 }
    BEGIN { k = 0 }
    NR == FNR { if (m("<<<<<<<")) { b = 1; k++ } else if (b) { if (m(">>>>>>>")) b = 0 } else seg[k, ++len[k]] = $0; next }
    { r[++nr] = $0 }
    END {
      for (j = 1; j <= len[0]; j++) if (j > nr || r[j] != seg[0, j]) miss(seg[0, j])
      if (k == 0) { if (nr > len[0]) miss(r[len[0] + 1]); exit }
      p = len[0]; e = nr - len[k]
      for (j = 1; j <= len[k]; j++) if (e < p || r[e + j] != seg[k, j]) miss(seg[k, j])
      for (s = 1; s < k; s++) {
        for (q = p; q + len[s] <= e; q++) { for (j = 1; j <= len[s] && r[q + j] == seg[s, j]; j++); if (j > len[s]) break }
        if (q + len[s] > e) miss(seg[s, 1])
        p = q + len[s]
      }
    }' "$1" "$2"
}
trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep .; }
# unsaid: the first input line step n's note never names.
unsaid() {
  local l
  while IFS= read -r l; do [[ ${NOTES[$n]} == *"$l"* ]] || { printf '%s\n' "$l"; return; }; done
}

[ ! -f "$MARK" ] || finished "$(cat "$MARK")"
if [ "$(pwd -P)" != "$(git rev-parse --show-toplevel 2>/dev/null)" ] || [ "$(git branch --show-current)" != "$BRANCH" ]; then
  echo "blocked [at=$(date +%s)]: launched in primary checkout, not an isolated worktree" >> "$STATUS"
  halt "this is not your own copy on the branch $BRANCH"
fi
cmd=${1:-} n=${2:-}
case $cmd in
  fold | commit)
    case $n in '' | *[!0-9]*) refuse "usage: $cmd <step number>" ;; esac
    [ "$n" -ge 1 ] && [ "$n" -le "$N" ] || refuse "there is no step $n"
    read -r -a files <<<"${EXPECT[$n]}"
    want=$(printf '%s\n' ${files[@]+"${files[@]}"} | sort -u | tr '\n' ' ' | sed 's/ $//')
    saved=$(git rev-parse --git-path "fm-combine/$n") ;;
  publish) ;;
  *) refuse "usage: fold <n> | commit <n> | publish" ;;
esac
case $cmd in
  fold)
    for ((i = 1; i < n; i++)); do
      git merge-base --is-ancestor "${HEADS[$i]}" HEAD || refuse "step $i is not done yet"
    done
    ! merging || refuse "a merge is still stopped: finish its step with its commit command"
    if git merge-base --is-ancestor "${HEADS[$n]}" HEAD 2>/dev/null; then echo "Step $n is already folded. Go on with the next step."; exit 0; fi
    if [ "$n" = 1 ]; then
      [ "$(git rev-parse HEAD)" = "$BASE" ] || stop "the copy starts at $(git rev-parse --short HEAD), not at ${BASE:0:7}, the base firstmate's trial merge used"
      echo "working [at=$(date +%s)]: started" >> "$STATUS"
    fi
    out=$(git merge --no-ff -m "${MSGS[$n]}" "${HEADS[$n]}" 2>&1)
    got=$(unmerged)
    if merging && [ -n "$got" ]; then
      [ -n "$want" ] || stop "git stopped on a conflict in $got, but this step was to merge cleanly"
      [ "$got" = "$want" ] || stop "git stopped on a conflict in $got, but this step expects one in $want"
      for f in "${files[@]}"; do
        [ ! -f "$f" ] || { odd=$(sides "$f" | unsaid); [ -z "$odd" ]; } || stop "a conflict side in $f is not what this step says: $odd"
      done
      for f in "${files[@]}"; do
        [ ! -f "$f" ] || { mkdir -p "$(dirname "$saved/$f")" && cp -- "$f" "$saved/$f"; }
      done
      printf 'Step %s stopped on a conflict in %s, as the step says. Resolve it as the step says, then run: bash %q commit %s\n' "$n" "$got" "$0" "$n"
    elif git merge-base --is-ancestor "${HEADS[$n]}" HEAD 2>/dev/null; then
      [ -z "$want" ] || stop "it merged cleanly, but this step expects a conflict in $want"
      echo "Step $n merged cleanly. Go on with the next step."
    else
      stop "git merge failed without a conflict: $(printf '%s\n' "$out" | grep -m1 .)"
    fi ;;
  commit)
    merging || refuse "no merge is stopped: run this step's fold command first"
    [ "$(git rev-parse MERGE_HEAD)" = "${HEADS[$n]}" ] || refuse "the stopped merge is not step $n's"
    [ -n "$want" ] || refuse "step $n has no conflict to commit"
    markers "${files[@]}" || refuse "conflict markers are left in the lines above"
    for f in "${files[@]}"; do
      [ ! -f "$f" ] || { odd=$(grep -vxF -f <({ git show "HEAD:$f"; git show "MERGE_HEAD:$f"; } 2>/dev/null) -- "$f" | trim | unsaid); [ -z "$odd" ]; } \
        || refuse "$f has a line that neither side has and step $n does not give: $odd"
      [ ! -f "$f" ] || [ ! -f "$saved/$f" ] || lost=$(kept "$saved/$f" "$f") \
        || refuse "$f changed a line outside its conflict blocks; keep every line outside them as git left it: $lost"
    done
    other=$({ git diff --name-only; git ls-files --others --exclude-standard; } | grep -vxF -f <(printf '%s\n' "${files[@]}") | sort -u | tr '\n' ' ')
    [ -z "$other" ] || refuse "files outside this step's conflict changed: $other"
    git add -A -- "${files[@]}"
    [ -z "$(unmerged)" ] || refuse "still unmerged: $(unmerged)"
    git commit -q --no-edit && mkdir -p "$(dirname "$saved")" && git rev-parse HEAD > "$saved.commit" \
      && echo "Step $n committed. Go on with the next step." ;;
  publish)
    ! merging || refuse "a merge is still stopped: resolve it and run its step's commit command"
    [ -z "$(git status --porcelain --untracked-files=no)" ] || refuse "uncommitted changes: $(git status --porcelain --untracked-files=no | tr '\n' ' ')"
    all=
    for ((i = 1; i <= N; i++)); do
      git merge-base --is-ancestor "${HEADS[$i]}" HEAD || refuse "step $i is not done: run its fold command"
      # A conflicted step's merge must be the one its commit checked and recorded.
      if [ -n "${EXPECT[$i]}" ]; then
        rec=$(cat "$(git rev-parse --git-path "fm-combine/$i.commit")" 2>/dev/null)
        [ -n "$rec" ] && [ "$(git rev-list --merges --parents HEAD | awk -v h="${HEADS[$i]}" '$3 == h { print $1; exit }')" = "$rec" ] \
          || { n=$i; stop "its merge was concluded outside its commit command, so its resolution is unchecked"; }
      fi
      all="$all ${EXPECT[$i]}"
    done
    read -r -a files <<<"$all"
    markers ${files[@]+"${files[@]}"} || refuse "conflict markers are left in the lines above"
    out=$( (eval "$GATE") 2>&1) || { printf '%s\n' "$out" | tail -20; refuse "the gate failed: fix the first failure above"; }
    git push -q -u origin "$BRANCH" || refuse "git push failed"
    # A repeated publish finds the PR the first one opened rather than opening another.
    url=$(gh-axi pr list --state open --head "$BRANCH" --fields url 2>/dev/null | grep -m1 -o 'https://[^ "]*/pull/[0-9]*') || {
      out=$(gh-axi pr create ${PR_BASE:+--base "$PR_BASE"} --title "$TITLE" --body "$BODY") || refuse "gh-axi pr create failed"
      url=$(printf '%s\n' "$out" | grep -m1 -o 'https://[^ ]*/pull/[0-9]*') || refuse "gh-axi printed no PR URL: $out"
    }
    echo "done [at=$(date +%s)]: PR $url" | tee -a "$STATUS"
    echo "Published. Reply with one line and call no more tools." ;;
esac
