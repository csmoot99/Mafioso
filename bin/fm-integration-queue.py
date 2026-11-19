#!/usr/bin/env python3
"""Opt-in integration queue and guarded GitHub fast-forward publication.

CLI owner: this module's --help. Storage: <state>/integration-queue/<key>/,
where key hashes the canonical project path and base ref. Each SQLite database
has ready components, immutable manifests, mutable batch outcomes and an event
history. FULL-synchronous transactions publish each transition atomically.
Candidate objects live beside the database, never in the project clone.

`claim --workdir <isolated-copy> -- <command> ...` holds an exclusive flock on
lease for the command's lifetime. A competing claim refuses immediately. The
command inherits that descriptor and FM_INTEGRATION_{BATCH,MANIFEST,COMMIT,
OBJECTS,LEASE_FD}; shell children retain it, even if the original claimant dies.
Call record-result/release from that shell while the descriptor is inherited.
Do not background work or close the descriptor before the integrator finishes.
There is no stale-lock timer or break-lock operation. After all holders exit,
the next claim resumes the exact durable active manifest or invalidates it if
its base, heads or candidate objects changed. Each new batch starts immediately
with up to three dependency-ordered compatible components. Conflicts and stale
heads are recorded and excluded, as are their dependents; no auto-resolution.

Submission's reviewed-head and focused-head are explicit supervisor assertions
at the exact live PR head, not test receipts or proof of permission. Owner holds
and merge authority are read by the shell adapter using existing merge helpers.
No new merge grant, review waiver, test reuse or pipeline configuration exists.
This initial implementation supports GitHub component reads only; other forge
URLs refuse explicitly. All commands emit JSON, errors go to stderr.

After running the full baseline on the candidate in the isolated integrator
copy and reviewing that exact commit, record-result binds those assertions.
Publish additionally needs a separate integration task and non-draft PR at
that exact commit, on the intended integration_branch, with all source heads
included by ancestry. The supervisor publishes the integration branch/PR via
its existing delivery path; this tool never pushes a review branch. It invokes
fm-pr-merge, which retains its authority, owner-hold, review, exact-head and
live-green guards for the integration PR and all components. Waivers and
ordinary forge merge are unavailable for a batch. Projects must be explicitly
listed in the private config/integration-queue-projects (default empty).

A normal Git push chains the original pre-push hook and rejects any advertised
old base except expected_base. Receive-pack then atomically checks that old
value while updating the single ref. No force flag, fallback or bypass exists.
PR-only protection or unreadable rules refuse, and server rejection is final.
A durable publishing intent precedes that command. After interruption, claim
proves the exact candidate is an ancestor of the remote base and every folded
PR is merged at its recorded head before idempotent merge-outcome accounting.
If the base is still expected_base the same passed candidate may retry the
existing guards; any ambiguous publication remains recoverable, never guessed
landed or silently replaced. A changed component after publication leaves
accounting unproved rather than declaring its new commits landed.
Do not release or overwrite a publishing batch until its outcome is resolved.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import sys
import time
import tempfile
from urllib.parse import quote
import uuid


class Refused(Exception):
    pass


class HeadChanged(Refused):
    pass


def run(args, *, env=None, cwd=None):
    # Keep the OS lease alive in a publication child even if every Python or
    # shell parent dies. Recovery cannot start while that child may publish.
    inherited = (env or os.environ).get('FM_INTEGRATION_LEASE_FD')
    descriptors = (int(inherited),) if inherited else ()
    result = subprocess.run(args, text=True, capture_output=True, env=env,
                            cwd=cwd, timeout=60, check=False, pass_fds=descriptors)
    if result.returncode:
        raise Refused(result.stderr.strip() or result.stdout.strip() or str(args))
    return result.stdout.strip()


def git(repo, *args, env=None):
    return run(['git', '-C', str(repo), *args], env=env)


def oid(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', value):
        raise Refused('an exact full object id is required')
    return value


def private_dir(path):
    if path.is_symlink():
        raise Refused('queue directory must not be a symlink')
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise Refused('queue directory must be owned and not writable by others')


def regular(path):
    if path.is_symlink():
        raise Refused('queue file must not be a symlink')
    if path.exists():
        info = path.stat()
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise Refused('queue file must be a private owned regular file')


class Queue:
    def __init__(self, args):
        self.args = args
        self.project = str(Path(args.project).resolve(strict=True))
        git(self.project, 'check-ref-format', 'refs/heads/' + args.base)
        state = Path(os.environ.get('FM_STATE_OVERRIDE',
                                    str(Path(os.environ['FM_HOME']) / 'state')))
        if not state.is_absolute() or state.is_symlink() or not state.is_dir():
            raise Refused('an existing absolute state directory is required')
        key = hashlib.sha256(json.dumps([self.project, args.base]).encode()).hexdigest()
        private_dir(state / 'integration-queue')
        self.root = state / 'integration-queue' / key
        private_dir(self.root)
        regular(self.root / 'queue.sqlite')
        regular(self.root / 'lease')
        self.db = sqlite3.connect(self.root / 'queue.sqlite', timeout=10,
                                  isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS components (
                id TEXT PRIMARY KEY, data TEXT NOT NULL, status TEXT NOT NULL,
                position INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS manifests (
                id TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TRIGGER IF NOT EXISTS immutable_update BEFORE UPDATE ON manifests
                BEGIN SELECT RAISE(ABORT, 'immutable manifest'); END;
            CREATE TRIGGER IF NOT EXISTS immutable_delete BEFORE DELETE ON manifests
                BEGIN SELECT RAISE(ABORT, 'immutable manifest'); END;
            CREATE TABLE IF NOT EXISTS batches (
                id TEXT PRIMARY KEY, status TEXT NOT NULL, result TEXT);
            CREATE TABLE IF NOT EXISTS active (id TEXT PRIMARY KEY CHECK (id='active'), batch TEXT);
            INSERT OR IGNORE INTO active VALUES ('active', NULL);
            CREATE TABLE IF NOT EXISTS events (
                seq INTEGER PRIMARY KEY, at INTEGER NOT NULL, kind TEXT NOT NULL, data TEXT NOT NULL);
        ''')
        self.shell = str(Path(__file__).with_suffix('.sh'))

    @contextlib.contextmanager
    def transaction(self):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            yield
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise

    def event(self, kind, data):
        self.db.execute('INSERT INTO events(at,kind,data) VALUES(?,?,?)',
                        (int(time.time()), kind, json.dumps(data, sort_keys=True)))

    def active(self):
        return self.db.execute("SELECT batch FROM active WHERE id='active'").fetchone()[0]

    def manifest(self, batch):
        row = self.db.execute('SELECT data FROM manifests WHERE id=?', (batch,)).fetchone()
        if not row:
            raise Refused('unknown batch')
        data = json.loads(row[0])
        if data['id'] != batch:
            raise Refused('manifest identity mismatch')
        return data

    def base(self):
        rows = git(self.project, 'ls-remote', '--exit-code', 'origin',
                   'refs/heads/' + self.args.base).splitlines()
        if len(rows) != 1 or rows[0].split()[1] != 'refs/heads/' + self.args.base:
            raise Refused('remote base could not be read exactly')
        return oid(rows[0].split()[0])

    def live(self, component):
        _, _, _, owner, repo, _, number = component['pr'].split('/')
        fields = {'url', 'headRefOid', 'baseRefName', 'state', 'isDraft'}
        output = run(['gh-axi', 'pr', 'view', number, '--repo', owner + '/' + repo,
                      '--fields', ','.join(sorted(fields))])
        lines = output.splitlines()
        if not lines or lines.pop(0) != 'pull_request:':
            raise Refused('unreadable component PR fields')
        data = {}
        for line in lines:
            match = re.fullmatch(r'  ([A-Za-z]+): (.+)', line)
            if not match or match[1] not in fields or match[1] in data:
                raise Refused('unreadable component PR fields')
            value = match[2]
            data[match[1]] = json.loads(value) if value.startswith('"') or value in ('true', 'false', 'null') else value
        if set(data) != fields:
            raise Refused('missing component PR fields')
        if (data.get('url') != component['pr'] or data.get('state') != 'OPEN'
                or data.get('isDraft') is not False
                or data.get('baseRefName') != self.args.base):
            raise Refused('component PR identity, state or base changed: ' + component['id'])
        return oid(data['headRefOid'])

    def admission(self, component):
        if self.live(component) != component['head']:
            raise HeadChanged('component head changed: ' + component['id'])
        run(['bash', self.shell, '--admit', component['id'], component['pr'],
             component['head'], self.project, self.args.base])

    def submit(self):
        a = self.args
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', a.task):
            raise Refused('invalid task id')
        if not re.fullmatch(r'https://github.com/[^/\s]+/[^/\s]+/pull/[1-9][0-9]*', a.pr):
            raise Refused('initial queue supports canonical GitHub PR URLs only')
        head = oid(a.head)
        if oid(a.reviewed_head) != head or oid(a.focused_head) != head:
            raise Refused('review and focused-test assertions must bind the exact head')
        if a.task in a.depends_on or len(set(a.depends_on)) != len(a.depends_on):
            raise Refused('invalid dependency list')
        component = dict(id=a.task, pr=a.pr, head=head, base=self.base(),
                         dependencies=a.depends_on, dependency_heads={}, reviewed_head=a.reviewed_head,
                         focused_head=a.focused_head)
        self.admission(component)
        with self.transaction():
            active = self.active()
            if active and a.task in [c['id'] for c in self.manifest(active)['components']]:
                raise Refused('component belongs to the active batch; release or finish it first')
            old = self.db.execute('SELECT * FROM components WHERE id=?', (a.task,)).fetchone()
            for dependency in a.depends_on:
                row = self.db.execute('SELECT status,data FROM components WHERE id=?', (dependency,)).fetchone()
                if not row or row[0] not in ('ready', 'landed'):
                    raise Refused('dependency must already be ready or landed: ' + dependency)
                dependency_data = json.loads(row['data'])
                component['dependency_heads'][dependency] = dependency_data['head']
                pending = [dependency]
                seen = set()
                while pending:
                    node = pending.pop()
                    if node == a.task:
                        raise Refused('dependency cycle')
                    if node not in seen:
                        seen.add(node)
                        entry = self.db.execute('SELECT data FROM components WHERE id=?', (node,)).fetchone()
                        if entry:
                            pending.extend(json.loads(entry['data'])['dependencies'])
            if old and json.loads(old['data'])['head'] == head:
                if old['status'] == 'ready' and dict(json.loads(old['data']), base=component['base']) == component:
                    return json.loads(old['data'])
                raise Refused('resubmission requires a new reviewed/focused-green head')
            position = self.db.execute('SELECT COALESCE(MAX(position),0)+1 FROM components').fetchone()[0]
            self.db.execute('INSERT OR REPLACE INTO components VALUES(?,?,?,?)',
                            (a.task, json.dumps(component, sort_keys=True), 'ready', position))
            self.event('submitted', component)
        return component

    def objects_env(self):
        objects = self.root / 'objects'
        private_dir(objects)
        common = git(self.project, 'rev-parse', '--path-format=absolute', '--git-common-dir')
        env = dict(os.environ, GIT_NO_REPLACE_OBJECTS='1', GIT_OBJECT_DIRECTORY=str(objects),
                   GIT_ALTERNATE_OBJECT_DIRECTORIES=str(Path(common) / 'objects'))
        env.update(GIT_AUTHOR_NAME='Firstmate integration', GIT_AUTHOR_EMAIL='integration@localhost',
                   GIT_COMMITTER_NAME='Firstmate integration', GIT_COMMITTER_EMAIL='integration@localhost')
        return env

    def fetch(self, head, env):
        # Only the queue's object store receives objects; no refs or FETCH_HEAD.
        git(self.project, 'fetch', '--no-write-fetch-head', '--no-tags', 'origin', head, env=env)
        if git(self.project, 'rev-parse', head + '^{commit}', env=env) != head:
            raise Refused('fetched object differs from requested commit')

    def verify(self, manifest, admission=True):
        if self.base() != manifest['expected_base']:
            raise Refused('expected base moved externally; rebuild and retest')
        for component in manifest['components']:
            if admission:
                self.admission(component)
            elif self.live(component) != component['head']:
                raise HeadChanged('component head changed: ' + component['id'])
        env = self.objects_env()
        if git(self.project, 'rev-parse', manifest['commit'] + '^{tree}', env=env) != manifest['tree']:
            raise Refused('candidate tree differs from immutable manifest')
        git(self.project, 'merge-base', '--is-ancestor', manifest['expected_base'],
            manifest['commit'], env=env)
        for component in manifest['components']:
            git(self.project, 'merge-base', '--is-ancestor', component['head'],
                manifest['commit'], env=env)
        run(['bash', self.shell, '--active', self.project, self.args.base])

    def finish(self, manifest, status, reason, failed=None):
        # Caller holds the transaction and live integrator lease.
        failed_ids = {failed} if failed else set()
        for component in manifest['components']:
            if failed_ids.intersection(component['dependencies']):
                failed_ids.add(component['id'])
            state = 'failed' if component['id'] in failed_ids else 'ready'
            self.db.execute('UPDATE components SET status=? WHERE id=?', (state, component['id']))
        self.db.execute('UPDATE batches SET status=?, result=? WHERE id=?',
                        (status, json.dumps(dict(reason=reason, failed_component=failed)), manifest['id']))
        self.db.execute("UPDATE active SET batch=NULL WHERE id='active'")
        self.event(status, dict(batch=manifest['id'], reason=reason, failed_component=failed))

    def prepare(self):
        active = self.active()
        if active:
            manifest = self.manifest(active)
            if self.batch_status(active) == 'publishing':
                if self.recover_publication(manifest):
                    return None
                # Under the recovered OS lease, no publication child remains.
                # The remote still equals the expected base, so a refused or
                # interrupted-before-update attempt can release or retry.
                with self.transaction():
                    self.db.execute("UPDATE batches SET status='passed' WHERE id=?", (active,))
                    self.event('publication-not-landed', dict(batch=active))
            try:
                self.verify(manifest)
            except Refused as error:
                with self.transaction():
                    self.finish(manifest, 'invalidated', str(error))
                raise
            return manifest
        base = self.base()
        env = self.objects_env()
        self.fetch(base, env)
        head = base
        selected = []
        with self.transaction():
            rows = self.db.execute("SELECT * FROM components WHERE status='ready' ORDER BY position").fetchall()
            for row in rows:
                component = json.loads(row['data'])
                unmet = False
                changed = False
                for dependency in component['dependencies']:
                    entry = self.db.execute('SELECT status,data FROM components WHERE id=?', (dependency,)).fetchone()
                    if not entry or json.loads(entry['data'])['head'] != component['dependency_heads'][dependency]:
                        changed = True
                        break
                    if dependency not in {c['id'] for c in selected}:
                        if entry['status'] != 'landed':
                            unmet = True
                        else:
                            git(self.project, 'merge-base', '--is-ancestor',
                                component['dependency_heads'][dependency], base, env=env)
                if changed:
                    self.db.execute("UPDATE components SET status='stale' WHERE id=?", (component['id'],))
                    self.event('stale', dict(component=component['id'], reason='declared dependency head changed'))
                    continue
                if unmet:
                    continue
                try:
                    if any(component['dependency_heads'][c['id']] != c['head']
                           for c in selected if c['id'] in component['dependencies']):
                        raise HeadChanged('declared dependency head changed')
                    self.admission(component)
                except HeadChanged as error:
                    self.db.execute("UPDATE components SET status='stale' WHERE id=?", (component['id'],))
                    self.event('stale', dict(component=component['id'], reason=str(error)))
                    continue
                except Refused as error:
                    # Holds and unreadable authority are retried, not mistaken
                    # for changed source that requires a new reviewed head.
                    self.event('admission-refused', dict(component=component['id'], reason=str(error)))
                    continue
                self.fetch(component['head'], env)
                # A rewritten base cannot silently replace the submission base.
                ancestor = git(self.project, 'merge-base', base, component['head'], env=env)
                if ancestor != base and component['base'] != base:
                    # Ordinary behind-base components are allowed; their exact
                    # patch is merged against today's base and fully retested.
                    git(self.project, 'merge-base', '--is-ancestor', component['base'], base, env=env)
                result = subprocess.run(['git', '-C', self.project, 'merge-tree', '--write-tree',
                                         head, component['head']], env=env, text=True,
                                        capture_output=True, timeout=60, check=False)
                if result.returncode == 1:
                    self.db.execute("UPDATE components SET status='conflict' WHERE id=?", (component['id'],))
                    self.event('conflict', dict(component=component['id'], detail=result.stdout))
                    continue
                if result.returncode:
                    raise Refused('trial merge failed: ' + result.stderr)
                tree = oid(result.stdout.splitlines()[0])
                head = git(self.project, 'commit-tree', tree, '-p', head, '-p', component['head'],
                           '-m', 'Integrate ' + component['id'], env=env)
                selected.append(component)
                if len(selected) == 3:
                    break
            if not selected:
                return None
            batch = uuid.uuid4().hex
            manifest = dict(version=1, id=batch, project=self.project, base_branch=self.args.base,
                            expected_base=base, components=selected, commit=head,
                            tree=git(self.project, 'rev-parse', head + '^{tree}', env=env),
                            integration_branch='fm/integration/' + batch)
            # Read again after assembly; nothing expensive or published yet.
            self.verify(manifest)
            self.db.execute('INSERT INTO manifests VALUES(?,?)',
                            (batch, json.dumps(manifest, sort_keys=True)))
            self.db.execute("INSERT INTO batches VALUES(?,'prepared',NULL)", (batch,))
            self.db.execute("UPDATE active SET batch=? WHERE id='active'", (batch,))
            self.event('prepared', dict(batch=batch))
        return manifest

    def claim(self):
        a = self.args
        workdir = str(Path(a.workdir).resolve(strict=True))
        if workdir == self.project or git(workdir, 'rev-parse', '--show-toplevel') != workdir:
            raise Refused('integrator command requires a distinct isolated repository root')
        command = a.command
        if command[:1] == ['--']:
            command = command[1:]
        if not command:
            raise Refused('claim requires a foreground integrator command after --')
        with open(self.root / 'lease', 'a') as lease:
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Refused('another integrator owns this project/base lease') from None
            manifest = self.prepare()
            emit(manifest)
            if manifest is None:
                return 0
            env = self.objects_env()
            env.update(FM_INTEGRATION_BATCH=manifest['id'],
                       FM_INTEGRATION_MANIFEST=json.dumps(manifest, sort_keys=True),
                       FM_INTEGRATION_COMMIT=manifest['commit'],
                       FM_INTEGRATION_OBJECTS=str(self.root / 'objects'),
                       FM_INTEGRATION_LEASE_FD=str(lease.fileno()))
            return subprocess.call(command, cwd=workdir, env=env, pass_fds=(lease.fileno(),))

    def owned_manifest(self):
        try:
            fd = int(os.environ['FM_INTEGRATION_LEASE_FD'])
            info = os.fstat(fd)
            current = (self.root / 'lease').stat()
            if (info.st_dev, info.st_ino) != (current.st_dev, current.st_ino):
                raise ValueError
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (KeyError, ValueError, OSError):
            raise Refused('operation requires the inherited live integrator lease') from None
        if self.args.batch != os.environ.get('FM_INTEGRATION_BATCH') or self.active() != self.args.batch:
            raise Refused('batch is not this integrator\'s active batch')
        return self.manifest(self.args.batch)

    def record_result(self):
        manifest = self.owned_manifest()
        if self.batch_status(manifest['id']) == 'publishing':
            raise Refused('publication intent must be recovered before replacing its result')
        a = self.args
        if a.failed_component:
            if a.failed_component not in {c['id'] for c in manifest['components']}:
                raise Refused('failed component is not in this batch')
            with self.transaction():
                self.finish(manifest, 'failed', a.reason, a.failed_component)
        else:
            if a.tested_tree != manifest['tree'] or a.reviewed_head != manifest['commit']:
                raise Refused('full-baseline tree and final reviewed head must match manifest')
            try:
                self.verify(manifest)
            except Refused as error:
                with self.transaction():
                    self.finish(manifest, 'invalidated', str(error))
                raise
            with self.transaction():
                self.db.execute("UPDATE batches SET status='passed',result=? WHERE id=?",
                                (json.dumps(dict(tested_tree=a.tested_tree, reviewed_head=a.reviewed_head)), a.batch))
                self.event('passed', dict(batch=a.batch))
        return self.snapshot()

    def release(self):
        manifest = self.owned_manifest()
        if self.batch_status(manifest['id']) == 'publishing':
            raise Refused('publication intent must be recovered before release')
        with self.transaction():
            self.finish(manifest, 'released', self.args.reason)
        return self.snapshot()

    def batch_status(self, batch):
        return self.db.execute('SELECT status FROM batches WHERE id=?', (batch,)).fetchone()[0]

    def allowed(self):
        path = Path(os.environ['FM_HOME']) / 'config/integration-queue-projects'
        if not path.exists():
            raise Refused('project is not opted in to integration publication')
        regular(path)
        if self.project not in path.read_text().splitlines():
            raise Refused('project is not opted in to integration publication')

    def publication_data(self):
        manifest = self.owned_manifest()
        self.allowed()
        row = self.db.execute('SELECT status,result FROM batches WHERE id=?', (manifest['id'],)).fetchone()
        result = json.loads(row['result'] or '{}')
        if (row['status'] not in ('passed', 'publishing')
                or result.get('tested_tree') != manifest['tree']
                or result.get('reviewed_head') != manifest['commit']):
            raise Refused('batch needs the full baseline and final review at the exact manifest')
        self.verify(manifest, admission=False)
        return dict(manifest, publication=result.get('publication'))

    def publish(self):
        manifest = self.owned_manifest()
        self.allowed()
        if self.batch_status(manifest['id']) == 'publishing' and self.recover_publication(manifest):
            return self.snapshot()
        data = self.publication_data()
        binding = dict(id=self.args.task, pr=self.args.pr, head=manifest['commit'])
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', binding['id']):
            raise Refused('invalid integration task id')
        if binding['id'] in {c['id'] for c in manifest['components']}:
            raise Refused('integration review requires its own task')
        if not re.fullmatch(r'https://github.com/[^/\s]+/[^/\s]+/pull/[1-9][0-9]*', binding['pr']):
            raise Refused('integration publication supports canonical GitHub PRs only')
        if any(c['pr'].split('/pull/')[0] != binding['pr'].split('/pull/')[0]
               for c in manifest['components']):
            raise Refused('all integration PRs must belong to the same repository')
        if data['publication'] and data['publication'] != binding:
            raise Refused('integration PR binding changed')
        # Admission checks the final PR identity/authority without taking over
        # the no-mistakes run or granting permission to push its branch.
        self.admission(binding)
        owner_repo, number = binding['pr'][len('https://github.com/'):].split('/pull/')
        branch = run(['gh-axi', 'api', 'repos/' + owner_repo + '/pulls/' + number,
                      '--jq', '.head.ref'])
        if branch != manifest['integration_branch']:
            raise Refused('integration PR does not use the intended manifest branch')
        with self.transaction():
            row = self.db.execute('SELECT result FROM batches WHERE id=?', (manifest['id'],)).fetchone()
            result = json.loads(row[0])
            result['publication'] = binding
            self.db.execute('UPDATE batches SET result=? WHERE id=?', (json.dumps(result), manifest['id']))
        env = self.objects_env()
        fd = int(os.environ['FM_INTEGRATION_LEASE_FD'])
        command = ['bash', str(Path(self.shell).with_name('fm-pr-merge.sh')),
                   binding['id'], binding['pr'], '--integration-batch', manifest['id']]
        completed = subprocess.run(command, env=env, pass_fds=(fd,), check=False)
        if completed.returncode:
            raise Refused('guarded integration publication refused; inspect the merge error; no fallback attempted')
        if not self.recover_publication(manifest):
            raise Refused('publication was not confirmed; durable intent retained for recovery')
        return self.snapshot()

    def recover_publication(self, manifest):
        row = self.db.execute('SELECT status,result FROM batches WHERE id=?', (manifest['id'],)).fetchone()
        if row['status'] != 'publishing':
            return False
        result = json.loads(row['result'])
        base = self.base()
        if base == manifest['expected_base']:
            return False
        env = self.objects_env()
        self.fetch(base, env)
        # A later external fast-forward is acceptable evidence of an already
        # published candidate, never permission to publish a new candidate.
        ancestry = subprocess.run(['git', '-C', self.project, 'merge-base', '--is-ancestor',
                                   manifest['commit'], base], env=env, check=False,
                                  capture_output=True, timeout=60)
        if ancestry.returncode == 1:
            with self.transaction():
                self.finish(manifest, 'invalidated', 'base moved without the tested candidate; no publication proved')
            raise Refused('expected base moved externally; batch invalidated, no publication proved')
        if ancestry.returncode:
            raise Refused('publication ancestry could not be read; intent retained')
        if git(self.project, 'rev-parse', manifest['commit'] + '^{tree}', env=env) != manifest['tree']:
            raise Refused('published candidate tree cannot be proved')
        for component in [*manifest['components'], result['publication']]:
            git(self.project, 'merge-base', '--is-ancestor', component['head'], manifest['commit'], env=env)
            owner_repo, number = component['pr'][len('https://github.com/'):].split('/pull/')
            proof = run(['gh-axi', 'api', 'repos/' + owner_repo + '/pulls/' + number,
                         '--jq', 'if .merged == true and .head.sha == "' + component['head'] +
                         '" then "fm-queue-merged" else "fm-queue-unproved" end'])
            if proof != 'fm-queue-merged':
                raise Refused('published PR merge is not yet proved: ' + component['pr'])
            run(['bash', self.shell, '--account', component['id'], component['pr'], result['authority'], component['head']])
        with self.transaction():
            self.db.execute("UPDATE batches SET status='landed' WHERE id=?", (manifest['id'],))
            for component in manifest['components']:
                self.db.execute("UPDATE components SET status='landed' WHERE id=?", (component['id'],))
            self.db.execute("UPDATE active SET batch=NULL WHERE id='active'")
            self.event('landed', dict(batch=manifest['id'], commit=manifest['commit']))
        return True

    def land_after_guards(self, task, url, head, authority):
        """Called only inside fm-pr-merge after its live gates, under its locks.

        A normal push's pre-push protocol supplies the server-advertised old
        object. Reject anything except the manifest's expected base, then let
        receive-pack's atomic old/new compare-and-swap perform the update.
        There are no force flags or fallback merge commands. The original
        repository hook is chained with the exact stdin/argv it normally sees.
        """
        data = self.publication_data()
        manifest = self.manifest(data['id'])
        binding = dict(id=task, pr=url, head=head)
        if data['publication'] != binding or head != manifest['commit']:
            raise Refused('verified integration PR does not match manifest binding')
        if authority not in ('attended', 'away'):
            raise Refused('unreadable accepted merge authority')
        owner_repo = url[len('https://github.com/'):].split('/pull/')[0]
        def identity(remote):
            match = re.fullmatch(r'(?:https://github.com/|git@github.com:|ssh://git@github.com/)([^/]+/[^/]+?)(?:\.git)?', remote)
            return match[1].lower() if match else None
        remotes = git(self.project, 'remote', 'get-url', '--push', '--all', 'origin').splitlines()
        if (len(remotes) != 1 or identity(remotes[0]) != owner_repo.lower()
                or identity(git(self.project, 'remote', 'get-url', 'origin')) != owner_repo.lower()):
            raise Refused('origin fetch/push identity differs from the GitHub PR repository')
        branch_path = quote(self.args.base, safe='')
        prefix = 'repos/' + owner_repo + '/'
        protected = run(['gh-axi', 'api', prefix + 'branches/' + branch_path, '--jq',
                         'if .protected == false then "fm-queue-unprotected" elif .protected == true then "fm-queue-protected" else "fm-queue-unreadable" end'])
        if protected == 'fm-queue-protected':
            protection = run(['gh-axi', 'api', prefix + 'branches/' + branch_path + '/protection', '--jq',
                              'if type == "object" and has("required_pull_request_reviews") and .required_pull_request_reviews == null then "fm-queue-no-pr-rule" else "fm-queue-requires-pr" end'])
            if protection != 'fm-queue-no-pr-rule':
                raise Refused('branch protection requires PR merges or could not be proved compatible')
        elif protected != 'fm-queue-unprotected':
            raise Refused('branch protection is unreadable')
        rules = run(['gh-axi', 'api', prefix + 'rules/branches/' + branch_path, '--paginate', '--jq',
                     'if type == "array" and all(.[]; has("type") and .type != "pull_request" and .type != "merge_queue") then "fm-queue-no-pr-rule" else "fm-queue-requires-pr" end'])
        if rules != 'fm-queue-no-pr-rule':
            raise Refused('branch rules require PR merges or could not be proved compatible')
        # Re-read after the network guards and immediately before recording the
        # synchronous publication intent. The hook also binds the server read.
        self.verify(manifest, admission=False)
        with self.transaction():
            row = self.db.execute('SELECT result FROM batches WHERE id=?', (manifest['id'],)).fetchone()
            result = json.loads(row[0])
            result['authority'] = authority
            self.db.execute("UPDATE batches SET status='publishing',result=? WHERE id=?",
                            (json.dumps(result), manifest['id']))
            self.event('publishing', dict(batch=manifest['id'], publication=binding))
        env = self.objects_env()
        original = git(self.project, 'rev-parse', '--path-format=absolute', '--git-path', 'hooks/pre-push')
        with tempfile.TemporaryDirectory(prefix='push-hooks-', dir=self.root) as hooks:
            hook = Path(hooks) / 'pre-push'
            hook.write_text('#!/usr/bin/env python3\n' +
                'import os, subprocess, sys\n' +
                'data = sys.stdin.read()\n' +
                'rows = [r.split() for r in data.splitlines()]\n' +
                'expected = ' + repr([head, 'refs/heads/' + self.args.base, manifest['expected_base']]) + '\n' +
                'if len(rows) != 1 or len(rows[0]) != 4 or rows[0][1:] != expected:\n' +
                '    sys.exit("error: advertised base differs from integration manifest; nothing published")\n' +
                'original = ' + repr(original) + '\n' +
                'if os.path.isfile(original) and os.access(original, os.X_OK):\n' +
                '    lease_fd = int(os.environ["FM_INTEGRATION_LEASE_FD"])\n' +
                '    sys.exit(subprocess.run([original, *sys.argv[1:]], input=data, text=True, pass_fds=(lease_fd,)).returncode)\n')
            hook.chmod(0o700)
            git(self.project, '-c', 'core.hooksPath=' + hooks, 'push', '--porcelain',
                '--no-force', '--no-mirror', '--no-follow-tags', '--recurse-submodules=no',
                'origin', head + ':refs/heads/' + self.args.base, env=env)

    def snapshot(self):
        return dict(active=self.active(), components=[dict(r, data=json.loads(r['data'])) for r in
                    self.db.execute('SELECT * FROM components ORDER BY position')],
                    batches=[dict(r, manifest=self.manifest(r['id'])) for r in
                             self.db.execute('SELECT * FROM batches ORDER BY rowid')],
                    events=[dict(r, data=json.loads(r['data'])) for r in
                            self.db.execute('SELECT * FROM events ORDER BY seq')])


def emit(data):
    print(json.dumps(data, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--project', required=True, help='registered canonical project clone path')
    parser.add_argument('--base', required=True, help='base branch name, e.g. main')
    commands = parser.add_subparsers(dest='action', required=True)
    submit = commands.add_parser('submit', help='assert reviewed/focused-green readiness at one live head')
    submit.add_argument('--task', required=True)
    submit.add_argument('--pr', required=True)
    submit.add_argument('--head', required=True)
    submit.add_argument('--reviewed-head', required=True)
    submit.add_argument('--focused-head', required=True)
    submit.add_argument('--depends-on', action='append', default=[])
    commands.add_parser('list', help='read components, immutable manifests, outcomes and recovery history')
    claim = commands.add_parser('claim', help='immediately prepare/resume up to three components under one live lease')
    claim.add_argument('--workdir', required=True)
    claim.add_argument('command', nargs=argparse.REMAINDER)
    result = commands.add_parser('record-result', help='record failure attribution or exact full-baseline/final-review assertions')
    result.add_argument('--batch', required=True)
    verdict = result.add_mutually_exclusive_group(required=True)
    verdict.add_argument('--tested-tree')
    verdict.add_argument('--failed-component')
    result.add_argument('--reviewed-head')
    result.add_argument('--reason', required=True)
    release = commands.add_parser('release', help='requeue batch; OS lease releases when the integrator command exits')
    release.add_argument('--batch', required=True)
    release.add_argument('--reason', required=True)
    publish = commands.add_parser('publish', help='land through existing merge guards; requires an opted-in project and final integration PR')
    publish.add_argument('--batch', required=True)
    publish.add_argument('--task', required=True)
    publish.add_argument('--pr', required=True)
    data = commands.add_parser('landing-data', help=argparse.SUPPRESS)
    data.add_argument('--batch', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    queue = Queue(args)
    try:
        if args.action == 'claim':
            return queue.claim()
        method = dict(list=queue.snapshot, submit=queue.submit, release=queue.release,
                      **{'record-result': queue.record_result, 'publish': queue.publish, 'landing-data': queue.publication_data})[args.action]
        emit(method())
        return 0
    finally:
        queue.db.close()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Refused, OSError, ValueError, KeyError, sqlite3.Error, subprocess.TimeoutExpired) as error:
        print('error: ' + str(error), file=sys.stderr)
        sys.exit(1)
