---
name: combined-merge
description: Load before landing two or more approved PRs on the same project and base at the same time, before a merge that would put another approved PR on that base into conflict, or before any merge on a base where a combined PR is being built or validated; it trial-merges them and lands them one by one or through one combined PR.
user-invocable: false
metadata:
  internal: true
---

# Combined merge

Approved PRs that share a project and base land through one combined PR when they touch the same files, so their conflicts are resolved once instead of after every merge.
`ship-landing` still owns registration, merge monitoring, and cleanup for every task involved; this skill owns only the combining.

## When to combine

Consider combining when two or more PRs on the same project and base branch are approved to merge at the same time, or when merging one approved PR would put another approved PR on that base into conflict.
Do not combine:

- PRs on different projects or base branches; each project and base is its own group.
- A single PR; it merges the ordinary way.
- PRs with a true semantic dependency that must land in sequence, such as a migration that must ship before its consumer; land them in that order.
- Local-only ready branches, which have no PR; they land through `bin/fm-merge-local.sh`.
- PRs whose repository refuses merge commits on that base, because a squashed or rebased combined PR leaves every folded PR open; ask the captain instead.

Before choosing, trial-merge the group in this home's clone of the project after refreshing it with `bin/fm-fleet-sync.sh <project>`, using the head commit the forge reports for each PR; the trial touches no ref, index, or working tree:

- `git merge-tree --write-tree --name-only origin/<base> <head>` for each head, and `git merge-tree --write-tree --name-only <head-a> <head-b>` for each pair; exit status 1 is a conflict, with the conflicted files listed after the tree id.
- `git diff --name-only origin/<base>...<head>` for each head, to find files more than one PR changes.
- When the clone lacks a head, such as a fork's, compare the PRs' changed-file lists from the forge instead and treat any shared file as a conflict.

With no conflict and no shared file, merge the PRs one by one through ordinary landing and tell the captain why combining was not needed.
Otherwise combine, and carry each conflicting or shared file into the integrator's steer with the intent to keep from each side.

While a combined PR is being built or validated, hold every other merge on that base, because moving the base under it can force new conflicts and a fresh validation.
A PR approved meanwhile waits for the next combined PR or lands after this one, unless the captain says otherwise; note that wait on its backlog item so a restart keeps it.

## Merge authority

- Judge each PR in its own right, exactly as its own merge would be judged: the captain's explicit word for that PR, or that task's standing `yolo` posture.
- The combined PR inherits merge authority only when every folded PR has it; a PR without it is never folded into an approved group and lands on its own later.
- Before folding, confirm each PR is green at the head being folded and its task carries no open captain hold (`bin/fm-captain-hold.sh open <id>`), because `bin/fm-pr-merge.sh` checks only the combined PR and the integrator's task.
- A red check, a held task, or a destructive, irreversible, or security-sensitive PR still escalates to the captain rather than riding inside the combined PR.
- The one exception to green is a named check the captain waived on a folded PR: that waiver carries into the combined PR only when the captain's approval covered merging those PRs together over that check; otherwise ask before folding that PR.

## Choose the integrator

- The integrator is one live worker of a folded PR with spare context whose task mode is the strictest among the folded tasks (no-mistakes over direct-PR).
- Without one, file and spawn a fresh ship worker in that mode with `--base-branch <base>` when the base is not the default; a spawn past the project's capacity stays queued.
- Steer every other folded worker through `bin/fm-send.sh` not to push to its PR branch, start a validation run, or edit the project's rolling bookkeeping files (`ai-map/CHANGELOG.md` and `ai-map/NOW.md`, or the project's equivalent), and to declare a `paused:` wait until its PR lands through the combined PR.
- Append the captain's merge words and the substance of every folded task's captain intent to the integrator's `## Captain's intent` and relay them, so a no-mistakes integrator's `--intent` covers the whole combined PR under `bin/fm-dod-lib.sh`.
- Quote the captain's merge words verbatim in the integrator's steer beside its merge and publish steps, so the worker's own permission check sees the approval for those commands, and name any waived check carried into the combined PR.

## Integrator steps

Project workers do not load firstmate's skills, so put these steps in the integrator's steer or its fresh brief's `## Firstmate spec`:

