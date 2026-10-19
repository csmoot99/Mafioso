# Qwen Code

Alibaba's `qwen` TUI (`@qwen-code/qwen-code`, a Gemini CLI fork), verified end to end on 2026-10-13 with Qwen Code 0.25.1 on Linux against a local Ollama 0.40.3 server serving `qwen3-coder:30b`.
Launch shape: `QWEN_CODE_SYSTEM_SETTINGS_PATH=state/<id>.qwen-settings.json qwen -y -m <model> -i "$(cat <brief>)"`.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no qwen wake protocol.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Semantic `qwen-hook`, Claude-style event names: `UserPromptSubmit` opens a turn, `Stop` and `SessionEnd` close it. `UserPromptSubmit` fires TWICE per submitted prompt; the repeated busy event is idempotent. `Stop` does NOT fire on a manual Escape, so `../../../../../bin/fm-control.sh` invalidates the record to `unknown fm-interrupt` after an interrupt, as it does for Devin. |
| Rendered tail | Not a state source, but the running turn's status row is the one ASCII busy token: `(<n>s · esc to cancel)`, carrying `↓ <n> tokens` once output streams, absent when idle. The phase text beside it is model-generated and the spinner is a dot animation; neither is ever a signal. It is registered as qwen's delivery-only footer in `../../../../../bin/fm-composer-lib.sh`, which is what lets a submit be confirmed by the idle-to-busy transition. |
| Turn end | `Stop` fires once per turn after the final response. With managed auto-memory on, a post-turn memory update (`Updated 1 memory`) can follow and briefly re-open busy; the per-task settings file turns it off, and a pane is still settled only when the record, the footer, and the composer all agree. |
| Exit | `/quit` (alias `/exit`), one Enter, exit status 0; prints `To continue this session, run` / `qwen --resume <session-id>`. `SessionEnd` fires once. |
| Interrupt | Single `Escape`, then `Ctrl+U`. On a turn with streamed output Escape prints `●︎ Request cancelled.`, leaves the agent running, and RESTORES the cancelled prompt into the composer as `* <prompt>`, where the next typed line would concatenate onto it; `Ctrl+U` clears it and is harmless on an empty composer. An Escape that lands before any output streams withdraws the prompt from the transcript with no cancel notice. Escape on an idle composer does nothing. |
| Composer | A separated shape: one row between two `─` rules opening with a literal ASCII `*`, then the `Type your message or @path/to/file` placeholder as dark truecolor text. It classifies `empty` only through the tmux identity probe plus the ghost-stripped glyph row, and a typed draft is `pending`; `*` is never an agent glyph on its own. |
| Steering mid-turn | The running turn's footer reads `Enter to steer · Ctrl+Q to queue`: text submitted while a turn runs is consumed by that turn as a steer rather than opening a new one. |
| Skill | Workspace skills under `.agents/skills` load (a lab skill was listed in the init event's `slash_commands`); the `/<skill>` submit shape was not exercised and is unverified. |
| Autonomy | `-y` / `--yolo`, footer `YOLO mode (shift + tab to cycle)`, verified unattended on a real file write and a `git commit` shell call with no approval gate; `config/qwen-approval-mode` selects `--approval-mode auto` instead. qwen's own tool policy blocks a standalone `sleep` shell call (`Run blocking commands in the background`), so a long turn for a probe is generation, not a sleeping tool. |
| Marker | `QWEN_CODE_CLI=<absolute path to the package's cli-entry.js>` on child and tool processes, beside `QWEN_CODE_SESSION_ID`, `QWEN_CODE_PROJECT_DIR`, `QWEN_CODE_MODEL`, and `QWEN_CODE_STARTUP_VERSION`. A bare `1` is not the verified marker. `AI_AGENT` and an inherited `CLAUDECODE` are passed through unchanged. |
| Resume | `qwen -r <session-id>` (`--resume`) restores the transcript; with `-i '<prompt>'` it runs that prompt in the resumed session. `-c` continues the most recent session for the cwd. |
| Model | `-m` / `--model <model>`, from the dispatch profile. An OpenAI-compatible endpoint lists its models at `/v1/models`; the interactive `/model` dialog also switches. |
| Effort | None. `qwen --help` on 0.25.1 exposes no effort, reasoning, or thinking flag, so `references/common/model-and-effort.md`'s record-and-omit contract applies. |
| Attribution | The worker's commits carry `Co-authored-by: Qwen-Coder <qwen-coder@alibabacloud.com>`; the per-task git hooks path that `../../../../../bin/fm-git-strip-ai-trailers.sh` installs strips it at the commit object (verified: the worker's own commit carried no trailer). |

