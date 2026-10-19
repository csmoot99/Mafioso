Work alone; do not wait for a human.
Your copy of project is the current directory: a disposable worktree on the branch `fm/qwen-brief-spawn-844404`, which firstmate already created from a clean copy of its default branch.
Stay on that branch. Never run `git checkout`, `git switch`, `git stash`, `git reset`, `git clean`, `git worktree` or `treehouse`.

Delivery contract: mode=direct-PR
Ship branch: fm/qwen-brief-spawn-844404
Brief shape: qwen

# Task
## Captain's intent
Add an initials helper and a reversed-name helper and print both from src/index.js.

## Firstmate spec
Follow the plan exactly. Edit only the three listed files.

# The plan
This is the whole plan; never look for a plan file.
````
1. Create `src/initials.js` with exactly this content:

```js
function initials(first, last) {
  return first[0] + '.' + last[0] + '.';
}

module.exports = { initials };
```

2. In `src/names.js`, add this function below `fullName`, and export it next to `fullName` so the last line reads `module.exports = { fullName, reversed };`:

```js
function reversed(first, last) {
  return last + ', ' + first;
}
```

3. In `src/index.js`, also require `initials` from `./initials` and `reversed` from `./names`, and after the existing `console.log` line add two lines:

```js
console.log(initials('Ada', 'Lovelace'));
console.log(reversed('Ada', 'Lovelace'));
```
````

# Rules
1. Write only `src/initials.js`, `src/names.js`, `src/index.js` in this directory; every other path is read-only.
2. Copy every regular expression, string literal and expected value from the plan character for character, and never loosen a test to make it pass.
3. Read a file with `read_file`, never `cat` or `head`, and only when you need it.
4. Never open a file the plan calls large, minified or one line long; to look inside it, run `grep -o '<short pattern>' <file> | head -5`.
5. Create a file with `write_file` and change it with `edit`. Both refuse a file that changed, or that qwen forgot when it compressed the chat, since you last read it: then `read_file` it once and retry.
6. Run any formatter the plan names once, after your last edit.
7. Never push to the default branch (push only your `fm/qwen-brief-spawn-844404` branch). Never merge a PR.

# Done means this command exits 0
    node src/index.js | diff - <(printf 'Ada Lovelace\nA.L.\nLovelace, Ada\n')
Run it; until it exits 0, fix the first failure and run it again. Never say it passed unless it printed a pass.

# Reporting
When the done command exits 0, run this as one command, then reply with one line and call no more tools:
    git add -- src/initials.js src/names.js src/index.js && git commit -m "<conventional commit title>" && git push -u origin fm/qwen-brief-spawn-844404 && url=$(gh-axi pr create --title "<the same title>" --body "<two or three sentences on what changed>" | grep -m1 -o 'https://[^ ]*/pull/[0-9]*') && echo "done [at=$(date +%s)]: PR $url" | tee -a '/tmp/qbr.hMDW9B/home/state/qwen-brief-spawn-844404.status'
If that fails, if you are stuck after two attempts at the same thing, or if the plan does not answer something you need, run this, and stop:
    echo "blocked [at=$(date +%s)]: <one line>" >> '/tmp/qbr.hMDW9B/home/state/qwen-brief-spawn-844404.status'
Write status lines only with the commands in this brief.
Firstmate answers through message files in '/tmp/qbr.hMDW9B/home/state/qwen-brief-spawn-844404.inbox'; when your terminal announces one, read it, act on it, then move it with `mv '/tmp/qbr.hMDW9B/home/state/qwen-brief-spawn-844404.inbox'/NNN.msg '/tmp/qbr.hMDW9B/home/state/qwen-brief-spawn-844404.inbox'/handled/`.

# Start
Before you look at any file, run this command:
    [ "$(pwd -P)" = "$(git rev-parse --show-toplevel)" ] && [ "$(git branch --show-current)" = fm/qwen-brief-spawn-844404 ] && echo "working [at=$(date +%s)]: started" >> '/tmp/qbr.hMDW9B/home/state/qwen-brief-spawn-844404.status' && echo OK || echo STOP
If it printed STOP, run the blocked command above with `launched in primary checkout, not an isolated worktree`, and stop.
