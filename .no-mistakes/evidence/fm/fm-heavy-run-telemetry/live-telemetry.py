#!/usr/bin/env python3
"""Drive real fm-heavy commands, systemd scopes and loopback OpenSSH.

All fixture state, SSH keys/config, packages and daemon paths stay under the
gate worktree. A byte-forwarding TCP proxy injects an actual connection outage.
No product command, runtime, transport response or result is substituted.
"""
import hashlib
import json
import os
from pathlib import Path
import select
import shlex
import signal
import socket
import subprocess as sp
import threading
import time

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
BASE = ROOT / '.no-mistakes/test-phase'
TOOLS = BASE / 'tools'
HEAVY = ROOT / 'bin/fm-heavy.sh'
SUMMARY = ROOT / 'bin/fm-heavy-summary.sh'
RUNNER = ROOT / 'bin/fm-heavy-remote-runner.py'
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'GIT_'))}
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Live validation', GIT_COMMITTER_NAME='Live validation',
           GIT_AUTHOR_EMAIL='test@example.invalid', GIT_COMMITTER_EMAIL='test@example.invalid')
TRANSCRIPT = open(EVIDENCE / 'live-telemetry.log', 'a', buffering=1)
RESULTS = []
children = []
stop_proxy = threading.Event()
network_down = threading.Event()


def log(message):
    print(message, flush=True)
    TRANSCRIPT.write(message + '\n')


def run(argv, cwd=ROOT, env=None, expected=0):
    p = sp.run([str(a) for a in argv], cwd=cwd, env=env or ENV,
               text=True, stdout=sp.PIPE, stderr=sp.STDOUT, timeout=80)
    log('$ ' + shlex.join([str(a) for a in argv]) + '\n' + p.stdout + f'[exit {p.returncode}]')
    assert p.returncode == expected, p.stdout
    return p.stdout


def wait_for(check, label, seconds=40):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if check():
            return
        time.sleep(.08)
    raise AssertionError('Timed out: ' + label)


def write(path, content, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o700)


def rows(home):
    return [json.loads(s) for s in (home / 'state/heavy-jobs.jsonl').read_text().splitlines()]


def summary(home, *extra):
    output = run([SUMMARY, '--executions', '--log', home / 'state/heavy-jobs.jsonl', *extra])
    parsed = [s.split('\t') for s in output.splitlines()[1:]]
    return sum(int(r[3]) for r in parsed), sum(int(r[4]) for r in parsed)


def save(home, name):
    dest = EVIDENCE / (name + '-ledger.jsonl')
    dest.write_text((home / 'state/heavy-jobs.jsonl').read_text())
    remote = home / 'state/heavy-remote'
    if remote.exists():
        records = {}
        for file in remote.glob('*/*.json'):
            if not file.parent.name.startswith('unknown-'):
                records[str(file.relative_to(remote))] = json.loads(file.read_text())
        (EVIDENCE / (name + '-receipts.json')).write_text(json.dumps(records, indent=2))


def fixture(name, body):
    base = BASE / name
    repo, home = base / 'repo', base / 'home'
    (home / 'state').mkdir(parents=True)
    (home / 'config').mkdir()
    write(repo / 't/job.sh', body)
    write(repo / 'input', 'initial\n')
    write(repo / '.gitignore', 'ignored\n')
    run(['git', 'init', '-q', repo])
    run(['git', 'add', '-A'], cwd=repo)
    run(['git', 'commit', '-qm', 'initial'], cwd=repo)
    env = ENV | {'FM_HOME': str(home), 'FM_HEAVY_LOCK': str(base / 'slot.lock')}
    return repo, home, env


def heavy(repo, env, *args, expected=0, command=None):
    return run([HEAVY, '--class', 'build' if '--remote' not in args else 'test',
                '--project', 'p', *args, '--', *(command or ['bash', 't/job.sh'])],
               cwd=repo, env=env, expected=expected)


def heavy_async(repo, env, *args):
    output = open(repo.parent / 'client-output.log', 'w')
    p = sp.Popen([str(HEAVY), '--class', 'test', '--project', 'p', *args, '--', 'bash', 't/job.sh'],
                 cwd=repo, env=env, stdout=output, stderr=sp.STDOUT, start_new_session=True)
    children.append(p)
    return p


