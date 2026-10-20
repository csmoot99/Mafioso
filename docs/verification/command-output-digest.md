# Command-output digest measurement

This record measures how much of the paid Claude context that large tool results cost is command output a digest wrapper could shorten, and how much is file reads that must stay whole.

## 2026-10-20 measurement

### Method

The corpus was every top-level Claude Code transcript under `~/.claude/projects/*/*.jsonl` (1,819 files, 5.4 GB) on the supervising host, restricted to requests timestamped from 2026-09-20T00:00Z to 2026-10-20T14:00Z.
Sessions were assigned a kind of work by transcript directory: `-home-work-firstmate` is firstmate, `-home-work--no-mistakes-worktrees-*` is the no-mistakes pipeline, and `-home-work--treehouse-*` is ship and scout workers.
A throwaway Python script, run with `python3 -I` and not committed, read only these fields: record `type`, `subtype`, `timestamp`, `isSidechain`, `isMeta`, `message.id`, `message.model`, `message.usage`, each `tool_use` block's `name` and `id`, a Bash `tool_use` block's `input.run_in_background` and `input.command`, and each `tool_result` block's `tool_use_id`.
The Bash command string was reduced at once to its leading program and subcommand, such as `pnpm test`, `git diff`, `npx tsc`, or `cat`, and the rest of the string was discarded.
That reduction skips `cd`, `export`, assignments, loop headers, and wrappers such as `timeout` and `env`, drops a heredoc body, and passes over a leading program that prints little (`echo`, `pwd`, `test`, `mkdir`) to the next one, so `echo ---; cat x` reads as `cat`.
No tool output, prompt, or other message text was read, and nothing under the home's `data/` was opened.

Attribution is the per-request growth formula of the 2026-10-20 token-savings scout, for main-thread request i inside a compaction segment of n requests when the preceding user record is a tool result:

```text
size_i   = (in_i + cc_i + cr_i) - (in_{i-1} + cc_{i-1} + cr_{i-1}) - out_{i-1}
cost_i   = size_i * 1.25 * input_rate + size_i * (n - 1 - i) * cache_read_rate
saving_i = cost_i * (size_i - 800) / size_i
```

Rates per million tokens were input 10 and cache read 0.25 for Fable, input 4 and cache read 0.20 for Opus, input 2 and cache read 0.20 for Sonnet, and input 0.10 and cache read 0.01 for Haiku.
`saving_i` is the ceiling if that result had been digested to 800 tokens.
Dollars are weights for comparing shares, not billed amounts.

Parallel tool calls answer one request with several results, so one growth event can carry several tools.
An event whose tools share one category is assigned to it whole, an event mixing categories is its own "mixed batches" row, and inside an all-Bash event the commands share the event equally, which affects only the per-command split.

The totals reproduce the scout's: workers 9,279 events over 2,000 tokens costing $1,133 (the scout counted 9,278 and $1,133), firstmate 1,131 and $260, and the pipeline 4,485 and $232.

### Results over 2,000 tokens

"Saving" is the ceiling at 800 tokens, with its share of that kind's whole ceiling.
"Tests, lint, typecheck, build" is any Bash command whose leading program or subcommand is a test runner, linter, formatter, typechecker, or build tool, including `pnpm test`, `npx vitest`, `bash *.test.sh`, `bin/fm-lint.sh`, `tsc`, and `pnpm build`.
"Shell file views" are `cat`, `sed`, `head`, `tail`, `awk`, `nl`, `cut`, and `diff` used to print files.

| Result kind | Worker events | Worker cost | Worker saving | Firstmate events | Firstmate cost | Firstmate saving | Pipeline events | Pipeline cost | Pipeline saving |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| tests, lint, typecheck, build | 60 | $4 | $3 (0.4%) | 0 | $0 | $0 (0.0%) | 35 | $2 | $1 (0.6%) |
| git and grep/find/ls | 2,002 | $188 | $154 (15.8%) | 187 | $33 | $27 (12.1%) | 2,042 | $91 | $76 (38.8%) |
| other commands | 902 | $69 | $55 (5.6%) | 277 | $44 | $35 (15.3%) | 222 | $9 | $7 (3.7%) |
| shell file views | 4,842 | $605 | $520 (53.3%) | 276 | $50 | $41 (18.3%) | 1,827 | $92 | $76 (38.9%) |
| Read tool | 736 | $144 | $132 (13.5%) | 117 | $62 | $59 (26.2%) | 298 | $34 | $32 (16.4%) |
| mixed batches | 557 | $100 | $91 (9.3%) | 150 | $56 | $51 (22.6%) | 27 | $3 | $3 (1.3%) |
| other tools | 180 | $23 | $20 (2.1%) | 124 | $15 | $12 (5.5%) | 34 | $1 | $1 (0.3%) |
| all | 9,279 | $1,133 | $976 | 1,131 | $260 | $226 | 4,485 | $232 | $197 |

