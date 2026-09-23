---
name: context-handoff
description: >-
  Agent-only procedure for the opt-in worker context handoff.
  A Claude worker loads it when a PostToolUse notice from bin/fm-context-handoff.sh names this skill: its context reached the handoff threshold, auto-compaction is being held off, and it must write a handoff document so a fresh worker can continue the same task.
  Firstmate loads its supervisor section on a `blocked [key=context-handoff-<n>]` status event, when a worker reports its context handoff ready, and replaces the worker with the one deterministic command there.
user-invocable: false
metadata:
  internal: true
---

# Context handoff

Adapted from Matt Pocock's `handoff` skill (`skills/productivity/handoff/SKILL.md` in <https://github.com/mattpocock/skills>, commit `d28dfdc39beadc3142a33359b5cfa4765dcbd0bc`, MIT licence), reshaped for a Firstmate worker whose replacement continues the same task in the same isolated copy with the same instructions file.
`bin/fm-context-handoff.sh` owns the hook mechanics, the durable records, and the replacement command; this skill owns what goes into the document and how the two sides act on it.

## Worker side: writing the handoff

You are here because a tool result carried a `FIRSTMATE CONTEXT HANDOFF` notice.
The notice names the exact handoff path, the status file, and the decision key; use those values verbatim.
Everything you know only from this conversation is about to be lost, and the next worker will treat your document as a contract, so a belief written as a fact becomes its false premise.

1. **Finish only the step in hand.**
   Start nothing new.
   Never hand off in the middle of a running validation call: if a `no-mistakes axi run` or `respond` is in flight, wait for it to return and reach the next point where no pipeline call is running before you write anything.
2. **Write the handoff to the exact path the notice named**, under `data/<task-id>/`, never to the OS temporary directory and never over an earlier `handoff-*.md` in that directory.
   A task can hand off more than once; each document gets its own number.
3. **Reference, do not restate.**
   The next worker has the same instructions file, the same isolated copy, and the same status log.
   Point at the instructions by path, at commits by SHA, at a PR or report by URL or path, and at a specification or plan by path; copy none of their content.
4. **Carry what only the conversation knows**, in this order:
   - Current state: where the task stands right now, in two or three sentences.
   - Done: what is complete, each with its commit SHA.
   - Uncommitted: every changed file not yet committed, file by file, and what the change is for.
   - Next steps: what remains, in the order to do it.
   - Decisions made and why: choices the next worker must not silently reverse.
   - Dead ends: approaches already tried that failed, and why, so they are not retried.
   - Open decisions and blockers: every `needs-decision` or `blocked` key still open in the status log, with what each waits on.
   - Unacknowledged inbox messages: any `state/<task-id>.inbox/*.msg` not yet moved to `handled/`, by number.
   - Tests that matter: the exact commands to re-run and what they proved last time.
5. **Separate verified from believed.**
   Keep a `## Verified` list of facts you established by running something, each with how, and a `## Unverified` list for anything you believe but did not check.
   Nothing unverified may appear as a plain statement elsewhere in the document.
6. **Suggested skills**: name each skill the next worker should load, with its path and the moment to load it.
7. **Redact secrets.**
   No API keys, tokens, passwords, or personal data, even when they appeared in a tool result.
8. **Report it and stop.**
   Append exactly the `blocked [key=context-handoff-<n>] [at=<epoch>]: context handoff ready at <path>` line the notice gave you to the status file the notice named, with `<epoch>` replaced by what `date +%s` prints.
   Then end your turn and wait.
   Do not keep working, do not run `/compact`, and do not exit: firstmate replaces you, and the replacement continues from the handoff.

## Supervisor side: replacing the worker

Load this section on the worker's `blocked [key=context-handoff-<n>]` handoff-ready event.
The replacement is automatic and never asked about; mention it in the next natural reply to the captain as a worker that handed over and continued.

Run exactly:

```sh
bin/fm-context-handoff.sh replace <task-id>
```

It checks that the named handoff exists, is non-empty, and belongs to the current worker incarnation, refuses with a precise message otherwise, and then drives `bin/fm-control.sh <task-id> relaunch` with a note telling the replacement to read the handoff first.
On success it appends the closing `resolved [key=context-handoff-<n>]` event itself, so the open record needs no separate `--resolve-key` steer.
A refusal is evidence: read its message, and if the worker reported ready before the file existed, steer it to write the file rather than relaunching around the refusal.
A `note: context handoff missed` event means the worker never wrote the handoff before the fallback ceiling and compacted instead; the task continues as before the flag existed, and the next threshold crossing tries again.
