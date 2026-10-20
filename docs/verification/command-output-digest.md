# Command-output digest measurement

This record measures how much of the paid Claude context that large tool results cost is command output a digest wrapper could shorten, and how much is file reads that must stay whole.

## 2026-10-20 measurement

### Method

The corpus was every top-level Claude Code transcript under `~/.claude/projects/*/*.jsonl` on the supervising host, 1,778 files with a request in the window, restricted to requests timestamped from 2026-09-20T00:00Z to 2026-10-20T14:00Z.
Sessions were assigned a kind of work by transcript directory: `-home-work-firstmate` is firstmate, `-home-work--no-mistakes-worktrees-*` is the no-mistakes pipeline, and `-home-work--treehouse-*` is ship and scout workers.
The script under Reproduction read only these fields: record `type`, `subtype`, `timestamp`, `isSidechain`, `isMeta`, whether a user record has a `toolUseResult` or `sourceToolAssistantUUID` key, `message.id`, `message.model`, `message.usage`, each `tool_use` block's `name` and `id`, a Bash `tool_use` block's `input.run_in_background` and `input.command`, and each `tool_result` block's `tool_use_id`.
Records timestamped at or after the window's end were skipped, so a session that ran past it counts only its in-window requests.
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
An event whose results all fall in one result kind is assigned to that row whole, and any other event, such as a `cat` batched with a `git diff`, is a "mixed batches" event, so each event is counted in exactly one row.
The per-command split under "Which commands dominate" instead shares an all-Bash event's cost equally among its commands.

The totals reproduce the scout's: workers 9,279 events over 2,000 tokens costing $1,132 (the scout counted 9,278 and $1,133), firstmate 1,131 and $260, and the pipeline 4,485 and $232.

### Results over 2,000 tokens

"Saving" is the ceiling at 800 tokens, with its share of that kind's whole ceiling.
"Tests, lint, typecheck, build" is any Bash command whose leading program or subcommand is a test runner, linter, formatter, typechecker, or build tool, including `pnpm test`, `npx vitest`, `bash *.test.sh`, `bin/fm-lint.sh`, `tsc`, and `pnpm build`.
"Shell file views" are `cat`, `sed`, `head`, `tail`, `awk`, `nl`, `cut`, and `diff` used to print files.

| Result kind | Worker events | Worker cost | Worker saving | Firstmate events | Firstmate cost | Firstmate saving | Pipeline events | Pipeline cost | Pipeline saving |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| tests, lint, typecheck, build | 54 | $4 | $3 (0.3%) | 0 | $0 | $0 (0.0%) | 27 | $1 | $1 (0.4%) |
| git and grep/find/ls | 1,821 | $157 | $126 (12.9%) | 151 | $24 | $19 (8.4%) | 1,972 | $85 | $71 (35.9%) |
| other commands | 816 | $56 | $44 (4.5%) | 238 | $34 | $26 (11.7%) | 211 | $9 | $7 (3.3%) |
| shell file views | 4,628 | $561 | $480 (49.1%) | 235 | $38 | $31 (13.8%) | 1,744 | $84 | $69 (34.9%) |
| Read tool | 736 | $144 | $132 (13.5%) | 117 | $62 | $59 (26.2%) | 298 | $34 | $32 (16.4%) |
| mixed batches | 1,041 | $187 | $171 (17.5%) | 263 | $86 | $77 (34.1%) | 199 | $19 | $17 (8.7%) |
| other tools | 183 | $23 | $21 (2.1%) | 127 | $16 | $13 (5.8%) | 34 | $1 | $1 (0.3%) |
| all | 9,279 | $1,132 | $976 | 1,131 | $260 | $226 | 4,485 | $232 | $197 |

### Results over 5,000 tokens

