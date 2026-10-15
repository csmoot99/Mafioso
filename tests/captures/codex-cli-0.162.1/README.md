# Codex PostToolUse and session log captures

These files own a recorded Codex hook payload and session log excerpt for `test_codex_recorded_live_payload_marks_the_handoff_due_at_the_threshold` in `../../fm-context-handoff.test.sh`.
They were captured on 2026-10-14 with `codex-cli 0.162.1` and model `gpt-6-sol`, in phase 2 of live run-1792018316: an interactive crewmate pane launched with `--enable hooks --dangerously-bypass-hook-trust` and probe hooks as `-c hooks.<Event>=...` session flags.
They are replay inputs for the hook's reading of Codex's formats, not a live run of `bin/fm-context-handoff.sh` itself.

## Capture provenance

`posttooluse-payload.json` is the unchanged stdin of the run's fifth and last `PostToolUse` hook, for the shell call `printf 'phase two\n' >> README.md`.
Its `transcript_path` names the session's rollout log under `~/.codex/sessions`; the test points that one field at its own copy of the excerpt.

`rollout-excerpt.jsonl` holds unchanged records from that rollout log, ordinals 0 through 42, which end at the `item_completed` record of the same call (`tool_use_id` `exec-8272cb65-...`), so it is the log as it stood when the hook ran.
Records of 1000 bytes or more are left out: the session metadata, the base and project instructions, the environment snapshots, reasoning, and the three large `seq` outputs.
Its latest `token_count` reports `last_token_usage.total_tokens` 18183 and `model_context_window` 258400.

## What the run showed

- Every `PostToolUse` payload carried a `transcript_path` naming the rollout log, and that log held `event_msg` `token_count` records with `last_token_usage` and `model_context_window`.
- `PostToolUse` fired once for each of the five shell calls the worker made (run-1792024303 phase 2 also fired once for each of its four calls); the worker used no other tool, so `apply_patch` and MCP tools were not exercised.
- The first `PostToolUse` returned `hookSpecificOutput.additionalContext` asking for a file named `notice-d483cf4f06b0.txt`; ordinal 20 is that text arriving as a developer message tagged `hooks.additional_context`, and the worker's next call created the file.
- A response's `token_count` is written after its tool call completes and after that call's `PostToolUse` has run, so the hook reads the usage of the response before the current one.
