# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Session-flag hooks on a crewmate or scout launch: `UserPromptSubmit` opens a turn, `Stop` and `SessionEnd` close it (source `codex-hook`), verified on codex-cli 0.162.1. Codex has no `StopFailure` hook and `Stop` on an Escape interrupt is unverified, so an interrupt leaves the record unknown. |
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
So crewmate and scout launches pass `--enable hooks --dangerously-bypass-hook-trust` (`../../../../../bin/fm-spawn.sh`'s launch template owns the flags), which runs the operator's and the project's hooks for that invocation only, the way a Claude worker runs its operator and project hooks, and writes no trust.
Codex resolves a worktree's project hooks from the main repository root, and Firstmate's own `.codex/hooks.json` hooks are primary-session infrastructure that stands down in a child worktree.
Firstmate's worker hooks ride the launch as `-c hooks.<Event>=...` session flags, so nothing is written into the worktree or `~/.codex`: busy state, the turn-end notification on `Stop`, and the opt-in context handoff.
The turn-end notification cannot use Codex's `notify` program, which on codex-cli 0.162.1 also fires for the TUI's side request that names the conversation, seconds into the turn.
Hooks run outside Codex's sandbox, as Claude hooks run outside Claude's permission check.
A secondmate is a primary in its own home and keeps its hooks without the bypass, so an unanswerable modal there is still possible and is the operator's own hook review to settle.

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
Under `config/worker-context-handoff` the compaction limit moves to the handoff's fallback ceiling (the flag file's `fallback-pct`), because Codex's `PreCompact` hook cannot block a compaction (exit 2 is reported as a failed hook and a block decision as invalid output); `../../../../../bin/fm-context-handoff.sh` owns that Codex mode.
By default the worker hands off at the launch-env share, below that ceiling; with the flag file's `codex-handoff-pct` line it compacts at the ceiling every time instead and hands off only if usage still reaches that higher share, as [Worker context handoff](../../../../../docs/configuration.md#worker-context-handoff-configworker-context-handoff) describes.
Each compaction writes a `compacted` record to the session log followed by a fresh `token_count` carrying the compacted context's size, before the next tool call (35 compactions across 21 session logs, codex-cli 0.162.1, 2026-10-21); the hook takes no usage from before the latest `compacted` record, so a successful compaction never triggers the later handoff from the usage that preceded it.
The notice path that replaces the block was observed live on codex-cli 0.162.1: every `PostToolUse` payload names the session log in `transcript_path`, that log carries the `token_count` usage the hook reads, the hook fired for every shell call a worker made, and its `additionalContext` reached the model as a developer message the worker then acted on.
[`../../../../../tests/captures/codex-cli-0.162.1/README.md`](../../../../../tests/captures/codex-cli-0.162.1/README.md) records that run, and its captured payload and log drive the hook in `../../../../../tests/fm-context-handoff.test.sh`.

## Project MCP servers

Verified on 2026-10-22 with codex-cli 0.162.1.
Crewmate and scout launches mirror the project's `.mcp.json` stdio servers into session-only `-c mcp_servers.<name>.*` overrides when its `.claude/settings.json` approves them through `enabledMcpjsonServers` or `enableAllProjectMcpServers`; `disabledMcpjsonServers` takes precedence.
Both files are read from the task's base commit, where the worker copy forked from origin's base branch, never from the working copy or the task branch, so a worker's edits to them change nothing on a fresh launch or a relaunch; when that commit cannot be resolved the launch mirrors no servers.
The launch preserves command, args and env, resolves a relative server `cwd` against the worker copy, and defaults an omitted `cwd` to that copy.
Invalid JSON or approvals, or an approved server it cannot express as stdio (another `type`, a missing command, a non-string argument or env value, a name outside `[A-Za-z0-9_-]`), refuses the launch rather than starting the worker without that server.
These project-declared processes run outside Codex's model-command sandbox under the project's approval; the launch does not persist them into the user's Codex configuration.
The server's own code still runs from the worker copy, so after a restart a worker's edits to a server script take effect, the same trust a Claude worker already gives its working copy.
[`fm-spawn.sh`](../../../../../bin/fm-spawn.sh)'s `codex_project_mcp_flags` owns the mapping and validation, with launch-argument regression coverage in [`fm-spawn-dispatch-profile.test.sh`](../../../../../tests/fm-spawn-dispatch-profile.test.sh).
A live `gpt-6-astra` proof replayed the complete captured launch flags through `codex mcp list --json` and `codex exec --ephemeral --json` against a real project worktree: Codex resolved the enabled `kg` stdio server, listed its eight tools, and completed `kg_stats` with a real index response.

