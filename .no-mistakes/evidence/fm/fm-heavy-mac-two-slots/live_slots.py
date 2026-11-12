import ctypes
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
RUNNER = Path(os.environ.get('LIVE_RUNNER', str(ROOT / 'bin/fm-heavy-remote-runner.py')))
AREA = ROOT / '.test-validation/live-host'
AREA.mkdir()
HOME = AREA / 'home'
HOME.mkdir()
JOBS = HOME / '.fm-heavy-remote'
JOBS.mkdir()
LOCK = AREA / 'native.lock'
ENV = dict(os.environ, HOME=str(HOME), FM_HEAVY_HOST_LOCK=str(LOCK),
           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Live validator', GIT_AUTHOR_EMAIL='live@example.invalid',
           GIT_COMMITTER_NAME='Live validator', GIT_COMMITTER_EMAIL='live@example.invalid',
           PYTHONDONTWRITEBYTECODE='1')
for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
    ENV.pop(key, None)
# Adopt and reap only this driver's detached job descendants on Linux.
assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
NATIVES = []

def emit(event, **values):
    print(json.dumps(dict(event=event, **values)), flush=True)

def reap():
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
            if not pid:
                break
        except ChildProcessError:
            break

def wait_for(predicate, label, seconds=12):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        reap()
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError('timeout: ' + label)

def command(argv, expected=0):
    out = subprocess.run([str(x) for x in argv], env=ENV, capture_output=True, text=True, timeout=25)
    assert out.returncode == expected, (argv, out.returncode, out.stdout, out.stderr)
    return out.stdout.strip()

def runner(action, *args, expected=0):
    out = subprocess.run([sys.executable, str(RUNNER), action, *map(str, args)],
                         env=ENV, capture_output=True, text=True, timeout=30)
    emit('runner', action=action, arguments=[str(x).replace(str(AREA), '<lab>') for x in args],
         exit=out.returncode, stdout=out.stdout.strip(), stderr=out.stderr.strip())
    assert out.returncode == expected, (action, out.returncode, out.stdout, out.stderr)
    return out.stdout.strip()

REPO = AREA / 'candidate'
REPO.mkdir()
(REPO / 'job.py').write_text('''import json, os, pathlib, subprocess, sys, time
home = pathlib.Path(os.environ['HOME'])
name, mode = sys.argv[1:]
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)'], close_fds=True) if mode == 'descendant' else None
(home / (name + '.started')).write_text(json.dumps(dict(pid=os.getpid(), child=child.pid if child else None)))
print('running ' + name, flush=True)
while not (home / (name + '.release')).exists(): time.sleep(.05)
print('completed ' + name, flush=True)
''')
command(['git', '-C', REPO, 'init', '-q'])
command(['git', '-C', REPO, 'add', 'job.py'])
command(['git', '-C', REPO, 'commit', '-qm', 'disposable live job'])
SHA = command(['git', '-C', REPO, 'rev-parse', 'HEAD'])
BUNDLE = AREA / 'candidate.bundle'
command(['git', '-C', REPO, 'bundle', 'create', BUNDLE, 'HEAD'])

def prepare(name, slots=2, mode='normal', sha=SHA):
    job = JOBS / name
    job.mkdir()
    shutil.copyfile(BUNDLE, job / 'src.bundle')
    argv = [sys.executable, 'job.py', name, mode]
    manifest = dict(id=name, host_slots=slots, sha=sha, timeout_s=90, argv=argv,
                    command_sha256=hashlib.sha256(b''.join(x.encode()+b'\0' for x in argv)).hexdigest(),
                    bundle_sha256=hashlib.sha256(BUNDLE.read_bytes()).hexdigest())
    if slots is None:
        del manifest['host_slots']
    (job / 'manifest.json').write_text(json.dumps(manifest))
    return job

def start(name, slots=2, mode='normal'):
    job = prepare(name, slots, mode)
    assert runner('start', job) == 'started'
    wait_for(lambda: (HOME / (name+'.started')).exists(), name+' starts')
    emit('job-running', job=name, processes=json.loads((HOME/(name+'.started')).read_text()),
         owner=json.loads((job/'owner.json').read_text()))
    return job

def release(job):
    (HOME / (job.name+'.release')).touch()
    wait_for(lambda: (job/'result.json').exists(), job.name+' result')
    result = json.loads((job/'result.json').read_text())
    emit('job-result', job=job.name, outcome=result['outcome'], exit=result['exit_code'],
         log=(job/'run.log').read_text())
    assert result['outcome'] == 'exited' and result['exit_code'] == 0
    runner('cleanup', job)
    reap()

def native(name):
    ready, done = HOME/(name+'.native-started'), HOME/(name+'.native-release')
    proc = subprocess.Popen(['flock', str(LOCK), sys.executable, '-c',
                             'import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch();\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(.05)',
                             str(ready), str(done)], env=ENV, start_new_session=True)
    NATIVES.append((proc, done))
    return proc, ready, done

def native_done(item):
    proc, ready, done = item
    done.touch()
    proc.wait(timeout=8)
    emit('native-completed', pid=proc.pid, started=ready.exists(), exit=proc.returncode)
    assert proc.returncode == 0 and ready.exists()

def probe_legacy(occupied):
    out = subprocess.run(['flock', '-n', str(LOCK), 'true'], env=ENV, capture_output=True)
    emit('unchanged-native-probe', exit=out.returncode, expected_occupied=occupied)
    assert (out.returncode != 0) == occupied

