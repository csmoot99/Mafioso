# Targeted live validation

Target: 62e2e98b2fe2c0078dbd59ed66fb5f0ddfb97345. Base: 9e414d107ee7b463396146def893c21352ecd9a9.

All five live scenarios passed in this test phase. Product evidence is in claude-product-evidence.txt, live-proof.json, orphan-live/final-state.json, and pi-live/.

- Real Claude Code 2.1.330, supervision-host-off, one registered check, and real asyncRewake auto-arm delayed three seconds: first guard exit 0, no blind warning, real watcher wake delivered and handled, no block-budget file at finish.
- Same target with asyncRewake registration omitted: first guard exit 2 and TURN WOULD END BLIND delivered to Claude; no auto-arm epoch or watcher ledger. Claude retired the test check and completed.
- Counterfactual with only the guard replaced by the base version: the same three-second delay produces guard exit 2 and TURN WOULD END BLIND; target allows it. This reproduces the reported ordering failure through the real CLI.
- Original lab Claude killed by its exact lock-holder PID mid-cycle; replacement real Claude superseded epoch 1 with epoch 2, attached to the real watcher and delivered exactly one wake. Orphan hook exited 0, replacement exited 2. Lifecycle ledger records original, attached replacement, and handling successor. Real Claude handled the wake.
- Real Pi 1.6.0 TUI loaded the current Calm extension, rendered ordinary and operational user rows, toggled Calm, resumed its session with Calm retained, then revealed the operational row when toggled off. The supplied task-local Pi dependencies were used without installing anything.

The complete focused tests/fm-turnend-guard.test.sh and tests/fm-claude-stop-autoarm.test.sh suites both exited 0. The new default-wait handoff regression and both orphan replacement regression cases passed. Logs are in the parent evidence directory as guard-suite.log and autoarm-suite.log. FM_TEST_SKIP_ORPHAN_REAP=1 prevented unrelated fixture cleanup. No complete repository suite, linter, formatter, typechecker/static analysis, CI, push, PR, or pipeline-control command ran.

Live drivers use disposable primary copies of the current shipped scripts within the run worktree and marked lab homes. Three-second timing wrappers preserve hook payloads, exit status, and output. No arm or watcher is stubbed. Private tmux servers use nonzero 120x40 grids and are drained by repeated pane capture. All labs and private servers were removed; any remaining orphan-lab watcher was stopped only through that lab's public --stop interface. Final git status and diff were clean. No source change was needed.

Screenshots were omitted because the runtime change is CLI hook behavior and the Pi correction only changes a type annotation, without a visual-layout change. Product CLI transcripts, persisted lifecycle state, and actual Pi TUI captures are preserved. Remote CI and static checks remain owned by the outer executor's other phases.

Verdict: go for this test phase. No actionable findings remain.