def collect_async(p, repo, code):
    actual = p.wait(timeout=65)
    log('$ fm-heavy.sh --class test --project p --remote -- bash t/job.sh\n' +
        (repo.parent / 'client-output.log').read_text() + f'[exit {actual}]')
    assert actual == code, actual


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


def forward(client, target):
    upstream = socket.create_connection(('127.0.0.1', target))
    try:
        while not network_down.is_set() and not stop_proxy.is_set():
            ready, _, _ = select.select([client, upstream], [], [], .08)
            for source in ready:
                data = source.recv(65536)
                if not data:
                    return
                (upstream if source is client else client).sendall(data)
    except OSError:
        pass
    finally:
        client.close()
        upstream.close()


def proxy(front, target):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', front))
    s.listen()
    s.settimeout(.1)
    try:
        while not stop_proxy.is_set():
            try:
                c, _ = s.accept()
            except socket.timeout:
                continue
            if network_down.is_set():
                c.close()
            else:
                threading.Thread(target=forward, args=(c, target), daemon=True).start()
    finally:
        s.close()


def setup_ssh():
    host = BASE / 'ssh-host'
    host.mkdir(exist_ok=True)
    port, front = free_port(), free_port()
    shell = TOOLS / 'remote-shell'
    write(shell, '#!/bin/bash\n' +
          'export HOME=' + shlex.quote(str(host)) + '\n' +
          'export PATH=' + shlex.quote(ENV['PATH']) + '\n' +
          'export FM_HEAVY_HOST_LOCK=' + shlex.quote(str(BASE / 'ssh-host.lock')) + '\n' +
          'export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1\n' +
          'export npm_config_cache="$HOME/npm-cache"\n' +
          'cd "$HOME"\nexec /bin/bash --noprofile --norc -c "$SSH_ORIGINAL_COMMAND"\n', True)
    config = TOOLS / 'sshd_config'
    write(config, f'''ListenAddress 127.0.0.1
Port {port}
HostKey {TOOLS / 'host_key'}
PidFile {TOOLS / 'sshd.pid'}
AuthorizedKeysFile {TOOLS / 'client_key.pub'}
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
SshdSessionPath {TOOLS / 'root/usr/lib/openssh/sshd-session'}
SshdAuthPath {TOOLS / 'root/usr/lib/openssh/sshd-auth'}
ForceCommand {shell}
LogLevel VERBOSE
''')
    logfile = open(TOOLS / 'sshd.log', 'w')
    daemon = sp.Popen([str(TOOLS / 'root/usr/sbin/sshd'), '-D', '-e', '-f', str(config)],
                      env=ENV | {'LD_LIBRARY_PATH': str(TOOLS / 'root/usr/lib/x86_64-linux-gnu')}, stdout=logfile, stderr=sp.STDOUT)
    children.append(daemon)
    def listening():
        if daemon.poll() is not None:
            raise AssertionError((TOOLS / 'sshd.log').read_text())
        try:
            socket.create_connection(('127.0.0.1', port), timeout=.1).close()
            return True
        except OSError:
            return False
    wait_for(listening, 'isolated SSH daemon')
    threading.Thread(target=proxy, args=(front, port), daemon=True).start()
    ssh_config = TOOLS / 'ssh_config'
    write(ssh_config, f'''Host fm-telemetry-lab
  HostName 127.0.0.1
  User {os.environ['USER']}
  Port {front}
  IdentityFile {TOOLS / 'client_key'}
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile {TOOLS / 'known_hosts'}
  GlobalKnownHostsFile /dev/null
  LogLevel ERROR
''')
    write(TOOLS / 'bin/ssh', '#!/bin/sh\nexec /usr/bin/ssh -F ' + shlex.quote(str(ssh_config)) + ' "$@"\n', True)
    env = ENV | {'PATH': str(TOOLS / 'bin') + ':' + ENV['PATH']}
    run(['ssh', 'fm-telemetry-lab', 'printf "SSH live: "; pwd'], env=env)
    return host, env