## Trust

qwen's folder-trust gate is OFF by default (`security.folderTrust.enabled`, `system ?? user ?? defaults ?? false`), and the system layer wins outright.
The per-task settings file the spawn writes therefore pins `security.folderTrust.enabled=false`, so a captain who turned trust on in `~/.qwen/settings.json` does not park every fresh worktree on the dialog.
With trust ON and an unknown folder, an interactive launch parks on `Do you trust this folder?` / `Trusting a folder allows Qwen Code to execute commands it suggests.` with `› 1. Trust folder (<name>)`, `2. Trust parent folder (<parent>)`, and `3. Don't trust (esc)` (the trusting choice is the default), and a headless launch silently downgrades: `Approval mode overridden to "default" because the current folder is not trusted.`
`../../../../../bin/fm-busy-lib.sh` recognizes that dialog as a parked launch.

A controlled headless A/B on one worktree carrying a workspace skill showed the alternative, `QWEN_CODE_TRUSTED_FOLDERS_PATH` pointed at a record naming the worktree, loads the same project hooks and skills as trust OFF does.
The setting was chosen because it needs no path registration and leaves no record of disposable worktree paths.
Trusting a folder interactively persists to `~/.qwen/trustedFolders.json`; the spawn never does.

## Credential precondition, and the cheapest probe

A qwen worker needs a credential it can use without a dialog, and firstmate does not manage one.
Auth resolves as `--auth-type`, else `security.auth.selectedType` from settings, else the environment: `OPENAI_API_KEY` together with `OPENAI_MODEL` (or `QWEN_MODEL`) and `OPENAI_BASE_URL` selects `openai`.
qwen reads `.env` files itself at startup (`<cwd>/.qwen/.env` or `<cwd>/.env` walking up to `$HOME`, then `~/.qwen/.env`, then `~/.env`), so unlike gemini's exported key this does not depend on when the session-provider daemon started.

The one-time setup for a local Ollama model is a three-line `~/.qwen/.env`:

```text
OPENAI_API_KEY=ollama
OPENAI_BASE_URL=http://127.0.0.1:11434/v1
OPENAI_MODEL=qwen3-coder:30b
```

The key is a placeholder Ollama ignores; no `settings.json` change is needed.
A user home holding exactly that file plus a `{"$version":4}` settings file ran a worker with no auth or onboarding dialog, which is what the live guard reproduces.
The cheapest pre-dispatch probe is headless:

```sh
qwen -o json 'say OK' | jq -r '.[] | select(.type == "result") | .subtype'
```

It prints `success` when configured and `error_during_execution` when not, with the message `No auth type is selected. Please configure an auth type (e.g. via settings or --auth-type) before running in non-interactive mode.`; the exit status is 0 either way, so read the JSON.
Credentials never ride the launch command, and a firstmate-owned settings file never carries them.

## Detection

`QWEN_CODE_CLI` is load-bearing rather than a fast path, so `../../../../../bin/fm-harness.sh` checks it right after `GEMINI_CLI` and BEFORE `CLAUDECODE`.
qwen does not clear an inherited `CLAUDECODE`, so a qwen worker under a claude primary carries both markers and whichever is tested first wins; the spawn additionally clears the foreign markers at the launch boundary.

Ancestry cannot cover the gap, for gemini's reason: the shipped CLI is a node bundle (`~/.local/bin/qwen` -> `@qwen-code/qwen-code/cli-entry.js`) and Node on Linux reports `comm` as `MainThread`, so no command-name arm matches a live qwen process.
`../../../../../bin/fm-qwen-lib.sh` owns the structural rule that identifies one from argv[1], the script argument, accepted only when it is named `qwen` or lives under `@qwen-code/qwen-code/`; it runs no subprocess.
The same rule backs pane liveness in `bin/backends/tmux.sh` and the composer identity probe in `bin/fm-tmux-lib.sh`, so a stranger's node pane is never reported as a live agent or a provable composer.
`../../../../../tests/fm-qwen-harness.test.sh` pins the marker precedence, the marker's required shape, and the ancestry boundary.

## Worker busy state and the per-task settings file

