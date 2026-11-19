#!/usr/bin/env bash
# Behavior tests through the queue executable, real local Git remotes, SQLite
# transitions and real OS locks. Forge and validation CLI reads are fixtures.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-integration-queue)
export ROOT TMP_ROOT
python3 - <<'PY'
import json
import os
from pathlib import Path
import signal
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ['ROOT'])
ENTRY = ROOT / 'bin/fm-integration-queue.sh'


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ['TMP_ROOT'])
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        for part in ('state', 'data', 'config'):
            (self.home / part).mkdir(parents=True)
        (self.home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
        self.project = self.root / 'project'
        self.worker = self.root / 'worker'
        self.remote = self.root / 'origin.git'
        self.fake = self.root / 'fakebin'
        self.fake.mkdir()
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_STATE_OVERRIDE=str(self.home / 'state'),
                        PATH=str(self.fake) + os.pathsep + os.environ['PATH'],
                        QUEUE_FORGE=str(self.root / 'forge.json'), QUEUE_ACTIVE=str(self.root / 'active'),
                        QUEUE_REMOTE=str(self.remote), QUEUE_REAL_GIT=shutil.which('git'),
                        QUEUE_MARKERS=str(self.root))
        self.forge = {}
        self.write_forge()
        self.tool('gh-axi', '''#!/usr/bin/env python3
import json, os, sys, subprocess, signal
from pathlib import Path
if sys.argv[1] == 'api':
    endpoint = sys.argv[2]
    if '/pulls/' in endpoint and sys.argv[-1] == '.head.ref':
        data = json.loads(json.load(open(os.environ['QUEUE_FORGE']))['https://github.com/' + endpoint[len('repos/'):].replace('/pulls/', '/pull/')])
        print(data['headRefName'])
    elif '/pulls/' in endpoint:
        owner_repo, number = endpoint[len('repos/'):].split('/pulls/')
        url = 'https://github.com/' + owner_repo + '/pull/' + number
        head = json.loads(json.load(open(os.environ['QUEUE_FORGE']))[url])['headRefOid']
        base = subprocess.check_output([os.environ['QUEUE_REAL_GIT'], '--git-dir=' + os.environ['QUEUE_REMOTE'], 'rev-parse', 'refs/heads/main'], text=True).strip()
        rc = subprocess.run([os.environ['QUEUE_REAL_GIT'], '--git-dir=' + os.environ['QUEUE_REMOTE'], 'merge-base', '--is-ancestor', head, base]).returncode
        markers = Path(os.environ['QUEUE_MARKERS'])
        blocked = markers / 'unproved-pr'
        if (markers / 'unproved').exists() or (blocked.exists() and blocked.read_text() == url): rc = 1
        crash = markers / 'crash-before-pr'
        if crash.exists() and crash.read_text() == url:
            crash.unlink()
            (markers / 'accounting-crashed').write_text(str(os.getppid()))
            os.kill(os.getppid(), signal.SIGKILL)
        print('fm-queue-merged' if rc == 0 else 'fm-queue-unproved')
    elif '/rules/branches/' in endpoint:
        print('fm-queue-requires-pr' if (Path(os.environ['QUEUE_MARKERS']) / 'requires-pr').exists() else 'fm-queue-no-pr-rule')
    elif '/branches/' in endpoint:
        print('fm-queue-unprotected')
    else:
        sys.exit('unexpected API')
    sys.exit(0)
url = 'https://github.com/' + sys.argv[5] + '/pull/' + sys.argv[3]
data = json.loads(json.load(open(os.environ['QUEUE_FORGE']))[url])
print('pull_request:')
for key, value in data.items():
    if key not in sys.argv[-1].split(','): continue
    print('  ' + key + ': ' + json.dumps(value))
''')
        self.tool('gh', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args[:2] == ['pr', 'merge']:
    url = 'https://github.com/' + args[args.index('--repo')+1] + '/pull/' + args[2]
    if os.environ.get('QUEUE_ORDINARY_PR') != url:
        sys.exit('ordinary merge must never be used by a batch')
    path = Path(os.environ['QUEUE_FORGE'])
    records = json.loads(path.read_text())
    data = json.loads(records[url])
    if args[args.index('--match-head-commit')+1] != data['headRefOid']:
        sys.exit('head mismatch')
    data['state'] = 'MERGED'
    records[url] = json.dumps(data)
    path.write_text(json.dumps(records))
    with (Path(os.environ['QUEUE_MARKERS']) / 'ordinary-merges').open('a') as log:
        log.write(url + '\\n')
    sys.exit(0)
if args[:2] == ['pr', 'view']:
    value = args[2]
    url = value if value.startswith('https:') else 'https://github.com/' + args[args.index('--repo')+1] + '/pull/' + value
    data = json.loads(json.load(open(os.environ['QUEUE_FORGE']))[url])
    if '-q' in args:
        print(data['headRefOid'])
    else:
        data.update(mergeable='MERGEABLE', mergeStateStatus='CLEAN', statusCheckRollup=[])
        if (Path(os.environ['QUEUE_MARKERS']) / 'red').exists():
            data['statusCheckRollup'] = [dict(__typename='CheckRun', name='ci', status='COMPLETED', conclusion='FAILURE')]
        print(json.dumps(data))
elif args[0] == 'api':
    if args[1] == 'graphql':
        fields = dict(arg.split('=', 1) for arg in args if arg.startswith(('owner=', 'repo=', 'number=')))
        url = 'https://github.com/' + fields['owner'] + '/' + fields['repo'] + '/pull/' + fields['number']
        data = json.loads(json.load(open(os.environ['QUEUE_FORGE']))[url])
        print('state=' + data['state'])
        print('merged=' + ('true' if data['state'] == 'MERGED' else 'false'))
        print('queued=false')
        print('base=' + data['baseRefName'])
    elif any('/rules/branches/' in a for a in args):
        print('[]')
    elif any('/branches/' in a for a in args):
        print('{"protected":false}')
    else:
        sys.exit('unexpected gh api ' + str(args))
else:
    sys.exit('unexpected gh ' + str(args))
''')
        self.tool('git', '''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if 'get-url' in args:
    print('https://github.com/example/game.git')
else:
    os.execv(os.environ['QUEUE_REAL_GIT'], [os.environ['QUEUE_REAL_GIT'], *args])
''')
        self.tool('no-mistakes', '''#!/usr/bin/env python3
import os
from pathlib import Path
p = Path(os.environ['QUEUE_ACTIVE'])
if p.exists():
    print(p.read_text())
else:
    print('error: repo not initialized')
''')
        self.cmd(['git', 'init', '-q', '--bare', str(self.remote)])
        self.cmd(['git', 'init', '-q', '-b', 'main', str(self.project)])
        self.git(self.project, 'commit', '-qm', 'initial', '--allow-empty')
        self.base = self.git(self.project, 'rev-parse', 'HEAD')
        self.git(self.project, 'remote', 'add', 'origin', str(self.remote))
        self.git(self.project, 'push', '-q', 'origin', 'main')
        self.cmd(['git', 'clone', '-q', '--branch', 'main', str(self.remote), str(self.worker)])

    def tearDown(self):
        self.tmp.cleanup()

    def cmd(self, command, check=True, env=None):
        result = subprocess.run(command, env=env or self.env, text=True,
                                capture_output=True, timeout=30)
        if check and result.returncode:
            self.fail(result.stderr + result.stdout)
        return result

    def git(self, directory, *args):
        return self.cmd(['git', '-C', str(directory), *args]).stdout.strip()

    def tool(self, name, source):
        path = self.fake / name
        path.write_text(source)
        path.chmod(0o755)

    def write_forge(self):
        (self.root / 'forge.json').write_text(json.dumps({k: json.dumps(v) for k, v in self.forge.items()}))

    def component(self, name, path=None, content=None, deps=(), parent=None):
        self.git(self.project, 'checkout', '-q', '-B', name, parent or self.base)
        file = self.project / (path or name)
        file.write_text(content or name)
        self.git(self.project, 'add', '.')
        self.git(self.project, 'commit', '-qm', name)
        head = self.git(self.project, 'rev-parse', 'HEAD')
        self.git(self.project, 'push', '-q', 'origin', name)
        url = 'https://github.com/example/game/pull/' + str(len(self.forge) + 1)
        self.forge[url] = dict(url=url, headRefOid=head, baseRefName='main', state='OPEN', isDraft=False)
        self.write_forge()
        (self.home / 'state' / (name + '.meta')).write_text(
            f'kind=ship\nmode=no-mistakes\nproject={self.project}\nbase_branch=main\npr={url}\nworktree={self.worker}\n')
        args = ['submit', '--task', name, '--pr', url, '--head', head,
                '--reviewed-head', head, '--focused-head', head]
        for dep in deps:
            args.extend(['--depends-on', dep])
        return name, head, url, args

    def argv(self, *args):
        return ['bash', str(ENTRY), '--project', str(self.project), '--base', 'main', *args]

    def queue(self, *args, check=True, env=None):
        return self.cmd(self.argv(*args), check=check, env=env)

    def submit(self, component):
        return self.queue(*component[3])

    def claim(self, command=':'):
        result = self.queue('claim', '--workdir', str(self.worker), '--', 'bash', '-c', command)
        return json.loads(result.stdout.splitlines()[0])

    def snapshot(self):
        return json.loads(self.queue('list').stdout)

    def integrator(self, action):
        # Child shell inherits the actual OS lease and exact batch identity.
        args = ' '.join([str(ENTRY), '--project', str(self.project), '--base main'])
        return 'bash ' + args + ' ' + action

    def test_singleton_starts_immediately_and_resumes_immutable_manifest(self):
        a = self.component('a')
        self.submit(a)
        one = self.claim()
        two = self.claim()
        self.assertEqual(one, two)
        self.assertEqual([c['head'] for c in one['components']], [a[1]])
        self.assertEqual(self.snapshot()['batches'][0]['status'], 'prepared')
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], self.base)

    def test_no_more_than_three_and_explicit_dependency_order(self):
        for i, dep in [('a', ()), ('b', ('a',)), ('c', ('b',)), ('d', ())]:
            self.submit(self.component(i, deps=dep, parent=dep[-1] if dep else None))
        manifest = self.claim()
        self.assertEqual([c['id'] for c in manifest['components']], ['a', 'b', 'c'])
        self.assertEqual(len(self.snapshot()['components']), 4)

    def test_submission_refuses_dependency_cycles(self):
        a = self.component('a')
        self.submit(a)
        self.submit(self.component('b', deps=('a',)))
        self.submit(self.component('c', deps=('b',)))
        result = self.queue(*a[3], '--depends-on', 'c', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('dependency cycle', result.stderr)
        manifest = self.claim()
        self.assertEqual([c['id'] for c in manifest['components']], ['a', 'b', 'c'])
        self.assertEqual(manifest['components'][0]['dependencies'], [])

    def test_external_base_movement_invalidates_instead_of_resuming(self):
        self.submit(self.component('a'))
        old = self.claim()
        self.git(self.project, 'checkout', '-q', 'main')
        (self.project / 'external').write_text('external')
        self.git(self.project, 'add', '.')
        self.git(self.project, 'commit', '-qm', 'external')
        self.git(self.project, 'push', '-q', 'origin', 'main')
        refusal = self.queue('claim', '--workdir', str(self.worker), '--', 'true', check=False)
        self.assertNotEqual(refusal.returncode, 0)
        self.assertIn('base moved externally', refusal.stderr)
        state = self.snapshot()
        self.assertIsNone(state['active'])
        self.assertEqual(state['batches'][0]['status'], 'invalidated')
        self.assertEqual(state['batches'][0]['manifest'], old)
        self.assertNotEqual(self.claim()['expected_base'], old['expected_base'])

    def test_changed_component_head_invalidates_then_quarantines(self):
        a = self.component('a')
        self.submit(a)
        old = self.claim()
        self.forge[a[2]]['headRefOid'] = 'a' * 40
        self.write_forge()
        refusal = self.queue('claim', '--workdir', str(self.worker), '--', 'true', check=False)
        self.assertNotEqual(refusal.returncode, 0)
        self.assertIn('head changed', refusal.stderr)
        self.assertIsNone(self.claim())
        state = self.snapshot()
        self.assertEqual(state['components'][0]['status'], 'stale')
        self.assertEqual(state['batches'][0]['manifest'], old)

    def test_conflict_is_rejected_and_unrelated_change_proceeds(self):
        self.submit(self.component('a', 'shared', 'first'))
        self.submit(self.component('b', 'shared', 'second'))
        self.submit(self.component('dependent', deps=('b',)))
        self.submit(self.component('independent'))
        manifest = self.claim()
        self.assertEqual([c['id'] for c in manifest['components']], ['a', 'independent'])
        state = {c['id']: c['status'] for c in self.snapshot()['components']}
        self.assertEqual(state['b'], 'conflict')
        self.assertEqual(state['dependent'], 'ready')

    def test_failed_component_and_dependents_drop_other_component_retries(self):
        for name, deps in [('a', ()), ('b', ()), ('c', ('b',))]:
            self.submit(self.component(name, deps=deps))
        command = self.integrator('record-result --batch "$FM_INTEGRATION_BATCH" --failed-component b --reason narrow-failure')
        failed = self.claim(command)
        state = self.snapshot()
        self.assertEqual(state['batches'][0]['status'], 'failed')
        self.assertEqual([c['status'] for c in state['components']], ['ready', 'failed', 'ready'])
        next_batch = self.claim()
        self.assertEqual([c['id'] for c in next_batch['components']], ['a'])
        self.assertNotEqual(next_batch['id'], failed['id'])

    def test_failed_dependency_keeps_transitive_dependents_queued(self):
        for name, deps in [('a', ()), ('b', ('a',)), ('c', ('b',))]:
            self.submit(self.component(name, deps=deps))
        command = self.integrator('record-result --batch "$FM_INTEGRATION_BATCH" --failed-component a --reason failure')
        self.claim(command)
        self.assertIsNone(self.claim())
        state = self.snapshot()
        self.assertIsNone(state['active'])
        self.assertEqual([c['status'] for c in state['components']], ['failed', 'ready', 'ready'])

    def test_active_legacy_run_refuses_and_unknown_state_refuses(self):
        self.submit(self.component('a'))
        (self.home / 'state/legacy.meta').write_text(
            f'kind=ship\nmode=no-mistakes\nproject={self.project}\nworktree={self.worker}\nbase_branch=main\n')
        (self.root / 'active').write_text('status: running\nbranch: main\nsteps[1]{name,status}:\n  rebase,completed\n')
        result = self.queue('claim', '--workdir', str(self.worker), '--', 'true', check=False)
        self.assertIn('active legacy validation', result.stderr)
        self.assertIsNone(self.snapshot()['active'])
        self.tool('gh', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args[:2] == ['pr', 'merge']:
    sys.exit('ordinary merge must never be used by a batch')
if args[:2] == ['pr', 'view']:
    value = args[2]
    url = value if value.startswith('https:') else 'https://github.com/' + args[args.index('--repo')+1] + '/pull/' + value
    data = json.loads(json.load(open(os.environ['QUEUE_FORGE']))[url])
    if '-q' in args:
        print(data['headRefOid'])
    else:
        data.update(mergeable='MERGEABLE', mergeStateStatus='CLEAN', statusCheckRollup=[])
        if (Path(os.environ['QUEUE_MARKERS']) / 'red').exists():
            data['statusCheckRollup'] = [dict(__typename='CheckRun', name='ci', status='COMPLETED', conclusion='FAILURE')]
        print(json.dumps(data))
elif args[0] == 'api':
    if any('/rules/branches/' in a for a in args):
        print('[]')
    elif any('/branches/' in a for a in args):
        print('{"protected":false}')
    else:
        sys.exit('unexpected gh api ' + str(args))
else:
    sys.exit('unexpected gh ' + str(args))
''')
        self.tool('git', '''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if 'get-url' in args:
    print('https://github.com/example/game.git')
else:
    os.execv(os.environ['QUEUE_REAL_GIT'], [os.environ['QUEUE_REAL_GIT'], *args])
''')
        self.tool('no-mistakes', '#!/usr/bin/env bash\nexit 1\n')
        result = self.queue('claim', '--workdir', str(self.worker), '--', 'true', check=False)
        self.assertIn('cannot be read', result.stderr)

    def test_live_lease_survives_parent_crash_and_releases_on_last_holder(self):
        self.submit(self.component('a'))
        marker = self.root / 'child-pid'
        command = f'echo $$ > {marker}; echo child-ready; exec sleep 60'
        process = subprocess.Popen(self.argv('claim', '--workdir', str(self.worker), '--', 'bash', '-c', command),
                                   env=self.env, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        try:
            manifest = json.loads(process.stdout.readline())
            self.assertEqual(process.stdout.readline().strip(), 'child-ready')
            # A second claim must refuse while the first command owns the FD.
            busy = self.queue('claim', '--workdir', str(self.worker), '--', 'true', check=False)
            self.assertIn('another integrator', busy.stderr)
            process.kill()
            process.wait(timeout=10)
            busy = self.queue('claim', '--workdir', str(self.worker), '--', 'true', check=False)
            self.assertIn('another integrator', busy.stderr)
        finally:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
            process.stdout.close()
            process.stderr.close()
        self.assertEqual(self.claim(), manifest)

    def test_result_requires_lease_and_exact_tree_and_head(self):
        self.submit(self.component('a'))
        manifest = self.claim()
        result = self.queue('release', '--batch', manifest['id'], '--reason', 'outside', check=False)
        self.assertIn('inherited live integrator lease', result.stderr)
        bad = self.integrator('record-result --batch "$FM_INTEGRATION_BATCH" --tested-tree ' + 'b' * 40 +
                              ' --reviewed-head "$FM_INTEGRATION_COMMIT" --reason wrong-tree')
        result = self.queue('claim', '--workdir', str(self.worker), '--', 'bash', '-c', bad, check=False)
        self.assertIn('must match manifest', result.stderr)
        good = self.integrator('record-result --batch "$FM_INTEGRATION_BATCH" --tested-tree ' + manifest['tree'] +
                               ' --reviewed-head "$FM_INTEGRATION_COMMIT" --reason full-baseline-and-final-review')
        self.claim(good)
        self.assertEqual(self.snapshot()['batches'][0]['status'], 'passed')
        refused = self.queue('publish', '--batch', manifest['id'], '--task', 'integration',
                             '--pr', 'https://github.com/example/game/pull/99', check=False)
        self.assertIn('inherited live integrator lease', refused.stderr)

    def test_release_requeues_and_primary_copy_command_refuses(self):
        self.submit(self.component('a'))
        result = self.queue('claim', '--workdir', str(self.project), '--', 'true', check=False)
        self.assertIn('distinct isolated repository', result.stderr)
        old = self.claim(self.integrator('release --batch "$FM_INTEGRATION_BATCH" --reason retry'))
        self.assertEqual(self.snapshot()['batches'][0]['status'], 'released')
        self.assertNotEqual(self.claim()['id'], old['id'])

    def test_owner_hold_and_unreadable_authority_refuse_submission(self):
        a = self.component('a')
        self.cmd(['bash', str(ROOT / 'bin/fm-captain-hold.sh'), 'hold', 'a',
                  '--title', 'component a', '--reason', 'owner decision'])
        result = self.queue(*a[3], check=False)
        self.assertIn('held for the owner', result.stderr)
        b = self.component('b')
        (self.home / 'state/.afk-contract').write_text('invalid')
        result = self.queue(*b[3], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot()['components'], [])

    def ready_publication(self, opt_in=True):
        self.submit(self.component('a'))
        self.submit(self.component('b'))
        manifest = self.claim()
        self.claim(self.integrator('record-result --batch "$FM_INTEGRATION_BATCH" --tested-tree ' + manifest['tree'] +
                                  ' --reviewed-head "$FM_INTEGRATION_COMMIT" --reason full-baseline-and-final-review'))
        url = 'https://github.com/example/game/pull/99'
        self.forge[url] = dict(url=url, headRefOid=manifest['commit'], baseRefName='main', state='OPEN', isDraft=False)
        self.forge[url]['headRefName'] = manifest['integration_branch']
        self.write_forge()
        (self.home / 'state/integration.meta').write_text(
            f'kind=ship\nmode=no-mistakes\nproject={self.project}\nbase_branch=main\npr={url}\nworktree={self.worker}\n')
        if opt_in:
            config = self.home / 'config/integration-queue-projects'
            config.write_text(str(self.project) + '\n')
            config.chmod(0o600)
        return manifest, self.integrator('publish --batch "$FM_INTEGRATION_BATCH" --task integration --pr ' + url)

    def publish_attempt(self, command):
        return self.queue('claim', '--workdir', str(self.worker), '--', 'bash', '-c', command, check=False)

    def test_publication_requires_opt_in_and_exact_full_result(self):
        manifest, command = self.ready_publication(opt_in=False)
        result = self.publish_attempt(command)
        self.assertIn('not opted in', result.stderr)
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], self.base)

    def test_guarded_fast_forward_accounts_all_prs(self):
        manifest, command = self.ready_publication()
        self.assertEqual(self.snapshot()['accounting'], [])
        hook = self.project / '.git/hooks/pre-push'
        hook.write_text('#!/bin/sh\necho chained > ' + str(self.root / 'hook-ran') + '\n')
        hook.chmod(0o700)
        result = self.publish_attempt(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], manifest['commit'])
        self.assertTrue((self.root / 'hook-ran').exists())
        self.assertEqual(self.snapshot()['batches'][0]['status'], 'landed')
        for task in ('a', 'b', 'integration'):
            self.assertTrue((self.home / 'state' / (task + '.pr-poll-merge-notified')).exists())
        self.assert_accounting(manifest, [True, True, True])

    def test_successor_registration_retires_landed_batch_binding(self):
        manifest, command = self.ready_publication()
        result = self.publish_attempt(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        meta = self.home / 'state/integration.meta'
        authority = self.home / 'state/integration.merge-authority'
        prior_authority = authority.read_bytes()
        successor = self.component('successor')
        self.cmd(['bash', str(ROOT / 'bin/fm-pr-check.sh'), 'integration', successor[2]])
        registered = dict(line.split('=', 1) for line in meta.read_text().splitlines())
        self.assertNotIn('integration_batch', registered)
        self.assertEqual(registered['pr'], successor[2])
        self.assertEqual(registered['pr_head'], successor[1])
        self.assertEqual(authority.read_bytes(), prior_authority)
        args = list(successor[3])
        args[args.index('--task') + 1] = 'integration'
        self.queue(*args)
        self.assertEqual([c['id'] for c in self.claim()['components']], ['integration'])

    def test_same_pr_retry_preserves_batch_binding(self):
        manifest, command = self.ready_publication()
        result = self.publish_attempt(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        url = 'https://github.com/example/game/pull/99'
        meta = self.home / 'state/integration.meta'
        authority = self.home / 'state/integration.merge-authority'
        prior_authority = authority.read_bytes()
        self.cmd(['bash', str(ROOT / 'bin/fm-pr-check.sh'), 'integration', url])
        registered = dict(line.split('=', 1) for line in meta.read_text().splitlines())
        self.assertEqual(registered['integration_batch'], manifest['id'])
        self.assertEqual(registered['pr'], url)
        self.assertEqual(authority.read_bytes(), prior_authority)
        for flags in ([], ['--integration-batch', 'e' * 32]):
            result = self.cmd(['bash', str(ROOT / 'bin/fm-pr-merge.sh'), 'integration', url, *flags], check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('must land through its bound queue batch', result.stderr)

    def test_direct_successor_merge_requires_exact_previous_merge_proof(self):
        manifest, command = self.ready_publication()
        result = self.publish_attempt(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        successor = self.component('successor')
        env = dict(self.env, QUEUE_ORDINARY_PR=successor[2])
        meta = self.home / 'state/integration.meta'
        original = meta.read_bytes()
        marker = self.home / 'state/integration.pr-poll-merge-notified'
        proof = marker.read_bytes()
        other_pr = proof.decode().splitlines()
        other_pr[-1] = successor[2].rsplit('/', 1)[1]
        for invalid in (None, b'unreadable', ('\n'.join(other_pr) + '\n').encode()):
            with self.subTest(proof=invalid):
                if invalid is None:
                    marker.unlink()
                else:
                    marker.write_bytes(invalid)
                    marker.chmod(0o600)
                for entry in ('fm-pr-check.sh', 'fm-pr-merge.sh'):
                    result = self.cmd(['bash', str(ROOT / 'bin' / entry), 'integration', successor[2]],
                                      check=False, env=env)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('is bound to', result.stderr)
                    self.assertEqual(meta.read_bytes(), original)
        self.assertFalse((self.root / 'ordinary-merges').exists())
        marker.write_bytes(proof)
        marker.chmod(0o600)
        result = self.cmd(['bash', str(ROOT / 'bin/fm-pr-merge.sh'), 'integration', successor[2]], env=env)
        self.assertIn('is merged', result.stdout)
        registered = dict(line.split('=', 1) for line in meta.read_text().splitlines())
        self.assertNotIn('integration_batch', registered)
        self.assertEqual(registered['pr'], successor[2])
        self.assertEqual(registered['pr_head'], successor[1])
        self.assertEqual((self.root / 'ordinary-merges').read_text().splitlines(), [successor[2]])
        authority = (self.home / 'state/integration.merge-authority').read_text().splitlines()
        self.assertEqual(authority[4], successor[2].rsplit('/', 1)[1])
        self.assertEqual(marker.read_text().splitlines()[4], authority[4])

    def test_unlanded_batch_cannot_replace_pr_identity(self):
        manifest, command = self.ready_publication()
        hook = self.remote / 'hooks/update'
        hook.write_text('#!/bin/sh\n[ "$1" != refs/heads/main ]\n')
        hook.chmod(0o700)
        self.assertNotEqual(self.publish_attempt(command).returncode, 0)
        meta = self.home / 'state/integration.meta'
        original = meta.read_bytes()
        successor = self.component('successor')
        for entry in ('fm-pr-check.sh', 'fm-pr-merge.sh'):
            result = self.cmd(['bash', str(ROOT / 'bin' / entry), 'integration', successor[2]], check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('is bound to', result.stderr)
            self.assertEqual(meta.read_bytes(), original)
        url = 'https://github.com/example/game/pull/99'
        self.cmd(['bash', str(ROOT / 'bin/fm-pr-check.sh'), 'integration', url])
        registered = dict(line.split('=', 1) for line in meta.read_text().splitlines())
        self.assertEqual(registered['integration_batch'], manifest['id'])

    def test_landed_dependency_allows_next_batch(self):
        manifest, command = self.ready_publication()
        self.submit(self.component('c', deps=('a',)))
        result = self.publish_attempt(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        next_batch = self.claim()
        self.assertEqual([c['id'] for c in next_batch['components']], ['c'])
        self.assertEqual(next_batch['expected_base'], manifest['commit'])

    def test_rejected_publication_can_resume_and_release(self):
        manifest, command = self.ready_publication()
        hook = self.remote / 'hooks/update'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o700)
        self.assertNotEqual(self.publish_attempt(command).returncode, 0)
        self.claim(self.integrator('release --batch "$FM_INTEGRATION_BATCH" --reason rejected-publication'))
        self.assertEqual(self.snapshot()['batches'][0]['status'], 'released')

    def test_crash_after_publication_recovers_all_outcomes(self):
        manifest, command = self.ready_publication()
        (self.root / 'unproved').touch()
        result = self.publish_attempt(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot()['batches'][0]['status'], 'publishing')
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], manifest['commit'])
        (self.root / 'unproved').unlink()
        self.assertIsNone(self.claim())
        self.assertEqual(self.snapshot()['batches'][0]['status'], 'landed')

    def assert_accounting(self, manifest, accounted):
        progress = self.snapshot()['accounting']
        components = [*manifest['components'], dict(id='integration', pr='https://github.com/example/game/pull/99',
                                                   head=manifest['commit'])]
        self.assertEqual(len(progress), len(components))
        for row, component, done in zip(progress, components, accounted):
            self.assertEqual((row['batch'], row['task'], row['pr'], row['head']),
                             (manifest['id'], component['id'], component['pr'], component['head']))
            self.assertIs(row['accounted'], done)
            self.assertIsInstance(row['at'], int)
            self.assertGreater(row['at'], 0)
        return progress

    def assert_merge_outcomes_once(self, components):
        rows = [line.split('\t', 4) for line in (self.home / 'state/.wake-queue').read_text().splitlines()]
        for component in components:
            key = 'merged-' + component['id'] + '-' + component['pr']
            self.assertEqual(sum(row[2] == 'check' and row[3] == key for row in rows), 1)

    def crash_between_components(self):
        manifest, command = self.ready_publication()
        first, second = manifest['components']
        (self.root / 'crash-before-pr').write_text(second['pr'])
        result = self.publish_attempt(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'accounting-crashed').exists())
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], manifest['commit'])
        self.assertEqual(self.snapshot()['batches'][0]['status'], 'publishing')
        self.assert_accounting(manifest, [True, False, False])
        self.assertFalse((self.home / 'state' / (second['id'] + '.pr-poll-merge-notified')).exists())
        self.assertFalse((self.home / 'state/integration.pr-poll-merge-notified').exists())
        return manifest

    def test_crash_between_components_resumes_without_double_accounting(self):
        manifest = self.crash_between_components()
        first = self.assert_accounting(manifest, [True, False, False])[0]
        marker = self.home / 'state' / (first['task'] + '.pr-poll-merge-notified')
        marker.unlink()
        self.assertIsNone(self.claim())
        self.assertIsNone(self.claim())
        self.assertEqual(self.snapshot()['batches'][0]['status'], 'landed')
        self.assertEqual(self.assert_accounting(manifest, [True, True, True])[0], first)
        self.assertFalse(marker.exists())
        self.assert_merge_outcomes_once([*manifest['components'],
                                        dict(id='integration', pr='https://github.com/example/game/pull/99')])

    def resume_after_successor(self, merge):
        manifest = self.crash_between_components()
        first = manifest['components'][0]
        completed = self.assert_accounting(manifest, [True, False, False])[0]
        successor = self.component('successor')
        self.cmd(['bash', str(ROOT / 'bin/fm-pr-check.sh'), first['id'], successor[2]])
        if merge:
            env = dict(self.env, QUEUE_ORDINARY_PR=successor[2])
            self.cmd(['bash', str(ROOT / 'bin/fm-pr-merge.sh'), first['id'], successor[2]], env=env)
        meta = self.home / 'state' / (first['id'] + '.meta')
        registered = meta.read_bytes()
        authority = self.home / 'state' / (first['id'] + '.merge-authority')
        prior_authority = authority.read_bytes()
        marker = self.home / 'state' / (first['id'] + '.pr-poll-merge-notified')
        notification = marker.read_bytes()
        expected_pr = successor[2] if merge else first['pr']
        self.assertEqual(notification.decode().splitlines()[4], expected_pr.rsplit('/', 1)[1])
        self.assertIsNone(self.claim())
        self.assertIsNone(self.claim())
        state = self.snapshot()
        self.assertIsNone(state['active'])
        self.assertEqual(state['batches'][0]['status'], 'landed')
        self.assertEqual(meta.read_bytes(), registered)
        self.assertEqual(authority.read_bytes(), prior_authority)
        self.assertEqual(marker.read_bytes(), notification)
        self.assertEqual(self.assert_accounting(manifest, [True, True, True])[0], completed)
        components = [*manifest['components'], dict(id='integration', pr='https://github.com/example/game/pull/99')]
        if merge:
            components.append(dict(id=first['id'], pr=successor[2]))
        self.assert_merge_outcomes_once(components)

    def test_partial_accounting_resumes_after_component_registers_successor(self):
        self.resume_after_successor(merge=False)

    def test_partial_accounting_resumes_after_component_merges_successor(self):
        self.resume_after_successor(merge=True)

    def test_protected_branch_rejection_has_no_fallback(self):
        manifest, command = self.ready_publication()
        hook = self.remote / 'hooks/update'
        hook.write_text('#!/bin/sh\necho "protected branch rejects direct publication" >&2\nexit 1\n')
        hook.chmod(0o700)
        result = self.publish_attempt(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('protected branch', result.stderr)
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], self.base)

    def test_required_pr_rule_refuses_before_pushing(self):
        manifest, command = self.ready_publication()
        (self.root / 'requires-pr').touch()
        result = self.publish_attempt(command)
        self.assertIn('branch rules require PR merges', result.stderr)
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], self.base)

    def test_base_moves_between_verification_and_push_advertisement(self):
        manifest, command = self.ready_publication()
        # The original pre-push hook changes the server after our advertised
        # old-base check. Receive-pack must still reject its compare-and-swap.
        self.git(self.project, 'checkout', '-q', 'main')
        self.git(self.project, 'commit', '-qm', 'external', '--allow-empty')
        external = self.git(self.project, 'rev-parse', 'HEAD')
        self.git(self.project, 'push', '-q', 'origin', 'HEAD:refs/heads/external')
        hook = self.project / '.git/hooks/pre-push'
        hook.write_text('#!/bin/sh\n' + self.env['QUEUE_REAL_GIT'] + ' --git-dir=' + str(self.remote) +
                        ' update-ref refs/heads/main ' + external + ' ' + self.base + '\n')
        hook.chmod(0o700)
        result = self.publish_attempt(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], external)

    def test_non_descendant_candidate_refuses(self):
        manifest, command = self.ready_publication()
        # Inject a malformed durable manifest as a recovery fixture. A new
        # immutable row preserves the schema's prohibition on rewriting one.
        objects = str(next((self.home / 'state/integration-queue').glob('*/objects')))
        env = dict(self.env, GIT_OBJECT_DIRECTORY=objects)
        detached = self.cmd(['git', '-C', str(self.project), 'commit-tree', manifest['tree'], '-m', 'unrelated'], env=env).stdout.strip()
        database = next((self.home / 'state/integration-queue').glob('*/queue.sqlite'))
        with sqlite3.connect(database) as db:
            malformed = dict(manifest, id='f' * 32, commit=detached)
            db.execute('INSERT INTO manifests VALUES(?,?)', (malformed['id'], json.dumps(malformed)))
            db.execute("INSERT INTO batches VALUES(?,'passed',?)", (malformed['id'], json.dumps(dict(tested_tree=malformed['tree'], reviewed_head=detached))))
            db.execute('UPDATE active SET batch=?', (malformed['id'],))
        result = self.publish_attempt(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], self.base)

    def test_live_red_checks_refuse_even_with_passed_batch(self):
        manifest, command = self.ready_publication()
        (self.root / 'red').touch()
        result = self.publish_attempt(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ci', result.stderr)
        self.assertEqual(self.git(self.project, 'ls-remote', 'origin', 'refs/heads/main').split()[0], self.base)


unittest.main(verbosity=2)
PY
