import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path.cwd()
LAB = ROOT / '.validation-heavy' / 'live'
HOME = LAB / 'home'
RUNNER = ROOT / 'bin/fm-heavy-remote-runner.py'
LOCK = LAB / 'host.lock'
EVIDENCE = Path('/home/work/.no-mistakes/evidence/01M78WSYX8YMJ7PXNCTRM65Z1M')
# Reap detached grandchildren in this disposable driver, including after deliberate
# supervisor loss, so the kernel can release group ownership without zombie delay.
ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)
HOME.mkdir(parents=True)
ENV = dict(os.environ, HOME=str(HOME), FM_HEAVY_HOST_LOCK=str(LOCK),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='validation', GIT_AUTHOR_EMAIL='validation@example.invalid',
           GIT_COMMITTER_NAME='validation', GIT_COMMITTER_EMAIL='validation@example.invalid')
JOBS = []
PROCS = []

def reap():
    for _ in range(100):
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
            if not pid:
                return
        except ChildProcessError:
            return

def wait_for(test, label):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        reap()
        if test():
            return
        time.sleep(.05)
    raise AssertionError('timed out: ' + label)

def command(args, rc=0, env=ENV):
    result = subprocess.run([str(x) for x in args], env=env, capture_output=True, text=True)
    print('$', ' '.join(str(x).replace(str(ROOT) + '/', '') for x in args), flush=True)
    print('exit=%d %s%s' % (result.returncode, result.stdout, result.stderr), flush=True)
    assert result.returncode == rc, result
    return result.stdout.strip()

def runner(*args, rc=0):
    return command([sys.executable, RUNNER, *args], rc)

def new_job(name, body, slots=2, package=None):
    repo = LAB / ('repo-' + name)
    repo.mkdir()
    (repo / 'job.sh').write_text(body + '\n')
    if package is not None:
        (repo / 'package.json').write_text(package)
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], env=ENV).decode().strip()
    git('init', '-q')
    git('add', '-A')
    git('commit', '-qm', name)
    sha = git('rev-parse', 'HEAD')
    job = HOME / '.fm-heavy-remote' / name
    job.mkdir(parents=True)
    JOBS.append(job)
    git('bundle', 'create', str(job / 'src.bundle'), 'HEAD')
    argv = ['bash', 'job.sh']
    manifest = dict(id=name, sha=sha, project='live-validation', timeout_s=45,
                    argv=argv, command_sha256=hashlib.sha256(b''.join(a.encode()+b'\0' for a in argv)).hexdigest(),
                    bundle_sha256=hashlib.sha256((job/'src.bundle').read_bytes()).hexdigest())
    if slots is not None:
        manifest['host_slots'] = slots
    (job/'manifest.json').write_text(json.dumps(manifest))
    return job

def result(job, outcome='exited', rc=0):
    wait_for(lambda: (job/'result.json').exists(), job.name+' result')
    data = json.loads((job/'result.json').read_text())
    log = (job/'run.log').read_bytes()
    assert data['outcome'] == outcome and data['exit_code'] == rc, data
    assert data['artifacts']['run.log'] == dict(bytes=len(log), sha256=hashlib.sha256(log).hexdigest())
    print('RESULT', job.name, json.dumps(data), flush=True)
    print('RUN.LOG', job.name, log.decode(), flush=True)
    shutil.copyfile(job/'result.json', EVIDENCE/('live-'+job.name+'-result.json'))
    return data

def gated(name, slots=2):
    return new_job(name, 'echo START-'+name+'; touch "$HOME/'+name+'.started"; '
                   'until [ -e "$HOME/'+name+'.release" ]; do sleep .1; done; echo END-'+name, slots)

def release(name):
    (HOME/(name+'.release')).touch()

def started(name):
    wait_for(lambda: (HOME/(name+'.started')).exists(), name+' command started')

def native(name):
    proc = subprocess.Popen(['flock', str(LOCK), 'bash', '-c',
        'touch "$HOME/'+name+'.started"; until [ -e "$HOME/'+name+'.release" ]; do sleep .1; done'], env=ENV)
    PROCS.append(proc)
    return proc

