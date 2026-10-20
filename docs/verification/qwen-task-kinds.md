# Qwen task kinds

This record backs the kinds table in [`qwen-task-kinds`](../../.agents/skills/qwen-task-kinds/SKILL.md): which ship tasks are common and simple enough for the local qwen worker, and the live trials each listed kind passed.

## Task kinds in a month of ship tasks

Measured on 2026-10-20 over the 390 ship launch briefs written from 2026-09-20 to 2026-10-20 (every `data/<id>/launch-brief.md` carrying a delivery contract, with the private tenant-guide and monetization tasks left out).
A cheap-model first pass read each brief's `## Captain's intent` and `## Firstmate spec` against a fixed taxonomy (kind, files touched, fully specified, mechanical check, main paths), the counts were aggregated from its rows joined with each task's project, and the small rows named below were checked against their briefs.
Delivery modes: direct-PR 287, no-mistakes 87, local-only 16.
Projects: 420mia 189, b2b-platform 99, naughty-nomz 32, firstmate 27, cannabake-platform 16, 420usa 12, environment-tutorial 6, kds-core 6.

| Kind | Tasks | At most 3 files | Checks the specs name | Projects |
|---|---|---|---|---|
| docs | 21 | 9 | content 12, none 5, test 2, typecheck 1, lint 1 | b2b-platform 11, 420mia 4, naughty-nomz 2, environment-tutorial 2, cannabake-platform 1, kds-core 1 |
| copy | 3 | 1 | content 3 | naughty-nomz 3 |
| config-dep | 13 | 6 | test 7, lint 2, build 2, content 2 | 420mia 3, b2b-platform 3, 420usa 2, naughty-nomz 2, cannabake-platform 1, dotfiles 1, kds-core 1 |
| content-data | 8 | 7 | content 4, test 2, visual 2 | 420mia 4, environment-tutorial 3, naughty-nomz 1 |
| bugfix-small | 18 | 7 | test 16, build 2 | 420mia 9, b2b-platform 5, naughty-nomz 2, 420usa 1, cannabake-platform 1 |
| ci-tooling | 20 | 9 | test 16, lint 3, build 1 | b2b-platform 6, naughty-nomz 5, 420mia 3, kds-core 2, four others 1 each |
| test-add | 6 | 2 | test 6 | 420mia 5, cannabake-platform 1 |
| ui-small | 5 | 5 | visual 4, test 1 | naughty-nomz 3, 420mia 1, b2b-platform 1 |
| rename | 3 | 1 | test 2, content 1 | 420mia 2, naughty-nomz 1 |

The rest are never simple by the taxonomy: feature 203, other 40, agent-tooling 33, bugfix-diagnose 14, refactor 3.

The most common simple kind is `text-edit`, docs and copy together: 24 tasks, 10 of them at three files or fewer, and checked by exact content alone.
Its small tasks come from b2b-platform (4), environment-tutorial (2, local-only, so the qwen shape cannot deliver them), and 420mia, naughty-nomz, and cannabake-platform (1 each), plus naughty-nomz's one small copy task.
They are corrections such as stale facts in hosted runbooks, newsletter-runbook fixes, product-delete code comments, and a page's share title.