1. Cut a new branch from the current base: `<ship-branch>-combined` for a worker reusing its own copy, or a fresh task's own ship branch.
2. Merge each folded PR's current head with `git merge --no-ff -m "Merge #<number> from <branch> at <head>" <head>`, in dependency order; never squash, rebase, cherry-pick, or force-push, because GitHub marks a folded PR merged only when its exact head commit lands.
3. Resolve each conflict once, keeping every PR's intent as the steer describes it; a conflict that cannot keep both intents is a `needs-decision`, not the integrator's choice.
   In the project's rolling bookkeeping files, resolve each fold's conflict by keeping the combined branch's side, then after the last fold write one combined entry naming every folded PR in one commit, within the caps the project sets for those files.
4. Run the union of the folded PRs' tests and the repository's own gates.
5. Publish a combined PR into the base by the integrator's mode: no-mistakes runs one validation on the combined branch, while direct-PR pushes and opens the PR itself.
6. List in the combined PR body each folded PR's full URL and the exact head commit folded from it.
7. Report the ordinary ready line naming the combined PR.

When the integrator's own permission check refuses a merge, push, or validation start, it reports `blocked:` with the exact refused command and stops, never retrying it in another form or routing around the check.
Hand the captain that exact command to type as `! <command>` in the integrator's session, then steer the integrator to continue once it ran; never run it from firstmate or offer a workaround.

## No-mistakes projects

- Each folded PR's own run validated that PR alone against the old base, and nothing has validated the conflict resolutions, so the combined branch gets exactly one ordinary no-mistakes run driven by the integrator under `validation-supervision`.
- Never hand-merge around that run, skip it because every part passed, or start a second pipeline beside it; its ask-user findings follow `ask-user-authority` as usual.
- When the combined diff would not fit the pipeline's review time limit, split the group into smaller combined PRs that land in sequence rather than skipping validation.

## Folded workers while waiting

- Every folded worker other than the integrator stays paused with no new work until cleanup.
- Its declared wait re-surfaces on the long recheck cadence; confirm the combined PR is still in flight without steering the worker, because every steer spends one of its turns.
- To end an idle folded worker once its head is folded, run `bin/fm-control.sh <id> exit`: it stops only the agent and keeps the local copy, branch, records, and merge poll, and `bin/fm-teardown.sh`'s landed-work test reads that copy rather than the agent, so cleanup after the combined merge is unchanged.
- A context handoff from a folded worker that is only waiting gets no replacement: exit it that way, then close the handoff with `bin/fm-send.sh <id> --resolve-key context-handoff-<n> "<no replacement needed>"`, which records the answer without ringing the stopped worker.
- When an exited folded worker is needed again, such as for a PR that must land on its own, `bin/fm-control.sh <id> relaunch --note "<why>"` resumes it in the same copy.

## Land

1. Register the combined PR on the integrator's task with `bin/fm-pr-check.sh <integrator-task> <combined-url>` per `ship-landing`; that rebinds a reused worker's task from its own folded PR, and `bin/fm-pr-merge.sh` refuses the combined URL until it does.
2. Compare each folded PR's live head with the commit the combined PR body lists for it; when one moved, have the integrator merge the new head and report ready again.
3. Merge with `bin/fm-pr-merge.sh <integrator-task> <combined-url> -- --merge`, since only a merge commit lands every folded head intact; add `--allow-red <check-name>` before the `--` only for a waiver carried under Merge authority.
4. Confirm GitHub now reads each folded PR merged; its own merge poll then wakes tagged `external`, which is expected because the merge authority was recorded on the integrator's task.
   A folded PR still open holds work the combined PR did not carry and lands on its own through ordinary landing.
5. Clean up the integrator and every folded task through `bin/fm-teardown.sh <id>`, never `--force`; its landed-work test accepts a folded task whose local head the combined merge carried, and a refusal is investigated per `ship-landing`.
6. Report the combined PR's full URL and each folded PR's full URL to the captain.
