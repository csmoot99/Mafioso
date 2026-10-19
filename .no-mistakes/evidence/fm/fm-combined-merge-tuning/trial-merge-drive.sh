#!/usr/bin/env bash
# Drives the combined-merge skill's trial-merge and integrator commands verbatim
# against a throwaway forge (bare repo) and a fleet-style clone.
set -u
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$W/forge.git"
git clone -q "$W/forge.git" "$W/dev" 2>/dev/null; cd "$W/dev"
mkdir -p ai-map src
printf 'line1\nline2\nline3\n\n\n\n\n\n\n\nmid\n\n\n\n\n\n\n\nend\n' > src/app.txt
printf '# Changelog\n- base entry\n' > ai-map/CHANGELOG.md
printf '# Now\nRecent work: base\n' > ai-map/NOW.md
echo a > src/a.txt; echo b > src/b.txt; echo c > src/c.txt
git add -A; git commit -qm base; git push -q origin main
pr() { # name, then edit commands
  local n=$1; shift; git checkout -q -b "$n" main; eval "$@"; git add -A; git commit -qm "$n"; git push -q origin "$n"; git checkout -q main; }
# A and B conflict on src/app.txt line1; both append to CHANGELOG (bookkeeping)
pr prA "sed -i 's/line1/line1-A/' src/app.txt; echo '- PR #A entry' >> ai-map/CHANGELOG.md"
pr prB "sed -i 's/line1/line1-B/' src/app.txt; sed -i 's/Recent work: base/Recent work: B/' ai-map/NOW.md"
# C and D share src/app.txt but in separate hunks (no textual conflict)
pr prC "sed -i 's/^line1$/line1-C/' src/app.txt"
pr prD "sed -i 's/^end$/end-D/' src/app.txt"
# E and F touch disjoint files
pr prE "echo e >> src/a.txt"
pr prF "echo f >> src/b.txt"
# Firstmate's own clone, refreshed (stand-in for bin/fm-fleet-sync.sh)
git clone -q "$W/forge.git" "$W/fleet"; cd "$W/fleet"; git fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
h() { git rev-parse "origin/$1"; }
snap() { { git for-each-ref; git status --porcelain=v2; git rev-parse HEAD; ls -la .git/index; } | sha256sum; }
before=$(snap)
trial() { # base-vs-head for each head, then every pair, then shared-file diff
  echo "== group: $*"
  for p in "$@"; do out=$(git merge-tree --write-tree --name-only origin/main "$(h "$p")"); echo "merge-tree origin/main $p -> exit $?"; done
  local i j a=("$@")
  for ((i=0;i<${#a[@]};i++)); do for ((j=i+1;j<${#a[@]};j++)); do
    out=$(git merge-tree --write-tree --name-only "$(h "${a[i]}")" "$(h "${a[j]}")"); rc=$?
    echo "merge-tree ${a[i]} ${a[j]} -> exit $rc"; [ $rc -eq 1 ] && { echo "  conflicted files (after tree id):"; echo "$out" | sed -n '2,/^$/p' | sed '/^$/d;s/^/    /'; }
  done; done
  echo "  changed files per PR (git diff --name-only origin/main...<head>):"
  for p in "$@"; do git diff --name-only "origin/main...$(h "$p")" | sed "s/^/    $p: /"; done
  shared=$(for p in "$@"; do git diff --name-only "origin/main...$(h "$p")"; done | sort | uniq -d)
  echo "  shared files: ${shared:-<none>}"
}
trial prA prB
trial prC prD
trial prE prF
after=$(snap)
echo "== trial touched refs/index/worktree? $([ "$before" = "$after" ] && echo NO \(unchanged\) || echo YES)"
# Integrator steps 1-3 for A+B, verbatim command shape
echo "== integrator fold of prA, prB"
git checkout -q -b prA-combined origin/main
for p in prA prB; do
  hd=$(h "$p")
  git merge --no-ff -m "Merge #$p from $p at $hd" "$hd" >/dev/null 2>&1; rc=$?
  echo "git merge --no-ff -m 'Merge #$p from $p at ${hd:0:8}' -> exit $rc; conflicted: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
  if [ $rc -ne 0 ]; then
    # resolve code keeping both intents; bookkeeping on combined side
    printf 'line1-A-and-B\nline2\nline3\n\n\n\n\n\n\n\nmid\n\n\n\n\n\n\n\nend\n' > src/app.txt
    for f in $(git diff --name-only --diff-filter=U -- ai-map); do git checkout --ours -- "$f"; done
    git add -A; git commit -qm "Merge #$p from $p at $hd"
  fi
done
echo "  CHANGELOG after folds (prA's entry merged cleanly):"; sed 's/^/    /' ai-map/CHANGELOG.md
echo "  NOW after folds:"; sed 's/^/    /' ai-map/NOW.md
# step 3 final bookkeeping commit: replace every folded PR's entries with one combined entry
git show origin/main:ai-map/CHANGELOG.md > ai-map/CHANGELOG.md; echo '- Combined #A and #B' >> ai-map/CHANGELOG.md
git show origin/main:ai-map/NOW.md | sed 's/Recent work: base/Recent work: combined #A and #B/' > ai-map/NOW.md
git commit -qam "Combined bookkeeping entry for #A and #B"
echo "  CHANGELOG after combined entry:"; sed 's/^/    /' ai-map/CHANGELOG.md
echo "  NOW after combined entry:"; sed 's/^/    /' ai-map/NOW.md
for p in prA prB; do git merge-base --is-ancestor "$(h "$p")" HEAD && echo "  exact head of $p contained in combined branch: yes" || echo "  exact head of $p contained: NO"; done
echo "  merge commit subjects:"; git log --merges --format='    %s' origin/main..HEAD
