#!/usr/bin/env bash
# Exercise the public record writer with fixture transcripts and a private home.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WORK=$(fm_test_tmproot fm-attempt-record)
python3 - "$ROOT" "$WORK" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

root, work = map(Path, sys.argv[1:])
meta = work / 'task.meta'
data = work / 'data'
logs = root / 'tests/fixtures/attempt-usage'
base = ('worktree=/task/worktree\nharness=claude\nmodel=opus\neffort=high\n'
        'row=code\ntier=T1\nattempt_n=1\nattempt_id=first\n'
        'attempt_started_at=2026-10-22T19:01:00Z\n')
meta.write_text(base)
command = [sys.executable, str(root / 'bin/fm-attempt-record.py'), '--meta', str(meta),
           '--task-id', 'task', '--data', str(data), '--end', '2026-10-22T19:02:00Z',
           '--claude-root', str(logs / 'claude'), '--codex-root', str(logs / 'codex')]


def run(*extra):
    return subprocess.run([*command, *extra], capture_output=True, text=True)


def rows():
    return [json.loads(line) for line in (data / 'attempts.jsonl').read_text().splitlines()]


result = run()
assert result.returncode == 0, result.stderr
record, = rows()
assert record['input_tokens'] == 17 and record['output_tokens'] == 7
assert record['cache_read_tokens'] == 34 and record['cache_write_tokens'] == 4
assert record['context_peak'] == 33 and record['duration_s'] == 60
assert record['row'] == 'code' and record['tier'] == 'T1' and record['attempt_n'] == 1
assert record['gate_result'] is None and record['outcome'] is None
assert record['review_findings'] == dict(blocker=None, major=None, minor=None)
assert record['pool'] is None and record['prior_tier'] is None
assert record['fix_forward_7d'] is None and record['don_minutes'] is None and record['notes']
assert os.stat(data / 'attempts.jsonl').st_mode & 0o777 == 0o600
print('ok - replacement sessions sum into one classified private attempt; unavailable fields stay null')

# A cleanup retry retains the completed interval even if transcripts disappear.
before = (data / 'attempts.jsonl').read_bytes()
assert run('--end', '2026-10-23T00:00:00Z', '--claude-root', '/missing').returncode == 0
assert (data / 'attempts.jsonl').read_bytes() == before
print('ok - retries preserve exactly one record and its original end time')

meta.write_text(base.replace('attempt_id=first', 'attempt_id=second')
                .replace('attempt_n=1', 'attempt_n=2').replace('harness=claude', 'harness=codex'))
processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(4)]
for process in processes:
    _, error = process.communicate()
    assert process.returncode == 0, error
assert len(rows()) == 2
assert rows()[1]['input_tokens'] == 120 and rows()[1]['context_peak'] == 88
assert rows()[1]['attempt_n'] == 2
print('ok - concurrent retries serialize; distinct attempts remain distinct')

# An old task with no reliable start must not collect another occupant's logs.
meta.write_text('spawn_gen=legacy\nharness=claude\nworktree=/task/worktree\n')
assert run().returncode == 0
legacy = rows()[-1]
assert legacy['input_tokens'] is None and legacy['duration_s'] is None
assert legacy['attempt_n'] is None and any('start unavailable' in note for note in legacy['notes'])
assert run().returncode == 0 and len(rows()) == 3
print('ok - legacy metadata never invents a time boundary or duplicate retry')

meta.write_text(base.replace('attempt_id=first', 'attempt_id=unsupported').replace('harness=claude', 'harness=pi'))
assert run().returncode == 0
assert rows()[-1]['input_tokens'] is None
assert any('this harness' in note for note in rows()[-1]['notes'])
meta.write_text(base.replace('attempt_id=first', 'attempt_id=invalid'))
before = (data / 'attempts.jsonl').read_bytes()
assert run('--end', '2026-10-22T19:00:00Z').returncode != 0
assert (data / 'attempts.jsonl').read_bytes() == before
with (data / 'attempts.jsonl').open('a') as stream:
    stream.write('{partial')
before = (data / 'attempts.jsonl').read_bytes()
assert run().returncode != 0
assert (data / 'attempts.jsonl').read_bytes() == before
print('ok - unsupported harness remains unknown; invalid interval and corrupt ledger refuse safely')

blocked = work / 'not-a-directory'
blocked.write_text('preserve')
assert run('--data', str(blocked)).returncode != 0
assert blocked.read_text() == 'preserve'
print('ok - storage failure returns nonzero without destroying evidence')
PY
pass "attempt record writer"
