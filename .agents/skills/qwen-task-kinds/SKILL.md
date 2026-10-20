---
name: qwen-task-kinds
description: Load before routing a task to a qwen worker by task kind, writing its edits file, drafting a project's ai-map/qwen/<kind>.md setup file, or handling a qwen task-kind stop (a needs-decision line starting "edit stopped:").
user-invocable: false
metadata:
  internal: true
---

# Qwen task kinds

The local qwen worker takes the fleet's most common simple tasks when firstmate has made every judgment before dispatch.
It follows concrete commands and quoted text and drops process prose, so firstmate writes each edit as exact text, `bin/fm-brief.sh --kind` renders it, and `bin/fm-qwen-edit.sh` owns every check, the commit, the PR, the done line, and every stop.
The evidence, trial by trial, is in [`docs/verification/qwen-task-kinds.md`](../../../docs/verification/qwen-task-kinds.md).

## Kinds

| Kind | The task | Checked by |
|---|---|---|
| `text-edit` | Wording in Markdown docs, runbooks, READMEs, or code comments: whole lines replaced, lines added after a line, or a short new file. | The edits' `has` and `lacks` texts, then the project's doc check named in its setup file. |

A kind not in this table has no trialled setup; route its tasks by the ordinary dispatch rules.

## When a task fits

Use the qwen worker only when every point holds; otherwise route the task by the ordinary dispatch rules.

- The task's resolved delivery mode is direct-PR on a project with no bound forge, because the qwen shape renders nothing else.
- The project's clone holds `ai-map/qwen/<kind>.md` on the task's base branch.
- Firstmate can write every edit as exact text before dispatch, and every wording choice is already made.
- It touches one to three files, and each edit quotes at most a few whole lines.
- Each new text can be checked with `has`, and each text that must vanish can be checked with `lacks` against the whole file.

## Write the edits file

`bin/fm-brief.sh`'s header owns the edits-file format; this section owns how firstmate fills it.

1. Fleet-sync the clone, then quote the base branch's current lines, never memory or a stale report.
2. Write each edit as a bullet under its `file` line, with every quoted line indented nine spaces:
   - `   - Replace this text:`, the whole existing lines, `     with this text:`, the whole new lines.
   - `   - After this line:`, the one existing line, `     add these lines:`, the new lines.
   - `   - Create the file with exactly this text:`, the whole file.
3. Make each quoted existing text occur exactly once in its file; quote a longer span when a line repeats.
4. Set the `file` line's bound to the number of existing lines the edits remove or rewrite, counted the way `git diff --numstat` counts deletions; a pure addition or a new file is 0.
5. Add a `has` line for each new text, and a `lacks` line only for a text that must not remain anywhere in its file.
6. Pass the setup file's check command as `--done-command`.

To count a bound, apply the edits to a scratch copy of the file and read the second column of `git diff --no-index --numstat <original> <edited>`.

## Dispatch

1. Run `bin/fm-brief.sh <id> <repo> --mode direct-PR --harness qwen --kind <kind> --edits <file> --done-command '<check>'`, with `--branch-prefix` and `--base-branch` as for any ship.
2. Fill `{TASK}` with the captain's words as section 11 of `AGENTS.md` says, and `{FIRSTMATE_SPEC}` with `Make exactly the edits below and nothing else; publish when they are done.`
3. Spawn with the qwen profile, one qwen worker at a time: the model has one GPU.

## On a stop

An `edit stopped:` line means the helper already reset the copy to its base, so it holds no unlanded work.
A `blocked:` line from a qwen task-kind worker means it gave up on an edit it could not place.

- When the line names firstmate's own mistake, such as a quoted text the file does not hold, a bound too small for the edits, or a check that cannot pass, correct the edits file, scaffold a fresh task, and relaunch once.
- Otherwise, or after that one relaunch also stops, clean the task up and dispatch the paid fallback: the profile the ordinary dispatch rules give the task when qwen does not fit, on the standard brief, with the edits file's text as its `## Firstmate spec`.
- Never steer the qwen worker to improvise a fix; it cannot ask a question, and its stops are the safe outcome.

## Setup files

Each project carries one setup file per kind at `ai-map/qwen/<kind>.md`, the same path in every project.
The helper prints it into the worker's context before anything is committed, and the qwen launch loads no other context file or skill (the `harness-adapters` qwen reference owns that launch).
Draft it from [`references/setup-template.md`](references/setup-template.md) and land it through that project's own direct-PR, never in its `AGENTS.md` or `CLAUDE.md`.