| Result kind | Worker events | Worker cost | Worker saving | Firstmate events | Firstmate cost | Firstmate saving | Pipeline events | Pipeline cost | Pipeline saving |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| tests, lint, typecheck, build | 7 | $2 | $2 (0.3%) | 0 | $0 | $0 (0.0%) | 0 | $0 | $0 (0.0%) |
| git and grep/find/ls | 398 | $69 | $62 (9.0%) | 33 | $11 | $10 (6.0%) | 738 | $49 | $45 (34.5%) |
| other commands | 126 | $18 | $16 (2.3%) | 32 | $10 | $9 (5.3%) | 33 | $2 | $2 (1.7%) |
| shell file views | 1,494 | $353 | $324 (47.0%) | 63 | $19 | $17 (10.7%) | 483 | $42 | $38 (29.2%) |
| Read tool | 417 | $126 | $118 (17.1%) | 77 | $59 | $57 (35.0%) | 187 | $31 | $30 (23.3%) |
| mixed batches | 582 | $159 | $149 (21.6%) | 115 | $66 | $62 (38.6%) | 111 | $16 | $15 (11.3%) |
| other tools | 129 | $20 | $19 (2.7%) | 34 | $8 | $7 (4.4%) | 0 | $0 | $0 (0.0%) |
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

The command output a test, lint, typecheck, or build digest targets is 0.3 percent of the workers' over-2,000-token ceiling, about $3 of $976 a month, because workers already trim those outputs.
Adding long `git` and `grep`, `find`, or `ls` output raises the digestable ceiling to about $129 in workers (13 percent), $19 in firstmate, and $72 in the pipeline, before discounting the diffs and search hits a worker needs whole.
File reads are the majority: shell file views plus the Read tool are 63 percent of the workers' ceiling ($612), 40 percent of firstmate's, and 51 percent of the pipeline's, and a command digest must leave them whole.

### Limits

The leading-program reduction cannot see a file view that follows another command, so `git rev-parse` and other leading commands carry some file-view cost.
A shell file view of a saved log, such as a backgrounded command's output file, counts as a file view, because separating it needs the command's arguments, which were not read; at most 22 test and 22 build runs in workers were backgrounded in the window.
Mixed batches are not split by result kind, so 17.5 percent of the workers' ceiling, 34.1 percent of firstmate's, and 8.7 percent of the pipeline's is unassigned.
A rerun reproduces these numbers only while the window's transcripts remain on the host, because Claude Code deletes transcripts older than its `cleanupPeriodDays` setting, 30 days by default.

## Reproduction

Run this from the repository root on the supervising host, as the user whose `~/.claude/projects` holds the fleet's transcripts.
It extracts the script below from this record and runs it; it prints the file count, both results tables, the leading commands, and the single-command table.

```bash
sed -n '/^```python$/,/^```$/{/^```/d;p}' docs/verification/command-output-digest.md | python3 -I -
```

```python
import glob
import json
import os
import re
import shlex
import statistics
from collections import defaultdict

ROOT = os.path.expanduser('~/.claude/projects')
START, END = '2026-09-20T00:00:00', '2026-10-20T14:00:00'
KINDS = ('worker', 'firstmate', 'pipeline')
# $ per million tokens: input, cache read; cache write is 1.25 x input.
RATES = {'fable': (10.0, 0.25), 'opus': (4.0, 0.20), 'sonnet': (2.0, 0.20), 'haiku': (0.10, 0.01)}


def rates(model):
    for k, v in RATES.items():
        if model and k in model:
            return v
    return None


def kind_of(d):
    if d == '-home-work-firstmate':
        return 'firstmate'
    if d.startswith('-home-work--no-mistakes-worktrees-'):
        return 'pipeline'
    if d.startswith('-home-work--treehouse-'):
        return 'worker'
    return None


SKIP_FIRST = {'done', 'fi', 'cd', 'export', 'set', 'pushd', 'popd', 'true', 'unset', 'source', '.', 'local', 'shopt', 'umask'}
WRAPPERS = {'timeout', 'env', 'time', 'nice', 'command', 'exec', 'xargs', 'stdbuf', 'nohup'}
SUB = {'git', 'npm', 'pnpm', 'yarn', 'npx', 'bun', 'bunx', 'cargo', 'go', 'gh', 'gh-axi', 'no-mistakes',
       'docker', 'make', 'uv', 'pip', 'pip3', 'treehouse', 'tasks-axi', 'quota-axi', 'chrome-devtools-axi',
       'lavish-axi', 'ollama', 'systemctl', 'herdr', 'tmux', 'kubectl', 'deno', 'turbo', 'nx', 'mix', 'poetry'}
