---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay only its opening `## Envelope` section, record the report as the Done artifact, and re-evaluate the queue.
`bin/fm-brief.sh` owns the envelope's return fields and cap; stop reading at the next level-two heading rather than loading the full report or a worker transcript.
If the envelope is missing or does not answer a necessary question, dispatch a cheap T1 extraction scout through the normal intake and dispatch path, with that bounded question and the report or evidence paths and line ranges, not their contents.
Have that worker return the missing evidence in its envelope; firstmate never reads the transcript or full report to extract it itself.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