### Results over 5,000 tokens

| Result kind | Worker events | Worker cost | Worker saving | Firstmate events | Firstmate cost | Firstmate saving | Pipeline events | Pipeline cost | Pipeline saving |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| tests, lint, typecheck, build | 8 | $2 | $2 (0.3%) | 0 | $0 | $0 (0.0%) | 2 | $0 | $0 (0.2%) |
| git and grep/find/ls | 497 | $94 | $85 (12.4%) | 46 | $18 | $16 (9.8%) | 782 | $55 | $49 (38.2%) |
| other commands | 174 | $29 | $26 (3.8%) | 43 | $15 | $14 (8.5%) | 34 | $3 | $3 (2.0%) |
| shell file views | 1,624 | $391 | $360 (52.2%) | 81 | $28 | $25 (15.5%) | 533 | $49 | $45 (34.6%) |
| Read tool | 417 | $126 | $118 (17.1%) | 77 | $59 | $57 (35.0%) | 187 | $31 | $30 (23.3%) |
| mixed batches | 306 | $85 | $80 (11.5%) | 75 | $46 | $44 (27.1%) | 13 | $2 | $2 (1.8%) |
| other tools | 127 | $20 | $18 (2.7%) | 32 | $7 | $7 (4.1%) | 0 | $0 | $0 (0.0%) |
| all | 3,153 | $746 | $690 | 354 | $173 | $162 | 1,552 | $141 | $129 |

### Which commands dominate

Worker Bash results over 2,000 tokens, by attributable cost: `cat` $392, `sed` $201, `grep` $77, `ls` $27, `git diff` $20, `git rev-parse` $18, `wc` $17, `python3` heredoc scripts $9, `git show` $8.
`git rev-parse` leads mostly because the leading program of a compound command is counted, as in an isolation check followed by a file view.
Firstmate's largest are `sed` $29, `cat` $17, `grep` $14, `ls` $7, and its own `fm-wake-drain.sh`, `fm-pr-check.sh`, and `fm-tasks-axi.sh` at $5 to $6 each.
The pipeline's largest are `cat` $59, `git diff` $48, `sed` $32, `grep` $16, `git show` $9, and `git log` $8.

Test, lint, typecheck, and build commands are frequent but already small, as single-command worker results of every size show:

| Command group | Worker results | Median tokens | Over 2,000 | Over 5,000 | Run in background |
| --- | ---: | ---: | ---: | ---: | ---: |
| tests | 898 | 252 | 27 | 2 | 22 |
| lint | 445 | 252 | 15 | 3 | 2 |
| typecheck | 331 | 197 | 12 | 2 | 3 |
| build | 146 | 234 | 0 | 0 | 22 |
| git | 4,726 | 412 | 614 | 180 | 4 |
| grep/find/ls | 11,023 | 541 | 1,154 | 192 | 10 |
| shell file views | 13,796 | 1,181 | 4,384 | 1,308 | 10 |

### Reading

The command output a test, lint, typecheck, or build digest targets is 0.4 percent of the workers' over-2,000-token ceiling, about $3 of $976 a month, because workers already trim those outputs.
Adding long `git` and `grep`, `find`, or `ls` output raises the digestable ceiling to about $157 in workers (16 percent), $27 in firstmate, and $77 in the pipeline, before discounting the diffs and search hits a worker needs whole.
File reads are the majority: shell file views plus the Read tool are 67 percent of the workers' ceiling ($652), 44 percent of firstmate's, and 55 percent of the pipeline's, and a command digest must leave them whole.

### Limits

The leading-program reduction cannot see a file view that follows another command, so `git rev-parse` and other leading commands carry some file-view cost.
A shell file view of a saved log, such as a backgrounded command's output file, counts as a file view, because separating it needs the command's arguments, which were not read; at most 22 test and 22 build runs in workers were backgrounded in the window.
Mixed batches are not split by tool, so up to 9 percent of the workers' ceiling is unassigned.
