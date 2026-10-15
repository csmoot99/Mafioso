# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh\|max>"'`, verified on codex-cli 0.142.1 whose installed schema contains `model_reasoning_effort`. `max` is passed only when the selected model's entry in the catalog cache at `${CODEX_HOME:-~/.codex}/models_cache.json` advertises it, which every GPT-6 model does on codex-cli 0.162.1. |
| Model discovery | Open the current interactive session's `/model` picker. |
| Marker | None; identity comes from ancestry, and `../../../bin/fm-harness.sh` is what keeps a retained foreign `CLAUDECODE` from renaming it. Verified on 2026-09-01 with codex-cli 0.152.0: the pane process is the `node` npm shim and the native `codex` binary runs as its foreground child, so a tool subprocess reaches the native name directly while the shim itself is identified from its script path. |

A directory trust dialog appears on the first run for a repository root; on codex-cli 0.162.1 (verified 2026-10-14) it reads "Folder access ... Trust this folder?" with "1. Trust and continue" preselected, and from a worktree it notes that trust applies to the repository root.
Accept it with Enter and verify the instructions begin processing.
The decision persists for the repository root as a `[projects."<root>"]` `trust_level = "trusted"` entry in `~/.codex/config.toml`, so later worktrees of the same project skip it; a session-only `-c projects."<root>".trust_level="trusted"` override does not suppress the dialog.

## Hook trust

A second dialog, "Hooks need review - N hooks are new or changed", appears whenever the machine's `~/.codex/hooks.json` or a project's own `.codex/hooks.json` carries a hook Codex has not persisted trust for.
It is unanswerable rather than merely inconvenient: its selection starts on "Review hooks", which is neither trusting nor declining, and Firstmate's key plane carries Enter, Escape and Ctrl-C with no arrow navigation.
Writing Codex's own trust store to pre-accept it would manufacture an operator consent that was never given.
So crewmate and scout launches disable Codex's hook layer outright (`bin/fm-spawn.sh`'s launch template owns the flag), which is the opposite of `--dangerously-bypass-hook-trust` - that flag RUNS the untrusted hooks.
A crewmate loses nothing: its turn-end signal is the `-c notify=` program on the same launch, and the Firstmate hooks in a project's `.codex/hooks.json` are primary-session infrastructure that stands down in a child worktree.
A secondmate is a primary in its own home and keeps its hooks, so an unanswerable modal there is still possible and is the operator's own hook review to settle.

## Crewmate safety posture

Verified on 2026-10-14 with codex-cli 0.162.1.
A crewmate or scout runs under Codex's own safety layer, the counterpart of Claude's auto mode, never under `--dangerously-bypass-approvals-and-sandbox`; `../../../../../bin/fm-spawn.sh`'s launch template owns the exact keys.
Model shell commands run in the `workspace-write` sandbox: the worktree, `/tmp`, the task's steering inbox, and its data directory are writable, reads are unrestricted, and the network and unix sockets are blocked.
Anything else - a status-file append, `git commit` or `checkout -b` (they write the shared git common dir), a push, `gh`, `no-mistakes` (its daemon socket), a package install - needs a sandbox escalation, which goes to Codex's automatic approval reviewer (`approvals_reviewer="auto_review"`) instead of a pane prompt.
A denial comes back to the worker as a tool result, so no human ever answers a prompt in the pane.
A sandbox writable root must be a directory: naming a file makes every sandboxed command fail with a bwrap mount error, so the status file can never be granted directly.
`codex debug prompt-input` with the launch's `-c` flags renders exactly what the model is told, including the permissions block, at no token cost; `../../../../../tests/fm-codex-hook-layer-live-e2e.test.sh` replays the captured launch through it.
Codex ignores a misspelled or renamed `-c` key without an error, which is why that guard asserts the rendered result rather than the flags.

The launch also gives the worker what a Claude crewmate gets: the task-worker trust statement as `developer_instructions`, a project's instructions in full (Codex otherwise truncates `AGENTS.md` at 32 KiB), `CLAUDE.md` where a project has no `AGENTS.md`, and no startup update check.
It also compacts at the share of the window a Claude worker stops growing at: `model_auto_compact_token_limit` is an absolute token count, so the launch applies the `config/launch-env` threshold percentage to the selected model's effective window from the catalog cache, with the scope pinned to the full active context.

Parity gaps that remain with the hook layer off, because Codex treats every hook - a `-c` session-flag hook included - as untrusted until the operator trusts it, and ignores trust state passed with `-c`:

- No semantic busy state (no `userPromptSubmit`/`stop` hooks); the turn-end notify still fires.
- No context handoff: the worker compacts in place at the threshold instead of handing off to a fresh worker, because the handoff needs a `preCompact` hook to hold compaction.
- The operator's `~/.codex/hooks.json` and a project's `.codex/hooks.json` do not run, while a Claude crewmate runs the operator's and project's Claude hooks.
- A project's `.mcp.json` servers are Claude-only; Codex reads MCP servers only from its own config.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
In a home with `config/supervision-host` and no `config/supervision-host-off` the checkpoint runs the supervision host instead of the watcher, with Claude's print mode as its headless engine, and holds for at least an hour while away; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host and that bound.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