INTERP = {'bash', 'sh', 'zsh', 'node', 'python', 'python3', 'tsx', 'ts-node', 'perl', 'ruby'}
# Programs that print little or nothing: when one leads a compound command the
# next program is the one whose output the result carries (echo ---; cat x).
QUIET = {'echo', 'printf', 'pwd', 'test', '[', '[[', 'read', 'sleep', 'date', 'mkdir', 'mv', 'rm', 'cp',
         'touch', 'which', 'true', 'false', ':', 'chmod', 'ln', 'trap', 'wait', 'exit', 'return', 'case', 'esac'}
LOOP = {'for', 'while', 'until', 'select'}


def script_name(tok):
    b = os.path.basename(tok)
    if b.endswith('.test.sh'):
        return '*.test.sh'
    if re.search(r'\.(test|spec)\.[cm]?[jt]sx?$', b):
        return '*.test.js'
    return b


def command_key(cmd):
    """Leading program and subcommand only; the rest of the string is dropped."""
    first = ''
    fallback = ''
    # A heredoc body is data, not commands: keep only the text before it.
    lines = cmd.split('\n')
    for n, line in enumerate(lines):
        if '<<' in line:
            cmd = '\n'.join(lines[:n + 1])
            break
    for seg in re.split(r'&&|\|\||;|\||\n|\(|\)|\{|\}', cmd):
        seg = seg.strip()
        if not seg or seg.startswith('#'):
            continue
        try:
            toks = shlex.split(seg, comments=True)
        except ValueError:
            toks = seg.split()
        while toks and (re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', toks[0]) or toks[0] in ('!', 'then', 'do', 'else', 'if', 'elif')):
            toks.pop(0)
        if not toks or toks[0] in SKIP_FIRST or toks[0] in LOOP:
            continue
        while toks and os.path.basename(toks[0]) in WRAPPERS:
            w = os.path.basename(toks.pop(0))
            while toks and (toks[0].startswith('-') or re.match(r'^[0-9.]+[smh]?$', toks[0]) or re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', toks[0])):
                opt = toks.pop(0)
                if w == 'env' and opt in ('-u', '-C') and toks:
                    toks.pop(0)
        if not toks:
            continue
        if os.path.basename(toks[0]) in QUIET:
            fallback = fallback or toks
            continue
        first = toks
        break
    first = first or fallback
    if not first:
        return '(none)'
    prog = os.path.basename(first[0])
    rest = first[1:]
    if prog in INTERP:
        while rest and rest[0].startswith('-'):
            if rest[0] in ('-c', '-e', '-m'):
                return prog + ' ' + rest[0] + ((' ' + rest[1]) if rest[0] == '-m' and len(rest) > 1 else '')
            rest = rest[1:]
        return prog + (' ' + script_name(rest[0]) if rest else '')
    if prog.endswith('.sh') or prog.endswith('.mjs') or prog.endswith('.py'):
        return script_name(prog)
    if prog in SUB:
        while rest and rest[0].startswith('-'):
            o = rest.pop(0)
            if o in ('-C', '-c', '--filter', '--prefix', '--dir', '-w', '--workspace', '-F') and rest:
                rest.pop(0)
        if not rest:
            return prog
        sub = rest[0]
        if prog in ('npm', 'pnpm', 'yarn', 'bun') and sub in ('run', 'exec', 'x', 'dlx') and len(rest) > 1:
            return f'{prog} {sub} {rest[1]}'
        if prog in ('npx', 'bunx'):
            return f'{prog} {sub}'
        if prog in ('gh', 'gh-axi', 'no-mistakes') and len(rest) > 1 and not rest[1].startswith('-'):
            return f'{prog} {sub} {rest[1]}'
        return f'{prog} {sub}'
    return prog


TEST = re.compile(r'(^| )(test|tests|vitest|jest|pytest|mocha|playwright|\*\.test\.(sh|js)|fm-test-run\.sh|test:[a-z:-]+|e2e)( |$)')
LINT = re.compile(r'(^| )(lint|eslint|prettier|shellcheck|fm-lint\.sh|ruff|biome|format|fmt|actionlint|stylelint|clippy)( |$)')
TYPE = re.compile(r'(^| )(tsc|typecheck|check-types|mypy|pyright|vue-tsc|svelte-check|tsc:check)( |$)')
BUILD = re.compile(r'(^| )(build|compile|bundle|vite|webpack|next|astro|esbuild)( |$)')
VIEW = {'cat', 'sed', 'head', 'tail', 'nl', 'less', 'more', 'awk', 'bat', 'cut', 'tr', 'column', 'xxd', 'od', 'strings', 'diff', 'cmp'}
SEARCH = {'grep', 'rg', 'egrep', 'fgrep', 'find', 'fd', 'ls', 'tree', 'wc', 'du', 'stat', 'file'}
GROUPS = ('tests', 'lint', 'typecheck', 'build', 'git', 'grep/find/ls', 'shell file views')


def command_group(key):
    prog = key.split(' ')[0]
    if TEST.search(key):
        return 'tests'
    if LINT.search(key):
        return 'lint'
    if TYPE.search(key):
        return 'typecheck'
    if BUILD.search(key) and prog != 'git':
        return 'build'
    if prog == 'git':
        return 'git'
    if prog in SEARCH:
        return 'grep/find/ls'
    if prog in VIEW:
        return 'shell file views'
    return 'other commands'


CMD_TOOLS = {'Bash', 'BashOutput', 'KillShell', 'Monitor', 'PowerShell'}
ROWS = ('tests, lint, typecheck, build', 'git and grep/find/ls', 'other commands', 'shell file views',
        'Read tool', 'mixed batches', 'other tools')


def row_of(name, key):
    if name in CMD_TOOLS:
        g = command_group(key or '(none)')
        if g in ('tests', 'lint', 'typecheck', 'build'):
            return ROWS[0]
        if g in ('git', 'grep/find/ls'):
            return ROWS[1]
        return g
    if name in ('Read', 'NotebookRead'):
        return 'Read tool'
    return 'other tools'


def ctx(u):
    return (u.get('input_tokens') or 0) + (u.get('cache_creation_input_tokens') or 0) + (u.get('cache_read_input_tokens') or 0)


def scan(path, kind, events):
    tools = {}          # tool_use id -> (name, command key, run in background)
    reqs = []           # one per main-thread request
    seen = {}
    pending = []        # tool_use ids answered since the last request
    last_user_tool = False
    segment = 0
    with open(path, 'rb') as fh:
        for raw in fh:
            try:
                r = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(r, dict) or (r.get('timestamp') or '') >= END:
                continue
            t = r.get('type')
            if t == 'system':
                if r.get('subtype') == 'compact_boundary':
                    segment += 1
                    pending, last_user_tool = [], False
                continue
            if r.get('isSidechain'):
                continue
            m = r.get('message')
            if not isinstance(m, dict):
                continue
            if t == 'assistant':
                for b in m.get('content') or []:
                    if isinstance(b, dict) and b.get('type') == 'tool_use':
                        name, key, bg = b.get('name'), None, False
                        if name == 'Bash':
                            inp = b.get('input') or {}
                            c = inp.get('command')
                            key = command_key(c) if isinstance(c, str) else '(none)'
                            bg = inp.get('run_in_background') is True
                        tools[b.get('id')] = (name, key, bg)
                mid, u = m.get('id'), m.get('usage') or {}
                if not mid or not u:
                    continue
                if mid in seen:
                    reqs[seen[mid]]['usage'] = u
                    continue
                seen[mid] = len(reqs)
                reqs.append({'ts': r.get('timestamp') or '', 'model': m.get('model'), 'usage': u, 'seg': segment,
                             'after_tool': last_user_tool, 'tools': pending})
                pending, last_user_tool = [], False
            elif t == 'user':
                if 'toolUseResult' in r or r.get('sourceToolAssistantUUID'):
                    if r.get('isMeta'):
                        continue
                    pending = pending + [b.get('tool_use_id') for b in m.get('content') or []
                                         if isinstance(b, dict) and b.get('type') == 'tool_result']
                    last_user_tool = True
                elif not r.get('isMeta'):
                    last_user_tool = False
    seg_n = defaultdict(int)
    for q in reqs:
        seg_n[q['seg']] += 1
    seg_i = defaultdict(int)
    prev = None
    for q in reqs:
        i = seg_i[q['seg']]
        seg_i[q['seg']] += 1
        if prev is not None and prev['seg'] == q['seg'] and q['after_tool'] and q['tools'] and q['ts'] >= START:
            size = ctx(q['usage']) - ctx(prev['usage']) - (prev['usage'].get('output_tokens') or 0)
            rt = rates(q['model'])
            if size > 0 and rt:
                cost = (size * rt[0] * 1.25 + size * (seg_n[q['seg']] - 1 - i) * rt[1]) / 1e6
                events.append((kind, size, cost, [tools.get(x, ('(unknown)', None, False)) for x in q['tools']]))
        prev = q
    return any(q['ts'] >= START for q in reqs)


def saving(e):
    return e[2] * (e[1] - 800) / e[1]


def main():
    events, files = [], 0
    for f in sorted(glob.glob(os.path.join(ROOT, '*', '*.jsonl'))):
        kind = kind_of(os.path.basename(os.path.dirname(f)))
        if kind:
            files += scan(f, kind, events)
    print(f'transcript files with a request in the window: {files:,}')

    for th in (2000, 5000):
        tab = {(k, r): [0, 0.0, 0.0] for k in KINDS for r in ROWS + ('all',)}
        for e in events:
            if e[1] <= th:
                continue
            rows = {row_of(n, k) for n, k, _ in e[3]}
            for r in (rows.pop() if len(rows) == 1 else 'mixed batches', 'all'):
                t = tab[e[0], r]
                t[0] += 1
                t[1] += e[2]
                t[2] += saving(e)
        print(f'\nResults over {th:,} tokens')
        for r in ROWS + ('all',):
            cells = []
            for k in KINDS:
                n, c, s = tab[k, r]
                share = '' if r == 'all' else f' ({100 * s / tab[k, "all"][2]:.1f}%)'
                cells += [f'{n:,}', f'${c:,.0f}', f'${s:,.0f}{share}']
            print('| ' + ' | '.join([r] + cells) + ' |')

    print('\nBash results over 2,000 tokens by leading command, attributable cost')
    for kind in KINDS:
        by = defaultdict(float)
        for e in events:
            if e[0] == kind and e[1] > 2000 and all(n in CMD_TOOLS for n, _, _ in e[3]):
                for _, k, _ in e[3]:
                    by[k or '(none)'] += e[2] / len(e[3])
        top = sorted(by.items(), key=lambda x: -x[1])[:12]
        print(f'{kind}: ' + ', '.join(f'{k} ${c:,.0f}' for k, c in top))

    print('\nSingle-command worker Bash results of every size')
    sizes, bg = defaultdict(list), defaultdict(int)
    for e in events:
        if e[0] == 'worker' and len(e[3]) == 1 and e[3][0][0] == 'Bash':
            g = command_group(e[3][0][1] or '(none)')
            sizes[g].append(e[1])
            bg[g] += e[3][0][2]
    for g in GROUPS:
        s = sizes[g]
        print(f'| {g} | {len(s):,} | {statistics.median(s):,.0f} | {sum(x > 2000 for x in s):,} | {sum(x > 5000 for x in s):,} | {bg[g]:,} |')


main()
```
