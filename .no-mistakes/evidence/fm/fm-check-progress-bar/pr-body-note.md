Live check-progress validation on `da5bdd72cd93227ec64cf69503d66453c2a17757` passed against `FM_HOME=/home/work/firstmate` while run `01M7RF315GNV72PXTS8QBDNV5Q` was in its test fix round. Two executions completed successfully. Checks collection took 0.255s against the 6s overall budget (2s/task); the measured full fleet snapshot took 13.36s. Commands ran with MemoryMax=6G and MemorySwapMax=0.

- `fm-check-progress-bar`: test, step 4/9, fix round, 602s elapsed, no percentage or estimate. Its elapsed time increased from 529s between snapshots.
- `superhero-game-concurrent-copies`: review, step 3/9, waiting on a decision, no percentage.
- `combined-business-test-fixture`: review, step 3/9, waiting on a decision, no percentage.
- `b2b-duress-cleanup-s4b2`: building, no checks row. No matching run was recorded for its task branch.

Read-only SQLite observations independently matched the projected steps and fixing/awaiting-approval states. Four live heavy waiting markers had empty task IDs, so no task queue state was inferred. No running counted-test or estimated-review/document state was present during observation; round 1's focused behavior and browser evidence covers those states. The checks budget is separate from total fleet snapshot latency.

The previously inconclusive live ingestion check resulted from inspecting `axi status` directly from an uninitialized gate worktree. The requested product command correctly read registered live tasks without initialization or pipeline control. No source fix was necessary. The snapshot's remote-summary cache was redirected to the worktree; the only intentional production-home write was the specifically requested `/home/work/firstmate/data/fm-check-progress-bar/live-snapshot.json`.
