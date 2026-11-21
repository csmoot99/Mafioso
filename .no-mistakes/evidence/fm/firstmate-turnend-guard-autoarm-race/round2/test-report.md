# Focused test fix and completed live verification

Only tests/fm-claude-stop-autoarm.test.sh changes in this fix round. No runtime behavior changes.

The exact orphan replacement case failed before editing: three expected arms, four observed (orphan-before.log). Instrumentation of the executable fixture records pid, parent, and predecessor (orphan-trace.log). The original hook launched its handling successor before the replacement foreground arm began. The test's 250 x 20ms wait expired and unconditionally released the orphan's cycle before replacement startup finished. Thus the reported failure is a fixture ordering race exposed by startup latency, not an extra production arm after supersession.

The minimal correction increases the bounded readiness wait to 1500 x 20ms and records/asserts exactly two foreground launches before cycle release. Both replacement cases use that same ordering. The assertion is checked after releasing and waiting, so a failure still lets the orphan finish. Existing final arm count and ownership/output checks remain unchanged.

Reproduction and re-verification execute the existing named Bash test functions using temporary runners that retain their suite definitions. TMPDIR is task-local and FM_TEST_SKIP_ORPHAN_REAP=1 prevents cleanup of unrelated fixtures. The failing test and same-id resumed variant both passed after the fix (orphan-final.log). No full suite, linter, formatter, typechecker/static analysis, CI, push/PR, or pipeline-control command ran.

All five previously requested scenarios now have live product evidence:

1. Real Claude 2.1.330, real Stop hooks, real watcher, supervision-host-off, asyncRewake delayed three seconds: target guard rc=0, no blind warning, real actionable check delivered and handled (live-proof.json target).
2. Same target with asyncRewake registration omitted: guard rc=2 and TURN WOULD END BLIND delivered to Claude, no recovery epoch, check retired by real Claude (live-proof.json missing).
3. Same delayed handoff driven against the running base guard from 9e414d107ee7b463396146def893c21352ecd9a9: guard rc=2 and TURN WOULD END BLIND. All other shipped scripts and instrumentation match target. Target allows under the same three-second delay (live-proof.json baseline and target).
4. Real Claude's exact lab lock-holder process killed mid-cycle, preserving its live hook and real watcher. A second real Claude superseded epoch 1 with epoch 2, attached to the same watcher, and delivered exactly one wake. Orphan hook rc=0; replacement rc=2; real Claude handled the event. Persisted lifecycle records show exactly three arms: original started, replacement attached, handling successor started (orphan-live/final-state.json and orphan-driver.log).
5. Pi 1.6.0 launched as the real interactive product using supplied task-local dependencies. A serialized session restores ordinary and operational user rows; /calm hides only the operational row; restart/resume retains Calm; toggling off reveals it again. Saved real TUI captures and driver output are in pi-live/ and pi-driver.log. An initial test lab omitted the operational-input classifier script; the driver was corrected to point to the shipped classifier, then passed. This was lab setup, not a product change.

Every live lab and private tmux server was removed by driver cleanup; any remaining watcher was stopped only through its own lab-scoped public --stop interface. No broad watcher kill or supervision-host change occurred. Drivers are retained for reproduction; their original .phase-test output paths were temporary. No newly discovered unrelated deterministic product failure remains from these focused checks. Remote CI remains the outer executor's responsibility.

The existing test_hook_claude_mode_default_wait_covers_cycle_handoff also passed after the final test-only edit (guard-final.log). Final working tree cleanup retains only the intentional test-file change.
