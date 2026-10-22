#!/usr/bin/env bash
# Behavioral tests of the usage CLI, with small synthetic vendor log fixtures.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK=$(fm_test_tmproot fm-attempt-usage)
cp -R "$ROOT/tests/fixtures/attempt-usage" "$WORK/logs"
python3 - "$ROOT/bin/fm-attempt-usage.py" "$WORK/logs" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

cli, root = sys.argv[1], Path(sys.argv[2])


def run(harness, start='2026-10-22T19:01:00Z', end='2026-10-22T19:02:00Z', extra=()):
    command = [sys.executable, cli, '--harness', harness, '--worktree', '/task/worktree',
               '--start', start, '--end', end, '--claude-root', str(root / 'claude'),
               '--codex-root', str(root / 'codex'), *extra]
    return subprocess.run(command, capture_output=True, text=True)


def result(harness, **kwargs):
    process = run(harness, **kwargs)
    assert process.returncode == 0, process.stderr
    return json.loads(process.stdout)


def expect(actual, inputs, outputs, reads, writes, peak, sessions):
    expected = dict(input_tokens=inputs, output_tokens=outputs, cache_read_tokens=reads,
                    cache_write_tokens=writes, context_peak=peak, sessions=sessions)
    assert {k: actual[k] for k in expected} == expected, actual


expect(result('claude'), 17, 7, 34, 4, 33, 2)
assert result('claude')['notes'] == []
assert result('claude')['last_activity'] == 1792695700  # 19:01:40Z, latest in-window request
print('ok - Claude request ids deduplicate streaming and copies; subagents and replacement sessions sum')

expect(result('codex'), 120, 17, 60, 0, 88, 2)
assert result('codex')['notes'] == []
assert result('codex')['last_activity'] == 1792695710  # 19:01:50Z, latest in-window token_count
expect(result('codex', start='2026-10-22T19:01:15Z', end='2026-10-22T19:01:45Z'),
       40, 7, 40, 0, 54, 2)
expect(result('codex', start='2026-10-22T19:00:00Z'), 180, 27, 100, 0, 110, 2)
print('ok - Codex counter deltas exclude earlier tasks, repeated notifications and cached input; context uses last request')

# Duplicate rollout copies must not multiply usage.
(root / 'codex/copy.jsonl').write_bytes((root / 'codex/a.jsonl').read_bytes())
expect(result('codex'), 120, 17, 60, 0, 88, 2)
print('ok - duplicate Codex session ids and events counted once')

for harness in ('claude', 'codex'):
    empty = result(harness, start='2026-10-22T19:03:00Z', end='2026-10-22T19:04:00Z')
    expect(empty, None, None, None, None, None, 0)
    assert empty['notes'] and empty['last_activity'] is None
    assert run(harness, start='bad').returncode != 0
    assert run(harness, start='NaN').returncode != 0
    assert run(harness, start='2026-10-22T19:01:00').returncode != 0
    assert run(harness, end='2026-10-22T19:00:00Z').returncode != 0
    assert run(harness, extra=('--worktree', 'relative')).returncode != 0
    expect(result(harness, extra=('--worktree', '/task/worktree/child')),
           None, None, None, None, None, 0)
print('ok - exact cwd, half-open windows, missing usage and invalid arguments')

# Missing fields must remain unknown; a broken tail does not lose earlier data.
claude = root / 'claude/-task-worktree/session-b.jsonl'
rows = [json.loads(line) for line in claude.read_text().splitlines()]
del rows[0]['message']['usage']['cache_creation_input_tokens']
claude.write_text(''.join(json.dumps(row) + '\n' for row in rows) + '{broken tail\n')
unknown = result('claude')
expect(unknown, 17, 7, 34, None, None, 2)
assert any('Malformed' in note for note in unknown['notes'])
assert any('cache_write_tokens unavailable' in note for note in unknown['notes'])
print('ok - partial usage is explicitly unknown and malformed JSONL is noted')

# Counter resets use only the last request, not a negative or invented delta.
isolated = root / 'edge'
isolated.mkdir()
source = [json.loads(line) for line in (root / 'codex/b.jsonl').read_text().splitlines()]
source[2]['payload']['info']['total_token_usage'] = source[2]['payload']['info']['last_token_usage']
edge = isolated / 'edge.jsonl'
edge.write_text(''.join(json.dumps(row) + '\n' for row in source))
reset = result('codex', extra=('--codex-root', str(isolated)))
expect(reset, 40, 5, 10, 0, 33, 1)
assert any('reset' in note for note in reset['notes'])

# First in-window cumulative total with no baseline cannot include old usage.
source[0]['timestamp'] = '2026-10-22T18:00:00Z'
source = source[:2]
source[1]['payload']['info']['total_token_usage']['input_tokens'] = 900
edge.write_text(''.join(json.dumps(row) + '\n' for row in source))
unbounded = result('codex', extra=('--codex-root', str(isolated)))
expect(unbounded, 20, 3, 10, 0, 33, 1)
assert any('without a baseline' in note for note in unbounded['notes'])

del source[1]['payload']['info']['total_token_usage']
edge.write_text(''.join(json.dumps(row) + '\n' for row in source))
fallback = result('codex', extra=('--codex-root', str(isolated)))
expect(fallback, 20, 3, 10, 0, 33, 1)
assert any('counters missing' in note for note in fallback['notes'])
print('ok - reset, absent baseline and absent cumulative counters have explicit fallback notes')

del source[1]['payload']['info']['last_token_usage']['cache_write_input_tokens']
edge.write_text(''.join(json.dumps(row) + '\n' for row in source))
unknown = result('codex', extra=('--codex-root', str(isolated)))
assert unknown['cache_write_tokens'] is None
assert unknown['input_tokens'] == 20
assert any('cache_write_tokens unavailable' in note for note in unknown['notes'])
print('ok - older Codex logs without cache-write measurements remain unknown')

# A missing cumulative event followed by a good one must not charge it twice.
source = [json.loads(line) for line in (root / 'codex/b.jsonl').read_text().splitlines()]
del source[1]['payload']['info']['total_token_usage']
edge.write_text(''.join(json.dumps(row) + '\n' for row in source))
expect(result('codex', extra=('--codex-root', str(isolated))), 40, 5, 10, 0, 33, 1)

# Some logs supply only an overall cumulative total, with detailed last usage.
for row in source[1:]:
    info = row['payload']['info']
    info['total_token_usage'] = {'total_tokens': info.get('total_token_usage', {}).get('total_tokens', 33)}
edge.write_text(''.join(json.dumps(row) + '\n' for row in source))
expect(result('codex', extra=('--codex-root', str(isolated))), 40, 5, 10, 0, 33, 1)
print('ok - missing cumulative events or fields do not double-charge later counters or lose last usage')
PY
pass "attempt usage extraction fixtures"
