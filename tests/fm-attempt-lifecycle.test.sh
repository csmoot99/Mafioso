#!/usr/bin/env bash
# Lifecycle attribution uses a small fixture with the installed no-mistakes schema.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WORK=$(fm_test_tmproot fm-attempt-lifecycle)
python3 - "$ROOT" "$WORK" <<'PY'
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

root, work = map(Path, sys.argv[1:])
repo = work / 'repo'
repo.mkdir()
for args in [('init', '-q'), ('-c', 'user.name=Test', '-c', 'user.email=test@example.test',
                            'commit', '-qm', 'fixture', '--allow-empty')]:
    subprocess.run(['git', '-C', str(repo), *args], check=True)
head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
nm = work / 'nm'
nm.mkdir()
conn = sqlite3.connect(nm / 'state.sqlite')
conn.executescript('''
CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE,
 upstream_url TEXT NOT NULL, fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main',
 created_at INTEGER NOT NULL);
CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, head_sha TEXT,
 status TEXT, ci_ready_at INTEGER, created_at INTEGER, updated_at INTEGER);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT,
 status TEXT, findings_json TEXT);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT, round INTEGER,
 findings_json TEXT, repair_published INTEGER);
CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT,
 purpose TEXT, model TEXT);
''')
conn.execute('INSERT INTO repos VALUES (?,?,?,?,?,?)',
             ('repo', str(repo), 'https://example.test/repo.git', None, 'main', 100))
conn.execute('INSERT INTO runs VALUES (?,?,?,?,?,?,?,?)',
             ('run', 'repo', 'task-branch', head, 'completed', 150, 110, 160))
conn.execute('INSERT INTO step_results VALUES (?,?,?,?,?)',
             ('review', 'run', 'review', 'completed', '{"findings":[]}'))
conn.execute('INSERT INTO agent_invocations VALUES (?,?,?,?,?)',
             ('reviewer', 'run', 'review', 'review', 'review-model'))
conn.commit()
state = work / 'state'
state.mkdir()
meta = state / 'task.meta'
data = work / 'data'
base = (f'worktree={repo}\nproject={repo}\nbranch=task-branch\nharness=pi\n'
        'model=old\ntier=T1\nattempt_n=1\nattempt_started_at=100\n')
command = [sys.executable, str(root / 'bin/fm-attempt-record.py'), '--meta', str(meta),
           '--task-id', 'task', '--data', str(data), '--end', '200']
env = dict(os.environ, NM_HOME=str(nm))


