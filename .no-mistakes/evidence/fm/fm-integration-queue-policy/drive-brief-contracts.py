"""Drive real brief/promotion CLIs; generated Markdown is the public prompt contract."""
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
evidence = Path('/home/work/.no-mistakes/evidence/01M7VKR3HV925EC3NA45YYP7Z0')
lab = root / '.test-phase-tmp' / 'live-home'
env = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
for key in ('FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'TMUX', 'HERDR_SESSION', 'FM_TASK_ID'):
    env.pop(key, None)
env['FM_HOME'] = str(lab)
env['TMPDIR'] = str(root / '.test-phase-tmp')
policy = '''# Testing before handoff
Run focused tests during development and before validation; fix reproduced failures and rerun the affected checks.
Leave the full suite to the pipeline or assigned integrator; do not pre-run an identical full baseline merely to hand off.
Keep every task-specific test mandate and currently required gate unless firstmate explicitly supersedes it.'''
results = []
transcript = []

def run(script, *args, success=True):
    command = ['bash', str(root / 'bin' / script), *args]
    p = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    transcript.append('$ ' + ' '.join(command) + '\n' + p.stdout + f'[exit {p.returncode}]\n')
    assert (p.returncode == 0) == success, transcript[-1]
    return p.stdout

def brief(task):
    return lab / 'data' / task / 'brief.md'

def save(task, path, label):
    destination = evidence / (task + '-' + label)
    shutil.copyfile(path, destination)
    return destination.name

def record(name, files):
    results.append({'name': name, 'result': 'pass', 'live': True, 'evidence': files})

try:
    run('fm-lab-home.sh', 'create', str(lab))
    for mode in ('no-mistakes', 'direct-PR', 'local-only'):
        task = 'ship-' + mode
        run('fm-brief.sh', task, 'fixture-project', '--mode', mode)
        text = brief(task).read_text()
        assert text.count(policy) == 1
        assert f'Delivery contract: mode={mode}' in text
        assert 'Verify isolation before anything else.' in text
        assert '# Definition of done' in text
        if mode == 'no-mistakes':
            assert '--yes' in text and 'ask-user' in text
        record(f'{mode} scaffold emits focused-test policy with required gates and isolation', [save(task, brief(task), 'brief.md')])

    plan = lab / 'plan.md'
    plan.write_text('Update src/a.ts and src/a.test.ts.\n')
    run('fm-brief.sh', 'qwen', 'fixture-project', '--mode', 'direct-PR', '--harness', 'qwen', '--plan', str(plan), '--files', 'src/a.ts src/a.test.ts', '--done-command', 'make focused-test')
    text = brief('qwen').read_text()
    assert text.count(policy) == 1 and 'make focused-test' in text
    assert 'git rev-parse --show-toplevel' in text
    record('Compact Qwen plan scaffold retains focused policy and explicit done command', [save('qwen', brief('qwen'), 'brief.md')])

    combine = lab / 'combine.txt'
    combine.write_text('title Combine two reviewed changes\nbase ' + 'b' * 40 + '\nfold https://github.com/o/r/pull/11 pr11 ' + '1' * 40 + '\nfold https://github.com/o/r/pull/12 pr12 ' + '2' * 40 + '\n')
    run('fm-brief.sh', 'qwen-combine', 'fixture-project', '--mode', 'direct-PR', '--harness', 'qwen', '--combine', str(combine), '--done-command', 'make combined-test')
    text = brief('qwen-combine').read_text()
    assert text.count(policy) == 1
    assert 'pull/11' in text and 'pull/12' in text and 'publish' in text
    record('Compact Qwen integration scaffold emits testing policy beside exact fold instructions', [save('qwen-combine', brief('qwen-combine'), 'brief.md'), save('qwen-combine', lab / 'data/qwen-combine/combine.sh', 'combine.sh')])

    run('fm-brief.sh', 'no-mode', 'fixture-project', success=False)
    assert not brief('no-mode').exists()
    record('Missing delivery mode is refused without generating a worker brief', ['live-cli-transcript.log'])

    for mode in ('no-mistakes', 'direct-PR', 'local-only'):
        task = 'promoted-' + mode
        run('fm-brief.sh', task, 'fixture-project', '--scout')
        scout = brief(task).read_text()
        assert '# Testing before handoff' not in scout
        save(task, brief(task), 'scout-before.md')
        scout = scout.replace('{TASK}', 'Ship the investigated fix.').replace('{FIRSTMATE_SPEC}', 'Preserve the investigated behavior and all existing safety rules.')
        brief(task).write_text(scout)
        meta = lab / 'state' / (task + '.meta')
        meta.write_text(f'window=fm-{task}\nkind=scout\nworktree={root}\n')
        run('fm-promote.sh', task, '--mode', mode, '--yolo', 'off')
        instructions = lab / 'data' / task / 'ship-instructions.md'
        current = instructions.read_text()
        relaunch = brief(task).read_text()
        assert current.count(policy) == 1 and relaunch.count(policy) == 1
        assert relaunch.startswith(scout)
        assert 'kind=ship' in meta.read_text() and f'mode={mode}' in meta.read_text()
        assert 'Verify isolation before anything else.' in current
        assert '# Definition of done' in current
        assert 'Ship the investigated fix.' in current
        if mode == 'no-mistakes':
            assert '--yes' in current and 'ask-user' in current
        files = [save(task, instructions, 'ship-instructions.md'), save(task, brief(task), 'relaunch-brief.md'), save(task, meta, 'meta.txt')]
        record(f'Promote scout to {mode}: active and persisted relaunch contracts carry policy and preserve safety', files)
        prior = (brief(task).read_bytes(), meta.read_bytes(), instructions.read_bytes())
        run('fm-promote.sh', task, '--mode', mode, '--yolo', 'off', success=False)
        assert prior == (brief(task).read_bytes(), meta.read_bytes(), instructions.read_bytes())
        record(f'Repeated {mode} promotion refuses without changing the published contracts', ['live-cli-transcript.log'])

    run('fm-brief.sh', 'unfilled-scout', 'fixture-project', '--scout')
    meta = lab / 'state/unfilled-scout.meta'
    meta.write_text(f'window=fm-unfilled-scout\nkind=scout\nworktree={root}\n')
    before = brief('unfilled-scout').read_bytes()
    run('fm-promote.sh', 'unfilled-scout', '--mode', 'no-mistakes', '--yolo', 'off', success=False)
    assert 'kind=scout' in meta.read_text()
    assert before == brief('unfilled-scout').read_bytes()
    assert not (lab / 'data/unfilled-scout/ship-instructions.md').exists()
    record('Unfilled scout intent cannot be promoted or receive ship-policy output', ['live-cli-transcript.log'])

    task = 'policy-test-classification'
    (lab / 'state' / (task + '.meta')).write_text(f'project={root}\nkind=ship\n')
    run('fm-test-failure.sh', 'classify', task, '--test', 'test_qwen_shape_inlines_the_plan_and_keeps_the_contract', '--file', 'tests/fm-brief.test.sh', '--class', 'brittle', '--cause', 'Reproduced at base and target: global no-mistakes substring prohibition also matches absolute code/home paths inside the gate .no-mistakes worktree. Normalize emitted installation paths before checking instruction content.')
    for path in (lab / 'data/test-failures').glob('*.jsonl'):
        shutil.copyfile(path, evidence / 'failure-classification.jsonl')
finally:
    (evidence / 'live-cli-transcript.log').write_text('\n'.join(transcript))
    (evidence / 'live-scenarios.json').write_text(json.dumps(results, indent=2) + '\n')
    if lab.exists():
        shutil.rmtree(lab)
print(json.dumps(results, indent=2))