try:
    emit('environment', platform=sys.platform, transport='direct runner CLI; no mocked executables', candidate=SHA)
    # Default count: one native job consumes capacity.
    held = native('default-native')
    wait_for(held[1].exists, 'native started')
    runner('busy', expected=12)
    rejected = prepare('default-refused', None)
    runner('start', rejected, expected=12)
    assert not (rejected/'started').exists()
    emit('scenario-pass', name='Absent host-slots retains one total job')
    # Two total jobs include native work, and neither is stopped.
    beside = start('beside-native')
    runner('busy', 2, expected=12)
    third = prepare('third-refused')
    runner('start', third, expected=12)
    assert not (third/'started').exists()
    probe_legacy(True)
    release(beside)
    assert held[0].poll() is None
    emit('scenario-pass', name='One native plus one sent job overlap; a third is refused')
    # Both raw flock path form and descriptor form keep native priority.
    queued = native('queued-native')
    time.sleep(.2)
    assert queued[0].poll() is None and not queued[1].exists()
    runner('busy', 2, expected=12)
    runner('start', third, expected=12)
    native_done(held)
    wait_for(queued[1].exists, 'native gets next legacy lock')
    native_done(queued)
    held = native('descriptor-holder')
    wait_for(held[1].exists, 'descriptor holder started')
    fd = os.open(LOCK, os.O_WRONLY|os.O_APPEND)
    fdwait = subprocess.Popen(['flock', str(fd)], pass_fds=(fd,), env=ENV)
    os.close(fd)
    time.sleep(.2)
    assert fdwait.poll() is None
    runner('busy', 2, expected=12)
    native_done(held)
    assert fdwait.wait(timeout=8) == 0
    emit('scenario-pass', name='Queued native path and descriptor flock callers retain priority')
    # Two real transferred jobs overlap, and original lock stays occupied on supervisor loss.
    first = start('remote-first')
    second = start('remote-second', mode='descendant')
    assert runner('reconcile', second) == 'running'
    runner('busy', 2, expected=12)
    owner = json.loads((second/'owner.json').read_text())
    os.kill(owner['supervisor_pid'], signal.SIGKILL)
    wait_for(lambda: runner('reconcile', second) == 'orphaned', 'supervisor dies')
    probe_legacy(True)
    runner('busy', 2, expected=12)
    runner('start', third, expected=12)
    queued = native('after-supervisor-loss')
    time.sleep(.2)
    assert not queued[1].exists()
    (HOME/'remote-second.release').touch()
    wait_for(lambda: not Path('/proc/'+str(owner['group'])).exists(), 'leader exit')
    child = json.loads((HOME/'remote-second.started').read_text())['child']
    assert Path('/proc/'+str(child)).exists()
    probe_legacy(True)
    runner('busy', 2, expected=12)
    assert not queued[1].exists()
    emit('orphan-descendant-blocks-admission', child=child, native_started=False)
    runner('cancel', second)
    wait_for(queued[1].exists, 'native admits after orphan cleanup')
    native_done(queued)
    runner('cleanup', second)
    release(first)
    wait_for(lambda: runner('busy', 2) == 'free', 'both slots reclaimed')
    emit('scenario-pass', name='Two sent jobs overlap; supervisor and leader loss cannot admit native or remote third job')
    # Extra-slot ownership likewise survives a dead supervisor with a native occupant.
    held = native('orphan-extra-native')
    wait_for(held[1].exists, 'native starts beside extra')
    extra = start('orphan-extra')
    assert runner('reconcile', extra) == 'running'
    owner = json.loads((extra/'owner.json').read_text())
    os.kill(owner['supervisor_pid'], signal.SIGKILL)
    wait_for(lambda: runner('reconcile', extra) == 'orphaned', 'extra orphan')
    runner('busy', 2, expected=12)
    runner('start', third, expected=12)
    runner('cancel', extra)
    runner('cleanup', extra)
    wait_for(lambda: runner('busy', 2) == 'free', 'extra reclaimed')
    probe_legacy(True)
    native_done(held)
    emit('scenario-pass', name='Supervisor loss after running snapshot preserves the extra slot until cleanup')
    # Actual git checkout refusal, without any follow-up cleanup, releases its kernel slot.
    held = native('failed-checkout-native')
    wait_for(held[1].exists, 'native before checkout refusal')
    failed = prepare('failed-checkout', sha='f'*40)
    runner('start', failed, expected=10)
    assert (failed/'started').exists() and not (failed/'owner.json').exists()
    assert runner('busy', 2) == 'free'
    probe_legacy(True)
    retry = start('after-checkout-refusal')
    release(retry)
    native_done(held)
    emit('scenario-pass', name='Definite checkout refusal releases capacity without follow-up cleanup')
    # Public numeric validation retains accepted general host-slots range.
    for value in ('0','65','01','-1','two'):
        runner('busy', value, expected=10)
    for value in ('1','2','3','64'):
        assert runner('busy', value) == 'free'
    emit('scenario-pass', name='Runner accepts 1 through 64 and refuses malformed capacities')
finally:
    for proc, done in NATIVES:
        done.touch()
    for job in list(JOBS.iterdir()):
        if job.is_dir() and (job/'owner.json').exists():
            runner('cleanup', job)
    for _ in range(40):
        reap()
        time.sleep(.05)
    emit('teardown', lab='all processes stopped; disposable home removed')
    shutil.rmtree(AREA)
