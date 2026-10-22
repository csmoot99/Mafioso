# Live Haiku 80k cap lab (real tmux + real Claude Code worker, lab home /tmp/fmlab.kRfRyT/home at 7fa469d)

## Spawned Haiku worker hooks (.claude/settings.local.json)
precompact/posttooluse commands include --haiku-cap (see scenario output)

## Marker after live crossing (before replace)
v1 gen=g1792702149.2877227.11446 state=due seq=1 handoff=.../handoff-1.md key=context-handoff-1 usage=88354 pct=0 window=0 ceiling=80000 ceiling_pct=80 reclassify=T2 notices=1 calls=2 at=1792702170

## Status log
working [at=1792702164]: setup done, branch fm/lab5e546645fa53-worker created; reading reference/spawn.sh (6504 lines)
note [at=1792702170]: context handoff due: Haiku prompt usage 88354 crossed the 80000-token Haiku cap (including cache reads), so this T1 task was misclassified and must be reclassified to T2: replace it on the T2 route from config/crew-dispatch.json, never on Haiku; the worker was told to write /tmp/fmlab.kRfRyT/home/data/lab5e546645fa53-worker/handoff-1.md and report it with key context-handoff-1
blocked [key=context-handoff-1] [at=1792702194]: context handoff ready at /tmp/fmlab.kRfRyT/home/data/lab5e546645fa53-worker/handoff-1.md
resolved [key=context-handoff-1] [at=1792702222]: replaced the worker from context handoff /tmp/fmlab.kRfRyT/home/data/lab5e546645fa53-worker/handoff-1.md

## Meta after T2 replace
harness=claude
model=sonnet
effort=low
busy_gen=g1792702220.2898099.5187

## Replacement worker pane
 ▐▛███▛█   Claude Code v2.1.307
▝▜██████▀  Sonnet 5.5 with low effort · Claude Max
 ▝▝   ▝▝   /tmp/fmlab.kRfRyT/treehouse/.treehouse/notes-1ec8c7/1/notes · /rc
❯ : Firstmate operational input waiting: read '/tmp/fmlab.kRfRyT/home/state/operational-inbox/1792702221-e58bd143f3fa6db3.msg' and handle its contents as Firstmate operational input.
  Read 1 file, ran 1 shell command
● I have none of the file's content in this context, so I'll read all of it.
● Reading reference/spawn.sh
  ⎿  reference/spawn.sh
✢ Polishing… (23s · ↓ 827 tokens)
                                                                                                                         tmux detected · scroll with PgUp/PgDn · or add 'set -g mouse on' to ~/.tmux.conf for wheel scroll
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Sonnet 5.5 | ctx: 13% used
  ⏵⏵ auto mode on (shift+tab to cycle)