`../../../../../bin/fm-spawn.sh` writes a firstmate-owned per-task settings file at `state/<id>.qwen-settings.json` and the launch reaches it through `QWEN_CODE_SYSTEM_SETTINGS_PATH`.
It carries the three busy hooks bound to the minted busy generation, `"$version": 4`, `security.folderTrust.enabled=false`, `ui.enableFollowupSuggestions=false`, `ui.enableUserFeedback=false`, `memory.enableManagedAutoMemory=false`, and the two context-window pins described below.
Hook arrays merge across qwen's settings layers, so a project's own hooks still run alongside firstmate's.
This wiring belongs only to the canonical exact `qwen` adapter template; a raw qwen-shaped launch receives no busy-state wiring and has no trusted busy state.
It is deliberately NOT the worktree's `.qwen/settings.json`, which is the project's own file.
`../../../../../bin/fm-teardown.sh` removes the file.

Four settings exist because of observed hazards.
qwen rewrites any settings file that lacks `"$version"` into pretty-printed form at startup, including the system settings file, which is why the per-task file declares it (a project with no `.qwen/` directory is left untouched).
After a turn qwen can render a model-generated follow-up row (`* commit this`) in the composer position, where a composer read takes it for a draft.
After a turn with enough tool calls it can also open a session survey (`How is Qwen doing this session? (optional)`, `1: Good 2: Bad 3: Fine 0: Dismiss`) over the composer, where the next typed line is swallowed.
`memory.enableManagedAutoMemory` (default true on 0.25.1) gates both the post-turn extraction that writes `~/.qwen/memories` and the pre-turn recall that reads it, so pinning it false keeps every worker out of the captain's global memory in both directions; the captain chose off per task after the session audit found the extractor spending as many tokens as the main loop and a poisoned memory file steering later sessions.

## Context window on a local Ollama model

The captain's Ollama runs as the systemd user unit `ollama.service`, whose drop-in sets `OLLAMA_CONTEXT_LENGTH=65536 OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_FLASH_ATTENTION=1` (`systemctl --user show ollama -p Environment`), so the model's `llama-server` starts with `-c 65536 --context-shift --keep 4` (its launch line is in the journal under the `ollama` identifier).
The model still declares a 262144-token context length, and unpinned qwen auto-detects `contextWindowSize: 262144` from the model id, so it never compacts on its own.
Past the window the server does not refuse: it keeps the first 4 tokens, discards the next 32,765 (the system prompt, the brief, and the earliest reads), finishes against the remaining half, and answers 200; only its log says `slot context shift` and `truncated = 1`.
The next request re-sends the full history, so its cache hit is near zero, its time to first token is 17 to 20 s, and it shifts again as soon as output pushes it past the window.

The per-task settings file therefore pins `model.generationConfig.contextWindowSize=65536` (the served window) and `context.autoCompactThreshold=0.6`.
qwen compacts once its own estimate passes `min(threshold * window, window - 33000)` (a 20k summary reserve plus a 13k buffer), so at the pinned 65,536 the trigger is 32,536 and the threshold is inert; it becomes the active trigger if the window is raised above about 82,500.
A live session verified on 2026-10-18 that qwen compacts there and the server never shifts ([`runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#context-window-on-the-local-model)).
Changing the served window is the captain's call, sized to the card's memory, and firstmate never changes the service or the models; when it changes, the pin in `../../../../../bin/fm-spawn.sh` must change with it.

## Hazards seen in production launches

- **Brief prose is not followed; commands are.**
  A qwen worker on the standard brief skipped its branch step and every status append while following each concrete path and command, and wrote its module over the plan file the brief named by absolute path.
  Scaffold a qwen ship with `../../../../../bin/fm-brief.sh --harness qwen`, whose help owns that shape: the plan is inlined, the spawn creates the branch and refuses one that already exists, and the spawn makes every untracked file in a subdirectory of the home's `data/` that the brief names read-only for good, while top-level `data/` records, `state/`, `config/`, `projects/` and tracked files stay writable.
- **A pane read as dead may be a live TUI.**
  Before Herdr pane liveness recognized qwen (2026-10-15), a relaunch read a working qwen pane as dead and typed `cd -- '<worktree>'`, its `export` lines, and the launch-script line into qwen's idle composer.
  qwen ran the `cd` line as a prompt, executing the commit it had been describing on a detached HEAD, and took the rest as mid-turn steers.
  `fm-control.sh exit` and `relaunch` on a running qwen under Herdr still refuse, so stop a stuck one by its PID.
- **A formatter breaks qwen's edit guard.**
  `prettier --write` changes a file's mtime, after which qwen refuses `edit` and `write_file` on it with `file_changed_since_read` until the file is re-read.
  The qwen-shaped brief tells the worker to format once, after its last edit.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no qwen protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, steer, interrupt, exit, and resume.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
