import fcntl, hashlib, json, os, pathlib, shlex, shutil, socket, subprocess, time
ROOT=pathlib.Path.cwd()
LAB=ROOT/'.test-heavy-validation'
EVID=pathlib.Path('/home/work/.no-mistakes/evidence/01M78PKTATJJVSPR18T9AWQ6VC')
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith(('FM_', 'GIT_')): ENV.pop(k)
ENV['LD_LIBRARY_PATH']=str(LAB/'openssh/usr/lib/x86_64-linux-gnu')
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='test', GIT_AUTHOR_EMAIL='test@invalid', GIT_COMMITTER_NAME='test', GIT_COMMITTER_EMAIL='test@invalid', TMPDIR=str(LAB/'tmp'))
TRANS=[]
DAEMON=None

def run(args,cwd=None,env=None,check=True):
    p=subprocess.run([str(x) for x in args],cwd=cwd or ROOT,env=env or ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=75)
    TRANS.append('$ '+shlex.join([str(x) for x in args])+'\n'+p.stdout+f'[exit {p.returncode}]\n')
    if check and p.returncode: raise RuntimeError(TRANS[-1])
    return p

def git(repo,*args,**kw): return run(['git','-C',repo,*args],**kw).stdout.strip()
def fingerprint(repo):
    data={}
    for p in sorted(repo.rglob('*')):
        if p.is_dir() or '.git/objects/' in str(p): continue
        rel=str(p.relative_to(repo))
        if p.is_symlink(): b=os.readlink(p).encode()
        elif not p.stat().st_mode & 0o444: b=b'<unreadable>'
        else: b=p.read_bytes()
        data[rel]=[p.lstat().st_mode,hashlib.sha256(b).hexdigest()]
    return data

def setup(name,job):
    case=LAB/name; repo=case/'repo'; home=case/'home'
    (repo/'t').mkdir(parents=True); (home/'config').mkdir(parents=True)
    (repo/'t/job.sh').write_text(job+'\n')
    git(repo,'init','-q'); git(repo,'add','-A'); git(repo,'commit','-qm','candidate')
    (home/'config/heavy-remote').write_text('host fm-loopback\ncommand p -- bash t/job.sh\ntimeout 30\noffload\n')
    env=ENV|{'FM_HOME':str(home),'FM_HEAVY_LOCK':str(case/'slot.lock'),'PATH':str(LAB/'bin')+':'+ENV['PATH']}
    return case,repo,home,env

def heavy(repo,env,*opts,check=True):
    return run([ROOT/'bin/fm-heavy.sh','--class','test','--task','live-validation','--project','p',*opts,'--','bash','t/job.sh'],cwd=repo,env=env,check=check)

def record(home): return json.loads((home/'state/heavy-jobs.jsonl').read_text().splitlines()[-1])
def save(name,repo,home,p,before=None):
    dest=EVID/'live'/name; dest.mkdir(parents=True,exist_ok=True)
    (dest/'cli.log').write_text(p.stdout)
    rec=record(home); (dest/'heavy-job.json').write_text(json.dumps(rec,indent=2)+'\n')
    for label in ['result.json','run.log']:
        if rec.get('job'):
            src=home/'state/heavy-remote'/rec['job']/label
            if src.exists(): shutil.copy2(src,dest/label)
    if before is not None:
        after=fingerprint(repo)
        (dest/'source-before.json').write_text(json.dumps(before,indent=2)+'\n')
        (dest/'source-after.json').write_text(json.dumps(after,indent=2)+'\n')
        assert before==after,'source/index/ref mutation'
    return rec

try:
    # A genuine OpenSSH daemon, fresh keys, and an isolated shell HOME; nothing installed.
    for key in ['hostkey','clientkey']:
        if not (LAB/key).exists(): run(['ssh-keygen','-q','-t','ed25519','-N','','-f',LAB/key])
    with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
    (LAB/'ssh-home').mkdir(exist_ok=True); (LAB/'bin').mkdir(exist_ok=True)
    shell=LAB/'ssh-session.sh'
    shell.write_text('#!/bin/bash\nexport HOME='+shlex.quote(str(LAB/'ssh-home'))+'\nexport FM_HEAVY_HOST_LOCK='+shlex.quote(str(LAB/'host.lock'))+'\ncd "$HOME"\nexec /bin/bash -c "$SSH_ORIGINAL_COMMAND"\n'); shell.chmod(0o700)
    config=LAB/'sshd_config'
    config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {LAB}/hostkey
PidFile {LAB}/sshd.pid
AuthorizedKeysFile {LAB}/clientkey.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers work
PrintMotd no
PrintLastLog no
UseDNS no
ForceCommand {shell}
SshdAuthPath {LAB}/openssh/usr/lib/openssh/sshd-auth
SshdSessionPath {LAB}/openssh/usr/lib/openssh/sshd-session
''')
    clientconf=LAB/'ssh_config'
    clientconf.write_text(f'''Host fm-loopback
 HostName 127.0.0.1
 Port {port}
 User work
 IdentityFile {LAB}/clientkey
 IdentitiesOnly yes
 UserKnownHostsFile {LAB}/known_hosts
 StrictHostKeyChecking accept-new
 UpdateHostKeys no
 LogLevel ERROR
