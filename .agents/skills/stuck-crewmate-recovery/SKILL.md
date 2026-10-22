---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Also use on the inverse case: a live crewmate reporting the no-mistakes pipeline dead, unreachable, or timed out.
  Load before retrying or escalating a failed implementation attempt; owns the bounded attempt budget, failure envelope, and preserved-copy procedure.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.
A stale or dead-endpoint report for a worker whose pull request has already landed is not a recovery case: the work is finished, so close the task through ordinary teardown (`AGENTS.md` section 7 for firstmate, the landed-work rule in `bin/fm-branch-prompt.sh` for the supervision branch) instead of this playbook, never with `--force`.

Follow the crew-hosted Lavish board contract in [`docs/configuration.md`](../../../docs/configuration.md#crew-hosted-lavish-review-boards) when recovering a worker that hosts a board.

Interrupt, stop, and relaunch a worker through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
That plane covers workers running in this home; a remotely placed secondmate is refused by name and reconciled through `secondmate-provisioning` instead.
Load `harness-adapters` before a resume command or a harness-specific skill invocation, and whenever the adapter's own quirks matter.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Failed implementation attempts

Use this procedure when an implementation approach fails, before any corrective steer, model change, or replacement that would try the implementation again.
Endpoint recovery below resumes interrupted work; it is not permission to reset this attempt budget or carry a failed implementation into a stronger model's context.
An active no-mistakes run keeps ownership of its fixes and gates under `validation-supervision`; do not launch a competing attempt or count its internal fix rounds as separate worker attempts.

### Reconcile evidence and choose the next attempt

1. Read the worker's bounded return and the task's existing attempt record, not its transcript.
   If evidence is missing, have the worker complete the envelope below, or dispatch a cheap T1 extraction scout through normal intake with the evidence paths and one bounded question.
   Extraction gathers evidence only; it does not retry implementation or consume an implementation attempt.
2. Distinguish an implementation failure from an operational blocker.
   Missing credentials, unavailable services, and broken tooling return as `blocked` with the concrete blocker; a heavier model is not a remedy.
   Reconcile claims about a dead pipeline through the pipeline section below before making that classification.
3. Keep a durable attempt record in the original task's data folder, linked from its backlog note and every successor's brief.
   Record the original task id, original base commit, attempt number, tier and resolved profile, worker id, branch and copy, outcome, evidence paths, and whether the same-tier correction has been used.
   The first implementation is attempt 1; reconstruct it from recorded launch or worker evidence when handling an existing task.
   The original base is the full commit actually used before that first implementation, not today's branch tip, a guessed merge base, or the failed attempt's HEAD.
   If the base or attempt history cannot be established, stop as blocked rather than guessing or resetting the counter.
4. Allow one bounded same-tier correction per task only when the envelope identifies an obvious local cause and a concrete correction.
   That correction consumes the next attempt number and uses its own fresh copy under the preparation procedure below.
   If it fails, or no obvious local correction exists, escalate exactly one tier through the configured dispatch policy with the failure envelope.
   Do not equate a harness change with a tier change or invent a profile; an unavailable or ambiguous tier goes back to firstmate's normal routing decision.
5. Allow at most three implementation attempts in total across all tiers and successor worker ids, including the first attempt and the same-tier correction.
   After attempt 3 fails, return the unresolved question and preserved evidence to the captain instead of launching attempt 4.
   Repeated failure with no new evidence stops retries earlier for reassessment; record what was learned and what decision is missing, rather than treating a larger model as new evidence.

### Preserve the failure and prepare a fresh attempt

Before replacing the worker, have it save the failure envelope and its current diff in the original task's data folder under a distinct attempt-numbered name.
The diff must cover the original base through the current working tree, including committed, staged, unstaged, and binary changes; separately preserve task-relevant untracked files with a manifest because a tracked diff omits them.
Record the failed HEAD and dirty-file inventory with those artifacts, and verify the files were written before starting another attempt.
If the worker cannot produce them, use a bounded extraction worker against the preserved copy; never let it edit that copy or race a live writer.
Firstmate reads the envelope and artifact paths, never the full diff or transcript.

Reconcile ownership and any active validation before stopping the failed worker through the lifecycle plane above.
Preserve its branch, commits, uncommitted files, task records, and copy; saving a diff does not authorize teardown, reset, stash, pool return, or deletion.
Keep cleanup pending for the captain and ask about the preserved failed attempts in a batch, separately from the implementation result.

Create the successor through the normal intake, brief, dispatch, and isolated-spawn path with a distinct worker id and branch, linked to the original task and its shared attempt count.
Do not use same-copy relaunch for an implementation retry, and do not allocate a copy by bypassing `fm-spawn`.
Carry the original acceptance criteria, delivery mode, merge authority, and PR target forward; pass only paths to the failure envelope and evidence, not their contents or the failed worker's conversation.
Reserve the next attempt number in the shared record before dispatch so a repeated notification reconciles that successor instead of launching another one.
If launch fails before implementation starts, record the operational blocker and reconcile that reservation before resuming; never create a second successor for it.

In the successor's brief, replace the generated Setup branch-start instruction with an explicit pinned-start requirement: after the isolation assertion and before any edits or tests, verify the fresh copy is clean, resolve the recorded original commit, and start its new attempt branch at exactly that commit.
Keep the spawn's base-branch selection as the PR target; it is a branch name, not a way to pass an original commit SHA.
Fresh spawn normally refreshes to the target's current tip, so that refresh alone does not satisfy the pinned-start requirement.
For a launch path that precreates the branch, require proof that it is the new, clean attempt branch with no worker commits before positioning it at the original commit; never move an existing attempt's branch.
The worker must report its verified starting SHA before implementation and stop as blocked if the original commit is unavailable, the copy is dirty, or the branch cannot be positioned without overwriting work.
Do not apply the failed diff or cherry-pick failed commits into the new attempt; those artifacts are evidence for a fresh implementation from the original base.

### Failure-envelope template

Store this envelope with the attempt evidence and keep its filled body within about 500 tokens.
Use paths and narrow line ranges for supporting evidence; never embed a full diff or transcript.
The attempt record above owns the complete attempt history; this envelope is the standalone handoff to the next worker or the captain.

```markdown
## Failure envelope
- Outcome: implementation failure or operational blocker, and the concrete reason.
- Attempt: original task id; attempt number of 3; tier/profile; same-tier correction used or unused.
- Base and preserved work: original commit; failed HEAD; branch/copy; attempt-record path.
- Expected vs observed: required behavior and actual result.
- Reproduction: minimal command or steps, inputs, and evidence path.
- Files changed: paths and relevant line ranges.
- Diff: stat; saved binary-capable diff path; untracked manifest/artifact paths or none.
- Checks: commands, results, and any checks not run.
- Approaches tried: bounded correction, if any, and new evidence since the previous attempt.
- Unresolved question: the single question preventing completion.
```

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

For a REMOTE secondmate, `fm-crew-state` and `fm-peek` read the actual remote endpoint over `fm-on.sh`, and `fm-send` reports a delivered-with-pending-confirmation steer as delivered (their headers own the contracts); an `unknown-remote` read or unreachable-host failure means the remote state could not be read, never that the mate is dead or the send failed.
Recover a genuinely stuck remote mate only through `bin/fm-spawn.sh <id> --secondmate`, never raw herdr pane close/kill surgery, which strands the endpoint binding.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
A HERDR endpoint that is not merely idle but destroyed - a pane or workspace removed in Herdr churn - is recovered by that same relaunch, which creates one fresh endpoint in the existing worktree and rebinds the task's record to it; nothing special is needed, and the worktree is untouched ([`docs/agent-control.md`](../../../docs/agent-control.md) "Reclaiming a task whose endpoint is gone").
That relaunch proves the endpoint is destroyed before it rebinds, so a Herdr server that was merely stopped is adopted back rather than duplicated.
On tmux there is no reclaim: a task record carries no socket identity for its endpoint, so a `missing` window cannot be told apart from one on a tmux server this seat cannot address, and both `exit` and `relaunch` refuse.
Do not work around either refusal by respawning - it means a live agent may still hold that worktree.
That reclaim is the owning home's operation only, and a secondmate is the one exception: recover it through `bin/fm-spawn.sh <id> --secondmate` as above.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## A live crewmate claiming the pipeline is dead

This is the inverse of the dead-endpoint case above: the worker is alive and the pipeline it declares dead usually is too.
A drive call blocks until the next gate or outcome, far longer than a harness lets one command run, and the daemon accepts a response immediately and runs the round in the background.
So a crewmate's timed-out, killed, or errored drive call leaves it waiting on a read it never got, and the "the daemon is gone" conclusion it draws from that is a guess, not evidence.

Read the two authoritative sources yourself before believing the claim:

1. `no-mistakes daemon status` for the socket.
2. `no-mistakes axi status --run <id>` for the run, or `bin/fm-crew-state.sh <id>`, which already folds this contradiction in and reports a non-socket daemon-or-timeout `blocked:` line over a running or fixing run with fresh activity as superseded because the run is alive.

A refused connection or missing socket from `daemon status` is positive daemon-down evidence and must be escalated even if the persisted run record still says running or fixing; that record can be stale after the daemon exits.
Otherwise, if the run is still running or fixing with recent activity, the claim is wrong: steer the crewmate to reattach with `no-mistakes axi run` from its own worktree, which is safe and idempotent while the run still matches its `HEAD`, and tell it a timeout is not daemon death.
Nothing reaches the captain in that case.

Never restart, stop, or update the shared daemon on a crewmate's claim.
It is one instance serving every lane and home, so a restart kills other lanes' in-flight runs.
Only positive socket refusal or absence is a daemon-down finding; escalate that finding, or a failed run record that names a daemon error, to the captain.

## Live-endpoint escalation

For a failed implementation, use the attempt procedure above instead; the steps here address worker responsiveness and delivery of instructions, not another implementation attempt.

Escalate in order:

1. Peek the pane, and check the task's steering inbox (`state/<id>.inbox/`) for unhandled `*.msg` records - a stale wake naming an unread firstmate instruction means the worker never acknowledged a durable steer, and the record itself shows exactly what was intended.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
4. If the crewmate is genuinely wedged after redirection, relaunch it with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> relaunch --note '<progress so far>'`, which stops the agent, carries the brief plus that note into a replacement in the same local copy, and restores the prior record if the replacement cannot start.
   Pass `--harness`, `--model`, or `--effort` on that same command when the worker should come back on a different runtime.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.
