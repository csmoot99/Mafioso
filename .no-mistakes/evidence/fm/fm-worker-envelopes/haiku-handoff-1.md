# Handoff 1 — labhaiku1 (count_notes)

## Current state
Task: add `count_notes()` (returns how many notes are stored) to `notes/__init__.py`, plus a unit test in `tests/test_notes.py`. Setup is done and the branch exists, but no code has been written and nothing is committed. The predecessor finished reading `docs/spec-part1.md`–`docs/spec-part3.md` in full and was partway through the spec reads when the context cap hit. Parts 4–6 are still unread.

## Instructions (by path, not restated)
- Launch brief (the authoritative contract, rules, status format, definition of done): `/tmp/fm-lab.IoJpdE/home/data/labhaiku1/launch-brief.md`. A second copy named `brief.md` is in the same folder; the launch-brief operational message is `/tmp/fm-lab.IoJpdE/home/state/operational-inbox/1792696138-3098f26a9d66f76f.msg`. Do not move that operational message.
- Status log (append-only): `/tmp/fm-lab.IoJpdE/home/state/labhaiku1.status`
- Steering inbox: `/tmp/fm-lab.IoJpdE/home/state/labhaiku1.inbox/` (only a `handled/` subfolder exists; no unacknowledged `.msg` files at handoff time).
- Isolated worktree (the only place to edit): `/home/work/.treehouse/notes-f0d98c/1/notes`

## Done
- Isolation verified: `pwd -P` and `git rev-parse --show-toplevel` both return `/home/work/.treehouse/notes-f0d98c/1/notes`, which is the launched slot and not the primary checkout.
- Branch `fm/labhaiku1` created from the seed commit `cacebd0`. Branch head is still `cacebd0`.
- Setup status line appended: `working [at=1792696146]: setup done, branch fm/labhaiku1 created, reading spec`.

## Uncommitted
None. `git status --short` was empty at handoff time. The worktree is clean.

## Next steps (in order)
1. Read `docs/spec-part4.md`, `docs/spec-part5.md`, `docs/spec-part6.md` with the Read tool, each in consecutive 500-line chunks (offset 0, 500, 1000 with limit 500), in that order. Each file is about 1,499 lines. Do not skip a chunk.
2. Read the coding-discipline skill before editing: `/home/work/.no-mistakes/worktrees/5f69104d19ce/01M5JFG0HWJD70QE1WR8QTF44C/.agents/skills/ponytail/SKILL.md`.
3. Implement `count_notes()` in `notes/__init__.py`. The current module is roughly: `NOTES = []`, `add_note(text, tags=None)` appends `{"text", "tags"}`, and `list_notes()` returns `list(NOTES)`. The natural implementation is `return len(NOTES)`, but confirm it against the spec before writing it.
4. Create `tests/test_notes.py` (no `tests/` directory exists yet). Because `NOTES` is module-global, the test must reset state (for example, clear `notes.NOTES` in `setUp`) so it does not depend on test order.
5. Run `python3 -m unittest discover -s tests` from the worktree root and record the result.
6. Commit on `fm/labhaiku1`. Before reporting, confirm the branch is a clean fast-forward of current `main`. `main` was not checked in this incarnation; rebase onto it if it has advanced.
7. Append `done [at=<epoch>]: ready in branch fm/labhaiku1` to the status file and stop. Do not push, open a PR, or merge.

## Decisions made and why
- Read parts 1–3 in full, in 500-line chunks, before any code, as the brief requires. That is the reason no code exists yet.
- The brief's Rule 2 applies: scratch output goes under `/tmp/fm-lab.IoJpdE/home/data/labhaiku1/`, not in the worktree.

## Dead ends
None. No code was tried.

## Open decisions and blockers
- None open in the status log. No `needs-decision` or `blocked` keys are pending from this worker.
- Open question for firstmate (non-blocking): the brief says to read every spec file before writing code. The predecessor read parts 1–3 completely in this incarnation. Whether the replacement must re-read parts 1–3 too is not specified, and that choice is firstmate's.

## Spec findings so far
Parts 1, 2, and 3 contain no requirements for this task. Each is a list of about 1,500 lines, each in the form `N.M word word …`, with random NATO-alphabet-style tokens such as `kilo970 echo404 …`. There are no headings, no API description, and no mention of notes, counts, or tests. Parts 4–6 are assumed to follow the same pattern, but that is unverified (see below).

## Verified
- Isolation check: `pwd -P` and `git rev-parse --show-toplevel` both return `/home/work/.treehouse/notes-f0d98c/1/notes` (run in this incarnation).
- Branch: `git branch --show-current` returns `fm/labhaiku1`.
- Worktree clean: `git status --short` returned empty.
- `notes/__init__.py` content (read in full, 8 lines): `NOTES = []`; `add_note(text, tags=None)`; `list_notes()`.
- `docs/spec-part1.md`, `docs/spec-part2.md`, `docs/spec-part3.md`: read in full, 1,500 lines each, in 500-line chunks. No implementation requirements found.
- `tests/` does not exist in the worktree (`ls` returned "No such file or directory").
- Operational inbox: `/tmp/fm-lab.IoJpdE/home/state/labhaiku1.inbox/` contains only a `handled/` directory, so no message is waiting.

## Unverified
- The content of `docs/spec-part4.md`, `docs/spec-part5.md`, and `docs/spec-part6.md`. They have not been read, so any count-related requirement in them is unknown.
- That `python3 -m unittest discover -s tests` works with a bare `tests/` directory. It has not been run.
- The state of `main`. It has not been checked against `fm/labhaiku1`.
- That `count_notes()` should be `len(NOTES)`. This is the expected design from the task wording, not yet confirmed by the spec.

## Suggested skills
- `/home/work/.no-mistakes/worktrees/5f69104d19ce/01M5JFG0HWJD70QE1WR8QTF44C/.agents/skills/ponytail/SKILL.md`: read before the first edit (brief, "Coding discipline").
- `firstmate-coding-guidelines`: only if the work touches Firstmate itself. It does not here, so it is not needed.

## Tests that matter
- `python3 -m unittest discover -s tests` from `/home/work/.treehouse/notes-f0d98c/1/notes`. Not run yet. Last result: none.

## Secrets
None in this handoff.