''')
    transport=LAB/'bin/ssh'; transport.write_text('#!/bin/bash\nexec /usr/bin/ssh -F '+shlex.quote(str(clientconf))+' "$@"\n'); transport.chmod(0o700)
    run([LAB/'openssh/usr/sbin/sshd','-t','-f',config])
    daemonlog=open(EVID/'live-sshd.log','w')
    DAEMON=subprocess.Popen([str(LAB/'openssh/usr/sbin/sshd'),'-D','-e','-f',str(config)],stdout=daemonlog,stderr=subprocess.STDOUT,env=ENV)
    time.sleep(.3)
    run([transport,'fm-loopback','printf "real-ssh-ready\\n"; pwd; python3 --version'])

    c,r,h,e=setup('clean','git rev-parse HEAD; uname -s')
    sha=git(r,'rev-parse','HEAD'); before=fingerprint(r)
    p=heavy(r,e,'--remote'); rec=save('clean',r,h,p,before)
    assert rec['candidate']==sha and rec['snapshot'] is False and rec['host']=='fm-loopback' and rec['outcome']=='pass'

    job='''set -eu
python3 - <<'CHECK'
import json,os,pathlib,subprocess
p=pathlib.Path('.')
x={'tracked':p.joinpath('tracked').read_text().strip(),'new':p.joinpath('new').read_text().strip(),'deleted':p.joinpath('deleted').exists(),'ignored_secret':p.joinpath('.env').exists(),'tracked_ignored':p.joinpath('ignored-force').read_text().strip(),'symlink':os.readlink('link'),'executable':os.access('execfile',os.X_OK),'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'parent':subprocess.check_output(['git','rev-parse','HEAD^'],text=True).strip()}
print(json.dumps(x,sort_keys=True))
assert x['tracked']=='modified' and x['new']=='untracked' and not x['deleted'] and not x['ignored_secret'] and x['tracked_ignored']=='force-added' and x['symlink']=='tracked' and x['executable']
CHECK'''
    c,r,h,e=setup('dirty',job)
    (r/'tracked').write_text('original\n'); (r/'deleted').write_text('delete me\n'); (r/'.gitignore').write_text('.env\nignored*\n')
    git(r,'add','-A'); git(r,'commit','-qm','fixtures'); sha=git(r,'rev-parse','HEAD')
    (r/'tracked').write_text('stash\n'); git(r,'stash','push','-qm','preserve')
    (r/'tracked').write_text('staged\n'); git(r,'add','tracked'); (r/'tracked').write_text('modified\n')
    (r/'deleted').unlink(); (r/'new').write_text('untracked\n'); (r/'.env').write_text('test-only-secret\n')
    (r/'ignored-force').write_text('force-added\n'); git(r,'add','-f','ignored-force')
    (r/'link').symlink_to('tracked'); (r/'execfile').write_text('#!/bin/sh\nexit 0\n'); (r/'execfile').chmod(0o755)
    before=fingerprint(r); p=heavy(r,e,'--remote'); rec=save('dirty',r,h,p,before)
    observed=json.loads(p.stdout.splitlines()[-1])
    assert rec['snapshot'] is True and rec['candidate']!=sha and rec['candidate']==observed['head'] and observed['parent']==sha and rec['outcome']=='pass'
    # Both actual local slot locks remain occupied while the automatic job runs.
    (h/'config/host-test-slots').write_text('2\n')
    with open(c/'slot.lock','a') as a,open(c/'slot.lock.2','a') as b:
        fcntl.flock(a,fcntl.LOCK_EX|fcntl.LOCK_NB); fcntl.flock(b,fcntl.LOCK_EX|fcntl.LOCK_NB)
        before=fingerprint(r); p=heavy(r,e); rec=save('automatic-two-busy-slots',r,h,p,before)
        assert rec['host']=='fm-loopback' and rec['snapshot'] is True and rec['fallback'] is None and rec['slot'] is None and rec['outcome']=='pass'
    # Real git add failure, with no fake git or ssh; falls back locally once.
    c,r,h,e=setup('snapshot-failure','echo local-fallback-ran; printf x >> local-runs')
    (r/'unreadable').write_text('cannot-read\n'); (r/'unreadable').chmod(0)
    before=fingerprint(r); p=heavy(r,e,'--remote'); rec=save('snapshot-failure',r,h,p)
    assert rec['host']=='local' and rec['fallback']=='snapshot-failed' and rec['candidate'] is None and (r/'local-runs').read_text()=='x'
    after=fingerprint(r); after.pop('local-runs'); assert before==after
    (EVID/'live/snapshot-failure/source-before.json').write_text(json.dumps(before,indent=2)+'\n')
    (EVID/'live/snapshot-failure/source-after.json').write_text(json.dumps(after,indent=2)+'\n')
    (r/'unreadable').chmod(0o600)
    # Dirty content cannot broaden approval.
    p=heavy(r,e,'--project','unapproved','--remote',check=False)
    assert p.returncode==2 and 'not approved' in p.stdout
    (EVID/'live/approval-refusal.log').write_text(p.stdout)
    assert not list((LAB/'ssh-home/.fm-heavy-remote').glob('*')),'remote job scratch leaked'
    TRANS.append('All real-SSH scenarios passed; remote scratch is empty.\n')
finally:
    if DAEMON:
        DAEMON.terminate()
        try: DAEMON.wait(timeout=5)
        except subprocess.TimeoutExpired: DAEMON.kill(); DAEMON.wait()
    (EVID/'live-transcript.log').write_text('\n'.join(TRANS))