def remote_fixture(name, body, ssh_env):
    repo, home, env = fixture(name, body)
    write(home / 'config/heavy-remote', 'host fm-telemetry-lab\nproject p\ntimeout 50\n')
    env.update(PATH=ssh_env['PATH'], FM_HEAVY_REMOTE_RECONNECT_SLEEP='.1', FM_HEAVY_REMOTE_RECONNECT_TRIES='2')
    return repo, home, env


def scenario(name, fn):
    log('\nSCENARIO: ' + name)
    fn()
    RESULTS.append({'name': name, 'result': 'pass', 'live': True})
    log('PASS: ' + name)


def local_identity():
    repo, home, env = fixture('local', 'printf "workload output\\n"; exit 7\n')
    before = (repo / '.git/index').read_bytes()
    for _ in range(2):
        heavy(repo, env, '--phase', 'focused', expected=7)
    initial = rows(home)
    assert initial[0]['command_sha256'] == initial[1]['command_sha256']
    assert initial[0]['source_sha256'] == initial[1]['source_sha256']
    assert initial[0]['execution_id'] != initial[1]['execution_id']
    assert initial[0]['phase'] == 'focused' and initial[0]['source_dirty'] is False
    assert initial[0]['command_exit'] == 7 and initial[0]['entry_kind'] == 'execution'
    assert initial[0]['command_timing'] == 'local-command'
    assert initial[0]['command_ended_at'] >= initial[0]['command_started_at']
    assert summary(home) == (2, 0)
    heavy(repo, env, '--reattach', expected=7)
    assert rows(home)[-1]['entry_kind'] == 'reattachment'
    assert summary(home) == (2, 0)
    heavy(repo, env, command=['true', 'a b', ''])
    heavy(repo, env, command=['true', 'a', 'b'])
    assert rows(home)[-1]['command_sha256'] != rows(home)[-2]['command_sha256']
    write(repo / 'input', 'changed\n')
    heavy(repo, env, expected=7)
    assert rows(home)[-1]['source_sha256'] != initial[0]['source_sha256']
    assert rows(home)[-1]['source_dirty'] is True
    write(repo / 'untracked', 'new file\n')
    heavy(repo, env, expected=7)
    dirty = rows(home)[-1]
    assert dirty['source_sha256'] != rows(home)[-2]['source_sha256']
    assert (repo / '.git/index').read_bytes() == before, 'real index was mutated'
    run(['git', 'add', '-A'], cwd=repo)
    run(['git', 'commit', '-qm', 'same content now committed'], cwd=repo)
    heavy(repo, env, expected=7)
    committed = rows(home)[-1]
    assert committed['source_dirty'] is False
    assert committed['source_head'] != initial[0]['source_head']
    assert committed['source_sha256'] == dirty['source_sha256']
    write(repo / 'ignored', 'excluded input\n')
    heavy(repo, env, expected=7)
    assert rows(home)[-1]['source_sha256'] == committed['source_sha256']
    assert summary(home) == (8, 0)
    # Duplicate delivery of the emitted ledger is a real report input contract.
    ledger = home / 'state/heavy-jobs.jsonl'
    with ledger.open('a') as out:
        out.write(json.dumps(initial[0]) + '\n')
        out.write('{"requested_at":0}\n')
    assert summary(home) == (8, 0)
    assert summary(home, '--until', str(initial[0]['command_started_at'])) == (0, 0)
    run([SUMMARY, '--log', ledger])
    run([SUMMARY, '--until', 'later', '--log', ledger], expected=2)
    save(home, 'local')


def queued_cancel():
    repo, home, env = fixture('queued', 'touch should-not-run\n')
    ready = repo.parent / 'lock-ready'
    holder = sp.Popen(['flock', str(repo.parent / 'slot.lock'), 'bash', '-c',
                       'touch "$1"; sleep 40', '_', str(ready)], start_new_session=True)
    children.append(holder)
    wait_for(ready.exists, 'private slot held')
    p = heavy_async(repo, env)
    wait_for(lambda: list((repo.parent / 'slot.lock.waiting').glob('*'))
             if (repo.parent / 'slot.lock.waiting').exists() else [], 'queued marker')
    os.killpg(p.pid, signal.SIGTERM)
    collect_async(p, repo, 143)
    assert not (repo / 'should-not-run').exists()
    r = rows(home)[0]
    assert r['entry_kind'] == 'not-started' and r['command_started_at'] is None
    assert summary(home) == (0, 0)
    os.killpg(holder.pid, signal.SIGTERM)
    holder.wait()
    save(home, 'queued')


