Work alone; do not wait for a human.
Your copy of fixture-project is the current directory: a disposable worktree on the branch `fm/qwen`, which firstmate already created from a clean copy of its default branch.
Stay on that branch. Never run `git checkout`, `git switch`, `git stash`, `git reset`, `git clean`, `git worktree` or `treehouse`.

Delivery contract: mode=direct-PR
Ship branch: fm/qwen
Brief shape: qwen

# Task
## Captain's intent
{TASK}

## Firstmate spec
{FIRSTMATE_SPEC}

# The plan
This is the whole plan; never look for a plan file.
```
Update src/a.ts and src/a.test.ts.
```

# Rules
1. Write only `src/a.ts`, `src/a.test.ts` in this directory; every other path is read-only.
2. Copy every regular expression, string literal and expected value from the plan character for character, and never loosen a test to make it pass.
3. Read a file with `read_file`, never `cat` or `head`, and only when you need it.
4. Never open a file the plan calls large, minified or one line long; to look inside it, run `grep -o '<short pattern>' <file> | head -5`.
5. Create a file with `write_file` and change it with `edit`. Both refuse a file that changed, or that qwen forgot when it compressed the chat, since you last read it: then `read_file` it once and retry.
6. Run any formatter the plan names once, after your last edit.
7. Never push to the default branch (push only your `fm/qwen` branch). Never merge a PR.


# Testing before handoff
Run focused tests during development and before validation; fix reproduced failures and rerun the affected checks.
Leave the full suite to the pipeline or assigned integrator; do not pre-run an identical full baseline merely to hand off.
Keep every task-specific test mandate and currently required gate unless firstmate explicitly supersedes it.
# Done means this command exits 0
    make focused-test
Run it; until it exits 0, fix the first failure and run it again. Never say it passed unless it printed a pass.

# Reporting
Keep every done or blocked report (status line and final reply) to at most about 500 tokens: outcome, files changed, diff stat, checks run and results, and one open question only if blocked.
Use "none" or "not run" for fields with no changes or checks; never return a full diff or a transcript.
Keep detailed evidence in the task report or task data folder and return its path when needed.
Replace `<return envelope>` in the commands below with those fields on one line.
When the done command exits 0, run this as one command, then reply with one line and call no more tools:
    git add -- src/a.ts src/a.test.ts && git commit -m "<conventional commit title>" && git push -u origin fm/qwen && url=$(gh-axi pr create --title "<the same title>" --body "<two or three sentences on what changed>" | grep -m1 -o 'https://[^ ]*/pull/[0-9]*') && echo "done [at=$(date +%s)]: PR $url; <return envelope>" | tee -a '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen.status'
If that fails, if you are stuck after two attempts at the same thing, or if the plan does not answer something you need, run this, and stop:
    echo "blocked [at=$(date +%s)]: <return envelope>" >> '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen.status'
Write status lines only with the commands in this brief.
Firstmate answers through message files in '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen.inbox'; when your terminal announces one, read it, act on it, then move it with `mv '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen.inbox'/NNN.msg '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen.inbox'/handled/`.

# Start
Before you look at any file, run this command:
    [ "$(pwd -P)" = "$(git rev-parse --show-toplevel)" ] && [ "$(git branch --show-current)" = fm/qwen ] && echo "working [at=$(date +%s)]: started" >> '/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen.status' && echo OK || echo STOP
If it printed STOP, run the blocked command above with `launched in primary checkout, not an isolated worktree`, and stop.