def run(identity, extra=(), trailer=''):
    meta.write_text(base + f'attempt_id={identity}\n' + trailer)
    result = subprocess.run([*command, *extra], env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    records = [json.loads(line) for line in (data / 'attempts.jsonl').read_text().splitlines()]
    return next((record for record in records if record['attempt_id'] == identity), None), result.stdout.strip()


record, _ = run('green')
assert record['gate_result'] == 'green' and record['outcome'] is None
assert record['review_model'] == 'review-model'
assert record['review_findings'] == dict(blocker=0, major=0, minor=0)
assert record['merged'] is None and record['nm_run_ids'] == ['run']
record, _ = run('reassigned', ['--worktree-reassigned'])
assert record['gate_result'] is None
assert record['review_model'] == 'review-model' and record['nm_run_ids'] == ['run']
assert record['input_tokens'] is None and record['context_peak'] is None
assert any('slot reassigned' in note and 'gate-head attribution skipped' in note for note in record['notes'])
# Use the public merge-receipt writer, rather than bypassing its validation.
meta.write_text(base + 'pr=https://github.com/example/project/pull/1\n')
subprocess.run(['bash', '-c', 'source "$1/bin/fm-pr-lib.sh"; '
                'fm_pr_poll_merge_mark_notified "$2" task github github.com example/project 1',
                'test', str(root), str(state)], check=True)
record, _ = run('merged', trailer='pr=https://github.com/example/project/pull/1\n')
assert record['merged'] is True and record['outcome'] is None
assert any('Acceptance awaits' in note for note in record['notes'])
record, _ = run('different-pr', trailer='pr=https://github.com/example/project/pull/2\n')
assert record['merged'] is None
print('ok - green review and exact merge receipt retain pending seven-day acceptance')

findings = json.dumps({'findings': [{'id': 'f1', 'severity': 'major'}]})
conn.execute('INSERT INTO step_rounds VALUES (?,?,?,?,?)', ('r1', 'review', 1, findings, 1))
conn.execute('INSERT INTO step_rounds VALUES (?,?,?,?,?)', ('r2', 'review', 2, findings, 0))
conn.commit()
record, _ = run('corrected')
assert record['review_findings'] == dict(blocker=0, major=1, minor=0)
assert record['outcome'] == 'corrected'
conn.execute('UPDATE step_rounds SET findings_json=?',
             (json.dumps({'findings': [{'id': 'f1', 'severity': 'error'}]}),))
conn.commit()
record, _ = run('native-labels')
assert record['review_findings'] == dict(blocker=None, major=None, minor=None)
assert any('not mapped' in note for note in record['notes'])
print('ok - repeated findings charge once; native severity labels are never guessed')

conn.execute('INSERT INTO step_results VALUES (?,?,?,?,?)', ('test', 'run', 'test', 'failed', None))
conn.execute("UPDATE runs SET status='failed', ci_ready_at=NULL")
conn.commit()
record, _ = run('failed')
assert record['gate_result'] == 'red' and record['outcome'] == 'failed'
# Other repos, branches and prior attempts cannot supply this attempt's results.
for column, value in [('branch', 'other'), ('created_at', 99), ('created_at', 200), ('repo_id', 'other')]:
    conn.execute(f'UPDATE runs SET {column}=?', (value,))
    conn.commit()
    record, _ = run(f'unrelated-{column}-{value}')
    assert record['gate_result'] is None and record['review_model'] is None
    conn.execute('UPDATE runs SET branch=?, created_at=?, repo_id=?', ('task-branch', 110, 'repo'))
    conn.commit()
conn.execute('UPDATE runs SET updated_at=201')
conn.commit()
record, _ = run('later-write')
assert record['gate_result'] is None and record['outcome'] is None
conn.execute('UPDATE runs SET updated_at=160, head_sha=?', ('0' * 40,))
conn.commit()
record, _ = run('wrong-head')
assert record['gate_result'] is None
print('ok - failures are explicit; unrelated runs and stale code cannot establish gates')

record, output = run('same-profile', ['--relaunch', 'pi', 'old', 'T1'])
assert record is None and output == ''
record, boundary = run('lateral', ['--relaunch', 'codex', 'sol', 'T1'])
assert record['outcome'] is None and boundary == record['ts']
assert any('Lateral switch at tier T1: pi/old -> codex/sol' in note for note in record['notes'])
record, retry = run('lateral', ['--end', '300', '--relaunch', 'pi', 'old', 'T1'])
assert retry == boundary
record, _ = run('tier-only', ['--relaunch', 'pi', 'old', 'T2'])
assert record['outcome'] == 'escalated'
record, _ = run('escalation', ['--relaunch', 'codex', 'astra', 'T4 Heavy'])
assert record['outcome'] == 'escalated'
assert 'outcome not established by lifecycle evidence.' not in record['notes']
record, _ = run('de-escalation', ['--relaunch', 'pi', 'old', 'T0'])
assert record['outcome'] is None and any('without a recorded rise' in note for note in record['notes'])
print('ok - only a tier rise escalates; lateral switches close with a note; retries share a durable boundary')
(data / 'attempts.jsonl').write_text('{partial')
meta.write_text(base + 'attempt_id=broken-ledger\n')
for relaunch, expected in [(['pi', 'new', 'T1'], '1970-01-01T00:03:20Z'), (['pi', 'old', 'T1'], '')]:
    result = subprocess.run([*command, '--relaunch', *relaunch], env=env, text=True, capture_output=True)
    assert result.returncode != 0 and result.stdout.strip() == expected, result
(data / 'attempts.jsonl').unlink()
print('ok - a failed record still gives a changed profile its own boundary')
conn.execute('UPDATE runs SET head_sha=?', (head,))
conn.execute("UPDATE step_results SET findings_json='[]' WHERE step_name='review'")
conn.commit()
record, _ = run('malformed-review')
assert record['review_findings'] == dict(blocker=None, major=None, minor=None)
assert any('schema unsupported' in note for note in record['notes'])
conn.execute('UPDATE step_results SET findings_json=? WHERE step_name=?', ('{"findings":[]}', 'review'))
conn.execute('DROP TABLE agent_invocations')
conn.commit()
record, _ = run('missing-schema')
assert record['review_model'] is None
assert any('schema unsupported' in note for note in record['notes'])
print('ok - malformed or unavailable optional review evidence stays unknown')
conn.close()
PY
pass "attempt lifecycle evidence"