try:
    print('SCENARIO native + sent job share two slots; third start refused', flush=True)
    native1 = native('native1')
    started('native1')
    runner('busy', '1', rc=12)
    runner('busy', '2')
    a = gated('alongside-native')
    runner('start', a)
    started(a.name)
    runner('busy', '2', rc=12)
    rejected = gated('third-refused')
    runner('start', rejected, rc=12)
    assert not (rejected/'started').exists()
    release(a.name)
    result(a)
    assert native1.poll() is None, 'remote completion stopped the native job'
    release('native1')
    native1.wait(timeout=5)
    print('PASS native + sent job and no preemption', flush=True)

    print('SCENARIO two sent jobs overlap; capacity is reusable', flush=True)
    a, b = gated('concurrent-a'), gated('concurrent-b')
    runner('start', a)
    runner('start', b)
    started(a.name); started(b.name)
    assert runner('status', a) == 'running'
    assert runner('status', b) == 'running'
    runner('busy', '2', rc=12)
    release(a.name); result(a)
    wait_for(lambda: subprocess.run([sys.executable, str(RUNNER), 'busy', '2'], env=ENV, stdout=subprocess.DEVNULL).returncode == 0, 'freed slot')
    runner('start', rejected)
    started(rejected.name)
    assert runner('status', b) == 'running'
    release(b.name); release(rejected.name)
    result(b); result(rejected)
    print('PASS overlapping jobs and slot reuse', flush=True)

    print('SCENARIO queued native flock reserves spare slot; markers are rechecked at start', flush=True)
    blocker = native('blocker'); started('blocker')
    waiter = native('waiter')
    wait_for(lambda: Path('/proc/%d/comm'%waiter.pid).read_text().strip() == 'flock', 'flock waiter')
    runner('busy', '2', rc=12)
    waiting = gated('priority-refused')
    runner('start', waiting, rc=12)
    assert not (waiting/'started').exists()
    release('blocker'); blocker.wait(timeout=5); started('waiter')
    release('waiter'); waiter.wait(timeout=5)
    runner('busy', '2')
    markers = Path(str(LOCK)+'.waiting'); markers.mkdir(exist_ok=True)
    marker = markers/str(os.getpid()); marker.touch()
    runner('start', waiting, rc=12)
    assert not (waiting/'started').exists()
    marker.unlink()
    runner('start', waiting); started(waiting.name); release(waiting.name); result(waiting)
    print('PASS native priority and start-time guard', flush=True)

    print('SCENARIO absent slots remains one; bounds enforced', flush=True)
    blocker = native('legacy-blocker'); started('legacy-blocker')
    default = gated('default-one', slots=None)
    runner('busy', rc=12); runner('start', default, rc=12)
    assert not (default/'started').exists()
    release('legacy-blocker'); blocker.wait(timeout=5)
    for bad in ['0', '02', '65', '-1']:
        runner('busy', bad, rc=10)
    runner('busy', '64')
    print('PASS default one and bounded configuration', flush=True)

    print('SCENARIO preparation failure never starts command; command exit 78 remains failure', flush=True)
    prep = new_job('bad-preparation', 'touch "$HOME/forbidden-command-start"', package='{invalid')
    runner('start', prep)
    data = result(prep, 'prepare-failed', 78)
    assert data['preparation_step'] == 'runtime'
    assert not (HOME/'forbidden-command-start').exists()
    fail = new_job('command-exit-78', 'echo command-ran-once; exit 78')
    runner('start', fail)
    data = result(fail, 'exited', 78)
    assert data['preparation_step'] == 'command'
    print('PASS failure-stage distinction and verified log checksums', flush=True)

    print('SCENARIO supervisor loss retains original slot until orphan cleanup', flush=True)
    a, b = gated('surviving-peer'), gated('orphan-original')
    runner('start', a); started(a.name)
    runner('start', b); started(b.name)
    owner = json.loads((b/'owner.json').read_text())
    os.kill(owner['supervisor_pid'], signal.SIGKILL)
    wait_for(lambda: subprocess.run([sys.executable, str(RUNNER), 'reconcile', str(b)], env=ENV, capture_output=True, text=True).stdout.strip() == 'orphaned', 'orphan reconciled')
    assert runner('reconcile', b) == 'orphaned'
    runner('busy', '2', rc=12)
    with LOCK.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('native original lock remains held by orphan guard', flush=True)
        else:
            raise AssertionError('orphan prematurely released native slot')
    runner('cleanup', b)
    assert not b.exists()
    assert runner('status', a) == 'running'
    wait_for(lambda: subprocess.run(['flock','-n',str(LOCK),'true']).returncode == 0, 'native slot released')
    runner('busy', '2')
    release(a.name); result(a)
    print('PASS orphan cleanup releases only its own slot', flush=True)
finally:
    for proc in PROCS:
        if proc.poll() is None:
            proc.terminate()
    for job in JOBS:
        if job.exists():
            runner('cleanup', job)
    reap()
print('ALL LOCAL LIVE RUNNER SCENARIOS PASSED', flush=True)