def remote_normal(host, ssh_env):
    repo, home, env = remote_fixture('remote-normal', 'printf "real remote command\\n"; sleep 1; exit 9\n', ssh_env)
    heavy(repo, env, '--remote', expected=9)
    r = rows(home)[0]
    result = json.loads((home / 'state/heavy-remote' / r['job'] / 'result.json').read_text())
    assert r['entry_kind'] == 'execution' and r['outcome'] == 'failed'
    assert r['command_exit'] == 9 and r['command_timing'] == 'remote-result'
    assert r['command_started_at'] == result['command_started_at']
    assert r['command_ended_at'] == result['command_ended_at']
    assert r['source_tree'] == result['tree'] and r['candidate'] == result['sha']
    assert summary(home) == (1, 0)
    assert not (host / '.fm-heavy-remote' / r['job']).exists()
    save(home, 'remote-normal')


def remote_reconciled(host, ssh_env):
    release = host / 'release-command'
    count = host / 'command-count'
    repo, home, env = remote_fixture('reconciled',
        'echo executed >> "$HOME/command-count"\nuntil [ -e "$HOME/release-command" ]; do sleep .1; done\necho remote-finished\n', ssh_env)
    p = heavy_async(repo, env, '--remote')
    wait_for(count.exists, 'real remote command has started')
    network_down.set()
    log('Injected TCP outage: existing SSH connections closed; new connections refused.')
    collect_async(p, repo, 75)
    original = rows(home)[0]
    assert original['entry_kind'] == 'unknown' and original['command_started_at'] is None
    first_line = (home / 'state/heavy-jobs.jsonl').read_text().splitlines()[0]
    assert summary(home) == (0, 1)
    release.touch()
    result_path = host / '.fm-heavy-remote' / original['job'] / 'result.json'
    wait_for(result_path.exists, 'remote finishes while disconnected')
    assert summary(home) == (0, 1), 'unverified completion must remain unknown'
    network_down.clear()
    log('Restored TCP connectivity; next real invocation must reconcile and then execute.')
    heavy(repo, env, '--remote')
    assert len(count.read_text().splitlines()) == 2
    assert (home / 'state/heavy-jobs.jsonl').read_text().splitlines()[0] == first_line
    assert summary(home) == (2, 0)
    first_dir = home / 'state/heavy-remote' / original['job']
    receipt = json.loads((first_dir / 'reconciled.json').read_text())
    result = json.loads((first_dir / 'result.json').read_text())
    assert receipt['outcome'] == 'pass'
    at = result['command_started_at']
    assert summary(home, '--since', str(at), '--until', str(at + 1)) == (1, 0)
    assert summary(home, '--until', str(at)) == (0, 0)
    with (home / 'state/heavy-jobs.jsonl').open('a') as out:
        out.write(first_line + '\n')
        out.write(json.dumps(rows(home)[1]) + '\n')
    assert summary(home) == (2, 0)
    heavy(repo, env, '--remote', '--reattach')
    assert rows(home)[-1]['entry_kind'] == 'reattachment'
    assert summary(home) == (2, 0)
    save(home, 'reconciled')


