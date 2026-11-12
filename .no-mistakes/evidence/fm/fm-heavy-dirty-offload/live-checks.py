import os, pathlib, subprocess, json, hashlib, time, fcntl, signal, shutil
R=pathlib.Path.cwd()
D=R/'.phase-validation/live'
E=pathlib.Path('/home/work/.no-mistakes/evidence/01M78S47EKGR7CFY9G3C4HKCMM')
D.mkdir(parents=True,exist_ok=True)
repo=D/'repo'; repo.mkdir()
fm=D/'home'; (fm/'config').mkdir(parents=True)
host=D/'runner-host'; host.mkdir()
env=dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='test@example.invalid',TMPDIR=str(R/'.phase-validation/tmp'),FM_HOME=str(fm),FM_HEAVY_LOCK=str(D/'local.lock'),FM_HEAVY_HOST_LOCK=str(D/'runner.lock'),FM_HEAVY_REMOTE_RECHECK='30')
for k in ['GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(k,None)
transcript=[]
def emit(label,value):
    line=label+': '+(value if isinstance(value,str) else json.dumps(value,sort_keys=True))
    transcript.append(line); print(line,flush=True)
def run(args,cwd=repo,check=True,e=None):
    p=subprocess.run([str(x) for x in args],cwd=cwd,env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if check and p.returncode: raise RuntimeError(str(args)+'\n'+p.stdout)
    return p

def git(*args): return run(['git',*args]).stdout.strip()
def fingerprint():
    out={}
    for path in sorted(repo.rglob('*')):
        rel=path.relative_to(repo)
        if path.is_file() and not (len(rel.parts)>1 and rel.parts[:2]==('.git','objects')):
            out[str(rel)]={'mode':path.stat().st_mode,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
    return out

git('init','-q'); (repo/'t').mkdir()
probe='''import pathlib, subprocess, json, os
p=pathlib.Path('.')
files={name: ((p/name).read_text().strip() if (p/name).exists() else None) for name in ['tracked','new','deleted','.env','.forced','staged-new']}
print(json.dumps({'files': files, 'head': subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(), 'cwd': str(p.resolve())}), flush=True)
'''
(repo/'t/probe.py').write_text(probe)
(repo/'tracked').write_text('base\n'); (repo/'deleted').write_text('remove me\n')
(repo/'.gitignore').write_text('.env\n.forced\n')
git('add','-A'); git('commit','-qm','Fixture baseline'); head=git('rev-parse','HEAD')
(repo/'tracked').write_text('stash fixture\n'); git('stash','push','-qm','Preserved stash')
(repo/'tracked').write_text('staged\n'); git('add','tracked'); (repo/'tracked').write_text('working\n')
(repo/'new').write_text('untracked\n'); (repo/'deleted').unlink(); (repo/'.env').write_text('do not export\n')
(repo/'.forced').write_text('tracked ignored\n'); git('add','-f','.forced')
(repo/'staged-new').write_text('staged addition\n'); git('add','staged-new')
git('config','status.showUntrackedFiles','no')
conf=fm/'config/heavy-remote'
conf.write_text('host 127.0.0.1\ncommand lab -- python3 t/probe.py\ntimeout 20\noffload\n')
before=fingerprint()
base=D/'base-bin'; base.mkdir()
(base/'fm-heavy-remote.sh').write_text(run(['git','show','b5d0b6d1557caba0d8ef49b14b40bfbe4f80db94:bin/fm-heavy-remote.sh'],cwd=R).stdout)

def remote(script,sample):
    return run(['bash',script,'--host','127.0.0.1','--timeout','20','--sample',sample,'--state-dir',fm/'state/heavy-remote','--project','lab','--','python3','t/probe.py'])
base_sample=D/'base.sample'; p=remote(base/'fm-heavy-remote.sh',base_sample)
emit('Base dirty-tree attempt',p.stdout.strip()); emit('Base sample',base_sample.read_text().strip())
assert base_sample.read_text().strip()=='fallback=dirty-tree'
new_sample=D/'new.sample'; p=remote(R/'bin/fm-heavy-remote.sh',new_sample)
emit('Target dirty-tree attempt',p.stdout.strip()); emit('Target sample',new_sample.read_text().strip())
assert 'snapshot=true' in new_sample.read_text() and 'fallback=unreachable' in new_sample.read_text()
assert fingerprint()==before
objects=git('cat-file','--batch-all-objects','--batch-check=%(objectname) %(objecttype)').splitlines()
candidates=[]
for line in objects:
    sha,kind=line.split()
    if kind=='commit' and git('log','-1','--format=%s',sha)=='Snapshot of uncommitted work for remote tests': candidates.append(sha)
assert candidates
candidate=candidates[-1]
assert git('rev-parse',candidate+'^')==head
emit('Generated snapshot candidate',{'sha':candidate,'parent':head,'tree':git('rev-parse',candidate+'^{tree}')})
emit('Source preservation',{'files_and_git_controls_equal':True,'stash':git('stash','list'),'index_sha256':before['.git/index']['sha256']})

runner_env=dict(env,HOME=str(host))
runner=R/'bin/fm-heavy-remote-runner.py'
def exercise_runner(jobid,sha,argv,expect):
    job=host/'.fm-heavy-remote'/jobid; job.mkdir(parents=True)
    bundle=job/'src.bundle'; run(['git','bundle','create',bundle,'HEAD',sha])
    manifest={'id':jobid,'sha':sha,'argv':argv,'timeout_s':20,'project':'lab','class':'test','command_sha256':hashlib.sha256(b''.join(s.encode()+b'\0' for s in argv)).hexdigest(),'bundle_sha256':hashlib.sha256(bundle.read_bytes()).hexdigest()}
    (job/'manifest.json').write_text(json.dumps(manifest))
    try:
        start=run(['python3',runner,'start',job],cwd=host,e=runner_env); emit(jobid+' start',start.stdout.strip())
        state=run(['python3',runner,'wait',job,'25'],cwd=host,e=runner_env); assert state.stdout.strip()=='done'
        result=json.loads((job/'result.json').read_text()); output=(job/'run.log').read_text()
        emit(jobid+' output',output.strip()); emit(jobid+' result',result)
        shutil.copyfile(job/'result.json',E/(jobid+'-result.json')); shutil.copyfile(job/'run.log',E/(jobid+'-run.log'))
        assert result['sha']==sha and result['exit_code']==expect and result['outcome']=='exited'
        assert result['artifacts']['run.log']['sha256']==hashlib.sha256(output.encode()).hexdigest()
        return output
    finally:
        run(['python3',runner,'cleanup',job],cwd=host,e=runner_env)
        assert not job.exists()

out=exercise_runner('live-dirty-snapshot',candidate,['python3','t/probe.py'],0)
observed=json.loads(out)
assert observed['files']=={'tracked':'working','new':'untracked','deleted':None,'.env':None,'.forced':'tracked ignored','staged-new':'staged addition'}
assert observed['head']==candidate
assert fingerprint()==before
emit('Dirty snapshot execution assertions',{'working_beats_staged':True,'untracked_with_status_hidden_included':True,'deletion_included':True,'ignored_excluded':True,'force_added_ignored_included':True,'source_preserved':True})

# Drive actual wrapper while the local slot is held. A real localhost SSH refusal
# must leave it queued; releasing only our lock lets the real systemd scope run.
lock=open(D/'local.lock','a'); fcntl.flock(lock,fcntl.LOCK_EX)
auto_log=D/'auto-output.log'
with auto_log.open('w') as output:
    proc=subprocess.Popen([str(R/'bin/fm-heavy.sh'),'--class','test','--project','lab','--','python3','t/probe.py'],cwd=repo,env=env,stdout=output,stderr=subprocess.STDOUT)
    try:
        deadline=time.monotonic()+15
        while 'staying in the local queue' not in auto_log.read_text():
            assert proc.poll() is None
            if time.monotonic()>deadline: raise RuntimeError('No SSH fallback observed')
            time.sleep(.1)
        assert not (fm/'state/heavy-jobs.jsonl').exists()
        emit('Busy local slot before release',{'wrapper_pid':proc.pid,'no_job_completed':True,'output':auto_log.read_text().strip()})
        fcntl.flock(lock,fcntl.LOCK_UN); lock.close()
        assert proc.wait(timeout=20)==0
    finally:
        if not lock.closed: fcntl.flock(lock,fcntl.LOCK_UN); lock.close()
        if proc.poll() is None: proc.terminate(); proc.wait(timeout=10)
record=json.loads((fm/'state/heavy-jobs.jsonl').read_text().splitlines()[-1])
emit('Automatic offload fallback output',auto_log.read_text().strip()); emit('Automatic offload fallback record',record)
assert record['host']=='local' and record['fallback']=='unreachable' and record['exit']==0 and record['slot']==1
assert fingerprint()==before

# Real git add failure (unreadable untracked file), no PATH shim or injected tool.
(repo/'unreadable').write_text('cannot snapshot me\n'); (repo/'unreadable').chmod(0)
try:
    index_before=(repo/'.git/index').read_bytes()
    p=run([R/'bin/fm-heavy.sh','--class','test','--project','lab','--remote','--','python3','t/probe.py'])
    record=json.loads((fm/'state/heavy-jobs.jsonl').read_text().splitlines()[-1])
    emit('Snapshot failure fallback output',p.stdout.strip()); emit('Snapshot failure fallback record',record)
    assert record['host']=='local' and record['fallback']=='snapshot-failed' and record['exit']==0
    assert index_before==(repo/'.git/index').read_bytes()
    assert (repo/'unreadable').stat().st_mode & 0o777==0
finally:
    (repo/'unreadable').chmod(0o600); (repo/'unreadable').unlink()
assert fingerprint()==before

# A dirty failing test is run by the real runner and remains failed in result.json.
(repo/'t/probe.py').write_text(probe+'print("UNCOMMITTED_FAILURE_REACHED", flush=True)\nraise SystemExit(7)\n')
p=remote(R/'bin/fm-heavy-remote.sh',D/'failure.sample')
commits=[line.split()[0] for line in git('cat-file','--batch-all-objects','--batch-check=%(objectname) %(objecttype)').splitlines() if line.endswith(' commit')]
failed_candidate=next(sha for sha in commits if git('log','-1','--format=%s',sha)=='Snapshot of uncommitted work for remote tests' and git('show',sha+':t/probe.py').endswith('raise SystemExit(7)'))
out=exercise_runner('live-dirty-failure',failed_candidate,['python3','t/probe.py'],7)
assert 'UNCOMMITTED_FAILURE_REACHED' in out
(repo/'t/probe.py').write_text(probe)
assert fingerprint()==before
emit('Final isolation check',{'source_preserved':True,'runner_jobs_removed':True,'production_host_contacted':False})
(E/'live-transcript.log').write_text('\n'.join(transcript)+'\n')
(E/'live-job-records.jsonl').write_text((fm/'state/heavy-jobs.jsonl').read_text())
