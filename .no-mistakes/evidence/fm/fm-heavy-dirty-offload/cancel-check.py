import pathlib, subprocess, os, fcntl, time, json, shutil, signal, hashlib
r=pathlib.Path.cwd(); d=r/'.phase-cancel'; d.mkdir(); e=pathlib.Path('/home/work/.no-mistakes/evidence/01M78S47EKGR7CFY9G3C4HKCMM')
repo=d/'repo'; repo.mkdir(); home=d/'home'; (home/'config').mkdir(parents=True); (d/'tmp').mkdir()
env=dict(os.environ,FM_HOME=str(home),FM_HEAVY_LOCK=str(d/'slot.lock'),TMPDIR=str(d/'tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Test',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Test',GIT_COMMITTER_EMAIL='test@example.invalid')
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE']: env.pop(key,None)
def git(*args): return subprocess.check_output(['git',*args],cwd=repo,env=env,text=True).strip()
proc=None
try:
    git('init','-q'); (repo/'job.sh').write_text('echo SHOULD_NOT_RUN\n'); git('add','-A'); git('commit','-qm','fixture')
    (repo/'dirty').write_text('current uncommitted content\n')
    (home/'config/heavy-remote').write_text('host 127.0.0.1\ncommand lab -- bash job.sh\noffload\n')
    index=(repo/'.git/index').read_bytes(); refs=git('show-ref'); head=git('rev-parse','HEAD')
    with open(d/'slot.lock','a') as lock, open(e/'live-cancellation.log','w+') as out:
        fcntl.flock(lock,fcntl.LOCK_EX)
        proc=subprocess.Popen([str(r/'bin/fm-heavy.sh'),'--class','test','--project','lab','--','bash','job.sh'],cwd=repo,env=env,stdout=out,stderr=subprocess.STDOUT)
        end=time.monotonic()+15
        while True:
            out.flush(); text=(e/'live-cancellation.log').read_text()
            if 'staying in the local queue' in text: break
            if proc.poll() is not None or time.monotonic()>end: raise RuntimeError(text)
            time.sleep(.05)
        proc.send_signal(signal.SIGTERM)
        code=proc.wait(timeout=10)
        assert code==143
        rec=json.loads((home/'state/heavy-jobs.jsonl').read_text())
        assert rec['started_at'] is None and rec['exit'] is None and rec['fallback']=='unreachable'
        assert 'SHOULD_NOT_RUN' not in (e/'live-cancellation.log').read_text()
        assert index==(repo/'.git/index').read_bytes() and refs==git('show-ref') and head==git('rev-parse','HEAD')
        out.write('\nSignal result: '+json.dumps({'wrapper_exit':code,'record':rec,'command_never_executed':True,'source_preserved':True})+'\n')
        fcntl.flock(lock,fcntl.LOCK_UN)
finally:
    if proc and proc.poll() is None: proc.terminate(); proc.wait(timeout=10)
    shutil.rmtree(d)