def remote_cancel(host, ssh_env, reconciled):
    mode = 'reconciled' if reconciled else 'direct'
    name = 'cancel-' + mode
    repo, home, env = remote_fixture(name, f'echo executed >> "$HOME/{name}-ran"\n', ssh_env)
    # A real npm install lifecycle script blocks dependency preparation. No
    # runtime or package manager is faked; no third-party dependency is needed.
    package = {'name': name, 'version': '1.0.0', 'scripts': {'postinstall':
        f'echo installing > "$HOME/{name}-install"; while [ ! -e "$HOME/{name}-release" ]; do sleep .1; done'}}
    write(repo / 'package.json', json.dumps(package))
    run(['npm', 'install', '--package-lock-only', '--ignore-scripts', '--no-audit', '--no-fund'],
        cwd=repo, env=env | {'npm_config_cache': str(repo.parent / 'npm-cache')})
    run(['git', 'add', '-A'], cwd=repo)
    run(['git', 'commit', '-qm', 'dependency preparation'], cwd=repo)
    p = heavy_async(repo, env, '--remote')
    wait_for((host / (name + '-install')).exists, 'real npm ci postinstall reached')
    open_dir = home / 'state/heavy-remote/unknown-fm-telemetry-lab'
    opened = list(open_dir.glob('*.json'))
    assert len(opened) == 1
    job = opened[0].stem
    remote_dir = host / '.fm-heavy-remote' / job
    if reconciled:
        network_down.set()
        collect_async(p, repo, 75)
        assert rows(home)[0]['entry_kind'] == 'unknown'
        assert summary(home) == (0, 1)
        network_down.clear()
    # Host-side cancellation uses the real runner cancel interface over SSH.
    run(['ssh', 'fm-telemetry-lab', f'python3 .fm-heavy-remote/{job}/runner.py cancel .fm-heavy-remote/{job}'], env=ssh_env)
    if not reconciled:
        collect_async(p, repo, 143)
        r = rows(home)[0]
        assert r['outcome'] == 'cancelled' and r['entry_kind'] == 'not-started'
        assert r['command_started_at'] is None and r['command_exit'] is None
        assert summary(home) == (0, 0)
    else:
        wait_for((remote_dir / 'result.json').exists, 'verified host cancellation result')
        assert summary(home) == (0, 1)
        (host / (name + '-release')).touch()
        heavy(repo, env, '--remote')
        assert summary(home) == (1, 0)
        receipt = json.loads((home / 'state/heavy-remote' / job / 'reconciled.json').read_text())
        assert receipt['outcome'] == 'cancelled'
    result = json.loads((home / 'state/heavy-remote' / job / 'result.json').read_text())
    assert result['outcome'] == 'cancelled'
    assert result['preparation_step'] == 'dependencies' and result['command_started_at'] is None
    if not reconciled:
        assert not (host / (name + '-ran')).exists()
    else:
        assert len((host / (name + '-ran')).read_text().splitlines()) == 1
    assert not remote_dir.exists() and not list(open_dir.glob('*.json'))
    save(home, name)


try:
    if not (BASE / 'local').exists():
        scenario('Local command identity, failure timing, source snapshots, reattachments and bounded deduplicated report', local_identity)
        scenario('Cancellation while queued starts no command and contributes no execution or unknown', queued_cancel)
    host, ssh_env = setup_ssh()
    scenario('Real SSH command failure records verified remote identity and command-only timing', lambda: remote_normal(host, ssh_env))
    scenario('TCP outage remains unknown until reconciliation; two verified executions count twice', lambda: remote_reconciled(host, ssh_env))
    scenario('Host cancellation during real npm preparation is immediately not-started', lambda: remote_cancel(host, ssh_env, False))
    scenario('Reconciled host cancellation during real npm preparation removes unknown without counting an execution', lambda: remote_cancel(host, ssh_env, True))
except Exception as e:
    import traceback
    log(traceback.format_exc())
    RESULTS.append({'name': 'Current live drive', 'result': 'fail', 'live': True, 'reason': str(e)})
    raise
finally:
    network_down.clear()
    # Only private fixture jobs and processes are stopped.
    host_root = BASE / 'ssh-host/.fm-heavy-remote'
    if host_root.exists():
        for jobdir in host_root.iterdir():
            if (jobdir / 'manifest.json').exists():
                sp.run(['python3', str(RUNNER), 'cancel', str(jobdir)],
                       env=ENV | {'HOME': str(BASE / 'ssh-host'), 'FM_HEAVY_HOST_LOCK': str(BASE / 'ssh-host.lock')},
                       stdout=sp.DEVNULL, stderr=sp.DEVNULL, timeout=25)
    stop_proxy.set()
    for p in children:
        if p.poll() is None:
            try:
                if os.getpgid(p.pid) == p.pid:
                    os.killpg(p.pid, signal.SIGTERM)
                else:
                    p.terminate()
                p.wait(timeout=5)
            except (OSError, sp.TimeoutExpired):
                p.kill()
    (EVIDENCE / 'live-results.json').write_text(json.dumps(RESULTS, indent=2))
    TRANSCRIPT.close()
