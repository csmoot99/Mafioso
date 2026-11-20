import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('/home/work/.no-mistakes/evidence/01M7TFTSQXYVXHZVS34WF8J2QB')
lab = Path(tempfile.mkdtemp(prefix='.nm-queue-live.', dir=ROOT))
log = (EVIDENCE / 'live-queue-cli.log').open('w')
results = []
env = dict(os.environ)
for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_GATE_REFUSE_BYPASS', 'FM_TEST_SEAM', 'FM_INTEGRATION_LEASE_FD', 'FM_INTEGRATION_BATCH'):
    env.pop(key, None)
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', FM_HOME=str(lab / 'home'), GIT_AUTHOR_NAME='Queue live check', GIT_AUTHOR_EMAIL='test@example.invalid', GIT_COMMITTER_NAME='Queue live check', GIT_COMMITTER_EMAIL='test@example.invalid')

def run(command, expected=0, contains=None):
    import shlex
    log.write('$ ' + shlex.join(map(str, command)) + '\n')
    p = subprocess.run(list(map(str, command)), env=env, text=True, capture_output=True, timeout=60)
    log.write(p.stdout)
    log.write(p.stderr)
    log.write('[exit ' + str(p.returncode) + ']\n\n')
    log.flush()
    assert (p.returncode == 0) if expected == 0 else (p.returncode != 0), p.stdout + p.stderr
    if contains:
        assert contains in p.stdout + p.stderr, p.stdout + p.stderr
    return p

try:
    run(['bash', ROOT / 'bin/fm-lab-home.sh', 'create', lab / 'home'])
    project, worker, remote = (lab / p for p in ('project', 'worker', 'origin.git'))
    run(['git', 'init', '-q', '--bare', remote])
    run(['git', 'init', '-q', '-b', 'main', project])
    run(['git', '-C', project, 'commit', '-q', '--allow-empty', '-m', 'isolated live queue base'])
    run(['git', '-C', project, 'remote', 'add', 'origin', remote])
    run(['git', '-C', project, 'push', '-q', 'origin', 'main'])
    run(['git', 'clone', '-q', '-b', 'main', remote, worker])
    head = run(['git', '-C', project, 'rev-parse', 'HEAD']).stdout.strip()
    entry = ['bash', ROOT / 'bin/fm-integration-queue.sh', '--project', project, '--base', 'main']
    initial = json.loads(run(entry + ['list']).stdout)
    assert initial['active'] is None and initial['components'] == []
    marker = lab / 'unexpected-command'
    p = run(entry + ['claim', '--workdir', worker, '--', 'touch', marker])
    assert p.stdout.strip() == 'null' and not marker.exists()
    results.append('Empty queue returns null without launching the integrator command')
    run(entry + ['claim', '--workdir', project, '--', 'true'], expected=1, contains='distinct isolated repository root')
    results.append('Integrator command refuses the primary project checkout')
    for action in (['record-result', '--tested-tree', head, '--reviewed-head', head, '--reason', 'unleased check'], ['release', '--reason', 'unleased check'], ['publish', '--task', 'integration', '--pr', 'https://github.com/csmoot99/Mafioso/pull/62']):
        run(entry + [*action, '--batch', 'a'*32], expected=1, contains='inherited live integrator lease')
    results.append('Result, release and publish all refuse calls without an inherited integrator lease')
    submit = ['submit', '--task', 'closed-check', '--pr', 'https://github.com/csmoot99/Mafioso/pull/62', '--head', head, '--reviewed-head', head, '--focused-head', head]
    mismatch = submit.copy()
    mismatch[mismatch.index('--reviewed-head')+1] = 'b'*40
    run(entry + mismatch, expected=1, contains='assertions must bind the exact head')
    nongithub = submit.copy()
    nongithub[nongithub.index('--pr')+1] = 'https://gitlab.com/example/game/-/merge_requests/1'
    run(entry + nongithub, expected=1, contains='canonical GitHub PR URLs only')
    results.append('Readiness refuses mismatched review assertions and unsupported forge URLs')
    run(['gh-axi', 'pr', 'list', '--repo', 'csmoot99/Mafioso', '--state', 'open', '--limit', '5'])
    p = run(['gh-axi', 'pr', 'view', '62', '--repo', 'csmoot99/Mafioso', '--fields', 'url,headRefOid,baseRefName,state,isDraft'], contains='MERGED')
    github_head = next(line.split(': ', 1)[1] for line in p.stdout.splitlines() if line.startswith('  headRefOid:'))
    real_submit = submit.copy()
    for field in ('--head', '--reviewed-head', '--focused-head'):
        real_submit[real_submit.index(field)+1] = github_head
    run(entry + real_submit, expected=1, contains='component PR identity, state or base changed: closed-check')
    results.append('Real GitHub merged PR is refused despite matching exact readiness assertions')
    run(['bash', ROOT / 'bin/fm-integration-queue.sh', '--account', 'closed-check', 'https://github.com/csmoot99/Mafioso/pull/62', 'attended', github_head], expected=1, contains='unproven accounting for task closed-check')
    results.append('Accounting checks the real merged head and refuses an unavailable task identity')
    resolve = ['resolve-accounting', '--batch', 'a'*32, '--task', 'closed-check', '--pr', 'https://github.com/csmoot99/Mafioso/pull/62', '--head', github_head, '--reason', 'negative check; no stopped batch']
    run(entry + resolve, expected=1, contains='--github-checked')
    run(entry + resolve + ['--github-checked'], expected=1, contains='active accounting-stopped batch')
    results.append('Manual resolve requires GitHub attestation and an active stopped batch')
    final = json.loads(run(entry + ['list']).stdout)
    assert final['active'] is None and not final['components'] and not final['accounting']
    assert head == run(['git', '-C', project, 'ls-remote', 'origin', 'refs/heads/main']).stdout.split()[0]
    run(['bash', ROOT / 'bin/fm-integration-queue.sh', '--help'], contains='resolve-accounting')
    log.write('Verified observations:\n' + '\n'.join(results) + '\n')
    (EVIDENCE / 'live-queue-results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('\n'.join(results))
finally:
    log.close()
    shutil.rmtree(lab)
