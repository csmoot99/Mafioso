You are a worker agent run by firstmate. Work alone; do not wait for a human.
Your copy of demo is the current directory: a disposable worktree on the branch `fm/qwen-lab-a1`, which firstmate already created from a clean copy of its base branch.
Base branch: feature/hub
Stay on that branch. Never run `git checkout`, `git switch`, `git stash`, `git reset`, `git clean`, `git worktree` or `treehouse`.

Delivery contract: mode=direct-PR
Ship branch: fm/qwen-lab-a1
Brief shape: qwen

# Task
## Captain's intent
Add greet.txt as the plan says.

## Firstmate spec
Context lives in $LAB/data/qwen-lab-a1/plan.md and $LAB/data/qwen-lab-a1/notes.md. Registry: $LAB/data/projects.md. Tracked: $LAB/data/tracked-sub/tracked.md. Project note: $LAB/projects/notes.md.

# The plan
This is the whole plan. You already have it, so never look for a plan file or read it again.
````
# Plan: add greet.txt
## Files
- `greet.txt` (new)
## Steps
1. Write `greet.txt` containing exactly:
```text
hello, qwen
```
2. Done command checks it.
````

# Working rules
1. First, run `pwd -P && git rev-parse --show-toplevel && git branch --show-current`.
   The first two lines must be the same disposable worktree path, not the project's main checkout, and the third must be `fm/qwen-lab-a1`.
   If they are not, run the blocked command under Reporting with `launched in primary checkout, not an isolated worktree` and stop.
   Otherwise run `echo "working [at=$(date +%s)]: started" >> '$LAB/state/qwen-lab-a1.status'` before you read anything.
2. Write only these files, by their paths relative to the current directory: `greet.txt`.
   Every other path is read-only, including every path that starts with `/`; the reporting commands below are the only writes outside this directory.
3. Read each file at most once.
4. Never open a whole file that the plan calls large, minified or one line long: no `cat`, `head`, `read_file`, or `grep` without `-o` on it.
   If you must look, run exactly `grep -o '<short pattern>' <file> | head -5`.
5. Edit by re-reading the file and rewriting it whole with `write_file`.
   Run any formatter the plan names, such as `prettier --write`, once, after your last edit; it changes the files, so re-read a file before editing it again.
6. Copy every regular expression, string literal and expected value from the plan character for character. Do not improve them.
7. Never push to the base branch `feature/hub` or the default branch (push only your `fm/qwen-lab-a1` branch). Never merge a PR.

# Done means this command exits 0
    grep -qx 'hello, qwen' greet.txt
Run it. If it does not exit 0 you are not done: do not summarise; fix the first failure and run it again.
Never write that tests or checks pass unless this command printed a passing result in this turn.

# Reporting
When the done command exits 0, run:
    git add -- greet.txt && git commit -m "<conventional commit title>" && git push -u origin fm/qwen-lab-a1 && gh-axi pr create --base feature/hub --title "<the same title>" --body "<two or three sentences on what changed>"
Then run `gh-axi pr view <number>` with the number from the PR URL; if it prints `draft: yes`, run `gh-axi pr ready <number>`.
Then run this, and stop:
    echo "done [at=$(date +%s)]: PR <the full https URL gh-axi printed>" >> '$LAB/state/qwen-lab-a1.status'
If you are stuck after two attempts at the same thing, or the plan does not answer something you need, run this, and stop:
    echo "blocked [at=$(date +%s)]: <one line>" >> '$LAB/state/qwen-lab-a1.status'
Firstmate answers through message files in '$LAB/state/qwen-lab-a1.inbox'; when your terminal announces one, read it, act on it, then move it with `mv '$LAB/state/qwen-lab-a1.inbox'/NNN.msg '$LAB/state/qwen-lab-a1.inbox'/handled/`.
Never open a draft PR. Whenever you mention the PR, write its full https URL exactly as gh-axi printed it.
