---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Before announcing readiness or calling `bin/fm-pr-check.sh`, apply the Consigliere stage below when enabled; a builder's ready signal starts that stage and is not its verdict.
Then run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, the Consigliere verdict and counts when enabled, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
`bin/fm-pr-merge.sh` refuses a merge that would conflict with another task's validation still in flight on the same project and base, naming that task, its PR or branch, and the conflicting files; merge once each named run has ended, abort a named run whose PR is already green but which is still monitoring CI (`no-mistakes axi abort` in its worktree, as after every green run) and then merge, land two green PRs that conflict with each other through `combined-merge`, and pass the script's attended override only on the captain's explicit word to merge anyway (its header owns the rule).
Load `combined-merge` before landing two or more approved PRs on the same project and base at the same time, before a merge that would put another approved PR on that base into conflict, or before any merge on a base where a combined PR is being built or validated.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

## Opt-in Consigliere review

[`docs/configuration.md`](../../../docs/configuration.md#consigliere-review-configconsigliere) owns the `config/consigliere` switch, dispatch mapping, and configuration instructions.
Read it through `fm_consigliere_mode` from `bin/fm-consigliere-lib.sh`: missing or `off` preserves the delivery path above, `on` applies this stage to every PR-based ship in this home, and invalid configuration stops readiness for correction.
Local-only landing is unchanged.
This is the narrow independent-review exception in AGENTS.md section 7, not permission for extra reviewers or a change in merge authority.
The home owning the builder also owns this stage; a routed builder completion is not a review verdict, and a parent must obtain the owning home's verdict before presenting or merging the PR.

### Green checks before dispatch

Read the live PR head and its checks from the forge, and establish which project commands cover lint, typecheck, and tests from the project's existing configuration.
All applicable gates must have succeeded on that exact head before spending on a reviewer; a skipped, cancelled, missing, pending, or unreadable check is not green.
An absent typecheck or other genuinely inapplicable gate needs an explicit project-backed explanation, not an inferred pass.
Save the head, commands/check names, results, times, and evidence links in `data/<builder-id>/consigliere-gates-<round>.md`.
Wait on pending checks using the existing supervised checks path; do not launch a reviewer to diagnose a red build.
For red gates before the first review, send the builder one bounded correction naming the failed checks; record that allowance as spent before sending it, and escalate if the correction still leaves red gates.
Use the selected delivery path for the correction: an active no-mistakes run owns its fixes and publishing, while a direct-PR builder fixes and republishes.
Missing evidence is a blocker to resolve, not permission to waive a gate.

### Reviewer selection and launch

Inspect the actual builder model and provider family, not just its harness, using the task's resolved profile and that harness's authoritative model catalog; if actual execution differs, use the execution evidence.
Apply the configured review rule for its tier and model under the mapping in the configuration owner, and record the chosen model, family, and rule.
No matching rule, ambiguous builder identity, an unavailable mapped reviewer, or a default route that violates the map requires resolution before dispatch; never silently choose the builder again.
For a profile array load `quota-array-dispatch` and evaluate every candidate under its existing procedure.
The only same-family exceptions are the documented Opus and Fable independent-brief routes; record their grounds explicitly, including current Codex-pool evidence for the Opus exception.

File a linked review work item using the normal backlog contract, load `harness-adapters`, and scaffold `bin/fm-brief.sh <review-id> <project> --review` (preserving a non-default `--base-branch` where applicable).
Copy the builder's `## Captain's intent` body into the review's intent without inventing new acceptance criteria.
Fill its Firstmate spec with the full PR URL and exact head, the builder brief path, gate evidence path, surrounding code to inspect, concrete questions about requirements, correctness, regressions, and missing coverage for this diff, and a request to include reviewer model attribution in the envelope.
The reviewer starts from those sources; the builder's envelope is context and never the verdict.
For an independent-brief exception, make the check questions independent of the builder's rationale and identify the exception in the spec.
Run `bin/fm-dispatch-resolve.sh` on the completed brief under the normal dispatch contract and verify its chosen profile still satisfies the review rule before using it.
Launch through `bin/fm-spawn.sh <review-id> <project> --scout --harness <harness> --model <model> --effort <effort>` with the resolved backend and any base branch under existing dispatch rules; `--review` is a brief variant, not a spawn flag.
Preserve its read-only contract: the reviewer neither edits nor runs mutating checks, and writes only its report and authorized task records.

Before dispatch or sending a correction, persist the current head, round, stable review task ID, routing evidence, and consumed correction allowances in the builder's `data/<builder-id>/consigliere.json` with `verdict: "pending"`.
On restart reconcile that linked task and its report instead of launching a duplicate or resetting either allowance.
Use round 1 for the initial review and round 2 only for the one re-review after correction; the library header owns the clear receipt's required fields.

### Findings and bounded correction

Read the report itself, checking its envelope's head, evidence, actual reviewer model/family, findings, and blocker/major/minor counts; a worker's `done:` line alone cannot clear this stage.
If the head moved or evidence is incomplete, keep readiness pending and obtain a review of the current green head; this does not replenish correction allowances.
If round 1 has any blocker or major findings, send their IDs and evidence back to the builder in one bounded correction, preserve the report, and mark that allowance spent before sending.
After the builder republishes through its selected delivery path, require green gates for the new head, then dispatch the one re-review with the prior findings and corrected diff as additional context.
The re-review still checks the full current diff and requirements, including new regressions, and retains the mapped reviewer family.
If that correction fails its gates, the re-review retains any blocker/major, or another correction would be required, stop and present the concrete findings and PR URL for a captain decision; never loop or mark the PR ready.
Minor-only findings do not trigger a correction loop: include them in the verdict for the captain.
Load `captain-hold-lifecycle` and `scout-completion` for any unresolved captain call and the review report's completion; this review never authorizes an unrequested product change or bypasses an ask-user decision.

For a clear report, re-read the live head and gate results, then atomically replace `consigliere.json` with a supervisor-authored clear receipt retaining the round and consumed allowances, linking the report and gate evidence, and recording the verified model families and counts.
`bin/fm-consigliere-lib.sh` validates this attestation at PR-ready registration and again at merge for the live head; it does not infer a verdict or family from prose.
Do not write a clear receipt from the builder's self-review.
Return to the normal PR-ready handoff above only when the guard accepts that head.

### No-mistakes integration

Count the pipeline's own review only with evidence of the actual cross-family reviewer, the exact reviewed PR head, and green lint/typecheck/test results preceding that review.
Installed no-mistakes 1.75.2 has no per-run reviewer flag or environment override: repository `agent:` selects the general pipeline agent, while `review_agents.reviewer` is global-only.
Its normal review runs before tests and lint, so that native review does not satisfy this stage's ordering; launch the separate reviewer after green checks.
Do not rewrite shared global configuration, redirect `NM_HOME`, or change the repository's whole pipeline agent just to select this reviewer.
When verifying native attribution, locate the run database through `fm_nm_state_db` in `bin/fm-nm-run-lib.sh` and inspect `state.sqlite`'s `agent_invocations` for the run ID, `step_name=review`, `purpose=review`, round, agent, model, model_provider, exit_status, and timestamps.
An agent/harness name without actual model-family evidence is insufficient, and the current `fm-nm-run-lib.sh` run-state reader does not supply reviewer attribution.
Re-check installed help and source if no-mistakes adds a scoped reviewer selector; use such a selector only when it also satisfies the exact-head and gate-order requirements, and record that evidence rather than charging for a duplicate qualifying review.

## Landing and cleanup

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
