Work alone; do not wait for a human.
Your copy of fixture-project is the current directory: a disposable worktree on the branch `fm/qwen-combine`, which firstmate already created from a clean copy of its default branch.
Stay on that branch. Never run `git checkout`, `git switch`, `git stash`, `git reset`, `git clean`, `git rebase`, `git cherry-pick`, `git worktree` or `treehouse`.

Delivery contract: mode=direct-PR
Ship branch: fm/qwen-combine
Brief shape: qwen

# Task
## Captain's intent
{TASK}

## Firstmate spec
{FIRSTMATE_SPEC}

# The combine
This is the whole plan; never look for a plan file.
Run the steps in order, one at a time, copying each command exactly.
A command that prints `WAIT:` ends your work until firstmate answers: reply with the one line it gives and call no more tools.

1. Fold https://github.com/o/r/pull/11 (head `1111111`). Run:
       bash '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/data/qwen-combine/combine.sh' fold 1
   If it prints `WAIT:`, do what it says and call no more tools.
   It merges cleanly.

2. Fold https://github.com/o/r/pull/12 (head `2222222`). Run:
       bash '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/data/qwen-combine/combine.sh' fold 2
   If it prints `WAIT:`, do what it says and call no more tools.
   It merges cleanly.

# Rules
1. Write only the files a step names, only as it says; every other path is read-only.
2. A conflict block runs from a `<<<<<<<` line through its `>>>>>>>` line. Find the blocks with `grep -nE '^(<<<<<<<|=======|>>>>>>>|[|]{7})([[:space:]]|$)' <file>`, read the file with `read_file`, and resolve each block with one `edit` whose old_string starts at its `<<<<<<<` line and ends at its `>>>>>>>` line. If `edit` refuses, `read_file` the file once and retry.
3. Resolve a conflict only as its step says; never choose between two sides yourself. The fold command has already checked that each block's sides are the ones its step names.
4. Only a step's commit command concludes its merge: if it prints `refused:`, fix only what it names and run that commit command again; never run `git commit` until it prints `committed`.
   Run only the commands this brief gives and `grep`. Never run `git merge`, `git add`, `git rm`, `git status`, `git fetch`, `git branch`, `git show`, `rm`, `ls`, `cat` or `find`.
5. Never push to the default branch (push only your `fm/qwen-combine` branch). Never merge a PR.
   Never use `--force`, `--squash` or `--amend`.


# Testing before handoff
Run focused tests during development and before validation; fix reproduced failures and rerun the affected checks.
Leave the full suite to the pipeline or assigned integrator; do not pre-run an identical full baseline merely to hand off.
Keep every task-specific test mandate and currently required gate unless firstmate explicitly supersedes it.
# Finish
After the last step, run this command:
    bash '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/data/qwen-combine/combine.sh' publish
It checks every fold and the tests, pushes, opens the combined PR and writes your done line.
If publish prints `refused:`, fix only what it names, in a file a step names; commit a fix with `git commit -m "fix: <what>" -- <that file>`; run it again. Only this script writes the done line; never write one yourself.

# Reporting
Keep every done or blocked report (status line and final reply) to at most about 500 tokens: outcome, files changed, diff stat, checks run and results, and one open question only if blocked.
Use "none" or "not run" for fields with no changes or checks; never return a full diff or a transcript.
Keep detailed evidence in the task report or task data folder and return its path when needed.
When a command prints `Published.` or `WAIT:`, reply with its result and the return fields on one line and call no more tools.
If a command still refuses after two fixes, or anything else fails twice, run this, and stop:
    echo "blocked [at=$(date +%s)]: <return envelope>" >> '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen-combine.status'
Replace `<return envelope>` with the return fields on one line.
Write status lines only with the commands in this brief.
Firstmate answers through message files in '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen-combine.inbox'; when your terminal announces one, read it, act on it, then move it with `mv '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen-combine.inbox'/NNN.msg '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen-combine.inbox'/handled/`.