The next candidate, a data edit (config-dep and content-data, 21 tasks, 13 small), was not set up.
Four of its seven small content-data tasks are 420mia seed listings whose specs are mostly research (find each shop's website, establish delivery evidence) before a short seed change, so they are not specifiable before dispatch without doing that research first; the other three are environment-tutorial edits, which are local-only.
Its six small config-dep tasks each touch a different file type with a different check (Renovate and workflow files, a Caddyfile, a public-key module, a Nix file, a content module), so no one setup file covers them.
bugfix-small and ci-tooling are mostly test-checked but need diagnosis or design, and ui-small is checked by eye.

## text-edit trials

Run on 2026-10-20 on Linux (WSL2) with Qwen Code 0.25.2 and Ollama 0.40.3 serving `qwen3-coder:30b` with a 65,536-token window, on the tmux backend (3.6) on a private server, with no Herdr.
Each trial's project was a scratch clone of b2b-platform at `7b2cb29` with the draft setup file below committed at `ai-map/qwen/text-edit.md`, a local bare origin, and a stub `gh-axi` printing one PR URL.
Each case was shaped like the project's real small doc tasks, from real lines of the clone.
The task worktree's own scripts scaffolded and launched each worker, one at a time and only after `ollama ps` showed no runner and no qwen worker ran:

```sh
bin/fm-brief.sh <id> b2b-platform --mode direct-PR --harness qwen --kind text-edit --edits <edits> \
  --done-command 'node scripts/check-agent-docs.cjs && node scripts/check-map-symbols.cjs'
env FM_HOME=<lab home> FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh <id> --relaunch
```

A case expecting a PR passed only when the pushed branch changed exactly the listed files, each byte for byte equal to the expected text, with one done line.
A case expecting a stop passed only when nothing was pushed, the copy was back at its base and clean, and a `needs-decision` or `blocked` line was written.

| # | Case | Result | Requests | Peak prompt tokens |
|---|---|---|---|---|
| 1 | one stale fact in one runbook | exact, 40s | 5 | 17.2k |
| 2 | the same stale fact in three runbooks | exact, 55s | 9 | 26.2k |
| 3 | a money figure in a table row | exact, 46s | 5 | 21.0k |
| 4 | a bullet added after a line | exact, 50s | 5 | 18.1k |
| 5 | a new short runbook, linked from another | wrong: the new file lacked its final newline, 51s | 8 | 19.3k |
| 6 | a line deep in a long runbook | exact, 50s | 7 | 22.7k |
| 7 | a comment in a TypeScript file | exact, 50s | 7 | 22.2k |
| 8 | three wrapped lines rewritten | exact, 45s | 4 | 17.5k |
| 9 | firstmate's mistake: a bound of 0 for a replaced line | stopped as expected, nothing pushed, copy reset, 46s | 5 | 18.4k |
| 10 | one of three files holding a stale fact, the other two off limits | exact, 45s | 4 | 16.7k |
| 11 | one table row | exact, 46s | 5 | 18.4k |
| 12 | a line in a package README | exact, 51s | 5 | 17.1k |
| 13 | case 5 again | exact, 50s | 9 | 20.4k |

Trial 1's worker never read the setup file the brief named in prose, so from trial 2 the helper's `start` prints it.
In trials 5, 8, 10, and 12 the worker skipped `start` and so never saw the setup file, and trial 5's `write_file` dropped the new file's final newline.
From trial 13 the helper puts back a final newline an edit dropped, and a publish before any `start` prints the setup file and refuses once.
No trial wrote outside its listed files, ran a forbidden git command, invented a PR URL, or wrote a second done line.

## b2b-platform setup-file draft

This is the setup file the trials ran with, for firstmate to land in b2b-platform at `ai-map/qwen/text-edit.md` through that project's own PR.
In b2b-platform `ai-map/` is in `.prettierignore`, and `scripts/check-map-symbols.cjs` scans only `ai-map/master_map.md` and `ai-map/features/*/map.md`, so the new file trips no project check.

````markdown
# Text edits in b2b-platform

You are making a text edit: changing wording in this project's Markdown docs, exactly as your brief lists it.
Your brief lists every file you may write and every edit; this file only tells you how this project's text looks.

## Where the text is

- Operator runbooks: `docs/runbooks/*.md` and `docs/runbooks/hosted/*.md`.
- Plans and findings: `docs/plans/*.md`.
- Package and app guides: `README.md` files at the repository root, in `apps/*/` and in `packages/*/`.

## How the text looks

- Prose is hard-wrapped near 100 characters per line, so one sentence can span two or three lines.
- The brief quotes whole lines; copy each one character for character, including backticks, `**bold**` markers, `§` section signs, `→` arrows and `—` dashes.
- Keep the wrapping the brief gives you; never re-wrap a paragraph you were not told to change.
- Money is written like `€177 ($199.18)`, and dates like `2026-10-20`.

## How to edit

- `read_file` a listed file once, then change it with `edit`, using the brief's quoted lines as `old_string`.
- An edit that adds lines quotes the line they go after; keep that line in `new_string` and put the new lines under it.
- If `edit` says the text was not found, `read_file` the file once and retry with the exact text the brief quotes; never change a different line in its place.

## Never edit

`AGENTS.md`, `CLAUDE.md`, `docs/spec.md`, `ai-map/CHANGELOG.md`, `ai-map/NOW.md`, or any file the brief does not list.

## Check

Your brief's publish command runs `node scripts/check-agent-docs.cjs && node scripts/check-map-symbols.cjs` after the brief's own text checks; never run either yourself.
````