## Remaining parity gaps

- No `StopFailure` hook closes a turn that ends in an API error, and `Stop` on an Escape interrupt is unverified.
- A handoff notice arrives on a tool call, and Codex writes a response's usage to the session log only after that response's tool call and its `PostToolUse` finish, so the notice comes one response after usage crosses the threshold; usage that jumps past the fallback ceiling in that span ends in one compaction, recorded as a missed handoff.
- `PostToolUse` was seen firing for shell calls only; delivery for `apply_patch` and MCP tool calls remains unverified.
- The status-file append, `git commit`, a push, `gh`, `no-mistakes`, and package installs run as reviewed escalations where a Claude worker's operator allowlist lets some of them through unreviewed.
- The automatic reviewer judges an escalation against what the worker was asked to do, so it approved a force push to `main` that a test prompt explicitly requested; the push guard rules below are the hard block for the pushes Firstmate never wants.

## Push guard rules

Codex refuses a command that matches a `forbidden` prefix rule from a `.rules` file in its config directory ("blocked by policy"), and loads no rules file from a session flag, so the guard is one machine-wide file that also binds the operator's own Codex sessions.
The rules live in [`codex-push-guard.rules`](codex-push-guard.rules) beside this reference, the one source of their content.
Install it from the repository root, and reinstall it the same way after it is lost or changed or after that file changes:

```sh
mkdir -p ~/.codex/rules && cp .agents/skills/harness-adapters/references/harness/codex-push-guard.rules ~/.codex/rules/firstmate-push-guard.rules
```

Nothing installs or checks it at launch, so a machine without the file runs Codex workers with no hard push block.

Codex validates each rule's `match` and `not_match` examples when it loads the file, so a broken rule fails loudly instead of silently matching nothing.
Check it without spending tokens, one command per form:

```sh
codex execpolicy check --rules ~/.codex/rules/firstmate-push-guard.rules git push --force origin fm/x
codex execpolicy check --rules ~/.codex/rules/firstmate-push-guard.rules git push origin fm/x
```

A forbidden form prints `"decision":"forbidden"` with the matched rule, and an ordinary `fm/` branch push prints `{"matchedRules":[]}`.
A session's load of the file shows in an app-server trace: under `RUST_LOG=codex_core::exec_policy=debug`, `codex app-server --listen stdio://` logs `loaded 1 .rules files in <home>/.codex/rules` when a client starts a thread.
Both checks were verified on codex-cli 0.162.1 on 2026-10-14; a live worker refusing a matching push was not run.
`../../../../../tests/fm-codex-push-guard-live-e2e.test.sh` runs the tracked file through `codex execpolicy check` for the force and `main` or `master` forms the rules cover and for ordinary `fm/` pushes, wherever Codex is installed, and skips elsewhere.

Prefix rules match whole argv words in order, so these push forms are not caught and still rely on the sandbox escalation and the automatic reviewer:

- A force flag after the refspec or after another flag (`git push origin fm/x --force`, `git push -q -f origin fm/x`), and `--force-with-lease=<ref>:<sha>`.
- A forced refspec other than `+HEAD` (`git push origin +fm/x`), and a local branch pushed onto the default branch (`git push origin fm/x:main`, `fm/x:refs/heads/main`).
- A remote other than `origin` or `upstream`, or a URL.
- A bare `git push` whose upstream is the default branch.
- Git options before `push` (`git -C <dir> push --force`, `git -c k=v push --force`), an absolute `/usr/bin/git`, an `env VAR=1` prefix, a git alias, or a script that pushes.
- A command with a redirection, substitution, environment assignment, or wildcard, which Codex's own permissions text says is not evaluated against rules at all, and a `bash -lc '...'` wrapper, which the check command does not unwrap.
- A ref update through another tool, such as the GitHub API.

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
