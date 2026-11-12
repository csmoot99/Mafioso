import fcntl, json, os, pathlib, shlex, shutil, subprocess, tempfile, time
ROOT=pathlib.Path.cwd()
EV=pathlib.Path('/home/work/.no-mistakes/evidence/01M78DV6HCT112ZXRNHZY5FFRZ')
fixture=pathlib.Path(tempfile.mkdtemp(prefix='.nm-heavy-live-', dir=ROOT))
transcript=[]
env=os.environ.copy()
for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_ROOT','STATE','GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR']:
    env.pop(key,None)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live validation',GIT_AUTHOR_EMAIL='live@example.invalid',GIT_COMMITTER_NAME='Live validation',GIT_COMMITTER_EMAIL='live@example.invalid',TMPDIR=str(fixture))
home=fixture/'home'
repo=home/'projects/420usa'
lock=fixture/'slot.lock'
records=[]
def run(cmd,cwd=ROOT,expected=0):
    p=subprocess.run([str(x) for x in cmd],cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
    transcript.append('$ '+shlex.join([str(x) for x in cmd])+'\n'+p.stdout+'exit='+str(p.returncode)+'\n')
    assert p.returncode==expected,p.stdout
    return p.stdout

def last():
    record=json.loads((home/'state/heavy-jobs.jsonl').read_text().splitlines()[-1]); records.append(record)
    transcript.append('Persisted job: '+json.dumps(record)+'\n')
    return record

def heavy(project,cwd=repo,remote=False,expected=0):
    args=[ROOT/'bin/fm-heavy.sh','--class','test','--task','live-path']
    if project is not None: args+=['--project',project]
    if remote: args+=['--remote']
    return run(args+['--','bash','t/job.sh'],cwd=cwd,expected=expected)
try:
    run([ROOT/'bin/fm-lab-home.sh','create',home])
    env.update(FM_HOME=str(home),FM_HEAVY_LOCK=str(lock))
    repo.mkdir(parents=True)
    (repo/'t').mkdir()
    (repo/'t/job.sh').write_text('printf "job ran in %s at " "$PWD"; git rev-parse --short HEAD\n')
    run(['git','init','-q',repo]);run(['git','add','-A'],cwd=repo);run(['git','commit','-q','-m','fixture'],cwd=repo)
    worker=fixture/'worker';run(['git','worktree','add','-q','-b','worker',worker],cwd=repo)
    alias=fixture/'clone-link';alias.symlink_to(repo,target_is_directory=True)
    conf=home/'config/heavy-remote'
    conf.write_text('host fm-mac\nproject 420usa\noffload\n')
    for project,cwd in [('420usa',repo),(str(repo),repo),(str(repo)+'/',repo),(str(alias),repo),('.',repo),('../420usa',repo),(str(repo),worker)]:
        heavy(project,cwd)
        rec=last();assert rec['project']=='420usa' and rec['host']=='local' and rec['exit']==0
    # Unapproved projects stay queued locally while the slot is held, then run locally.
    for project in ['session-kit','localvault','dotfiles']:
        path=home/'projects'/project;path.mkdir()
        with open(lock,'a') as held:
            fcntl.flock(held,fcntl.LOCK_EX)
            cmd=[str(ROOT/'bin/fm-heavy.sh'),'--class','test','--task','live-unapproved','--project',str(path),'--','bash','t/job.sh']
            proc=subprocess.Popen(cmd,cwd=repo,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            time.sleep(1)
            assert proc.poll() is None, 'unapproved project should wait for local slot'
            fcntl.flock(held,fcntl.LOCK_UN)
            out=proc.communicate(timeout=20)[0]
            transcript.append('$ '+shlex.join(cmd)+' [local slot held for 1s, then released]\n'+out+'exit='+str(proc.returncode)+'\n')
            assert proc.returncode==0
        rec=last(); assert rec['project']==project and rec['host']=='local' and rec['fallback'] is None
        heavy(str(path),remote=True,expected=2)
    foreign=fixture/'elsewhere/420usa';foreign.mkdir(parents=True)
    for project in [str(foreign),str(repo/'t'),str(fixture/'missing/420usa'),None]:
        heavy(project,remote=True,expected=2)
    # Current repository outside projects is an accepted behavior retained by author decision.
    outside=fixture/'outside/420usa';outside.mkdir(parents=True)
    (outside/'t').mkdir();shutil.copyfile(repo/'t/job.sh',outside/'t/job.sh')
    run(['git','init','-q',outside]);run(['git','add','-A'],cwd=outside);run(['git','commit','-q','-m','fixture'],cwd=outside)
    for project in [str(outside),'.']:
        heavy(project,cwd=outside);rec=last();assert rec['project']=='420usa'
    # Absolute paths remain invalid approval declarations.
    conf.write_text('host fm-mac\nproject '+str(repo)+'\n')
    heavy(str(repo),remote=True,expected=2)
    conf.write_text('host fm-mac\nproject 420usa\noffload\n')
    (home/'config/heavy-commands').touch()
    for kind in ['ship','scout']:
        args=['--mode','no-mistakes'] if kind=='ship' else ['--scout']
        run([ROOT/'bin/fm-brief.sh','live-'+kind,str(repo)]+args)
        brief=(home/'data'/('live-'+kind)/'brief.md').read_text()
        section=brief.split('# Heavy commands\n',1)[1].split('\n# ',1)[0]
        (EV/('generated-'+kind+'-heavy.txt')).write_text(section)
        template=next(line for line in section.splitlines() if line.startswith('`FM_HOME='))
        words=shlex.split(template.strip('`'))
        words[words.index('--class')+1]='test'
        idx=words.index('--'); words=words[:idx+1]+['bash','t/job.sh']
        assert words[words.index('--project')+1]=='420usa'
        assignment=words.pop(0);assert assignment=='FM_HOME='+str(home)
        run(words,cwd=worker); rec=last(); assert rec['project']=='420usa' and rec['exit']==0
    (EV/'local-job-records.json').write_text(json.dumps(records,indent=2)+'\n')
    transcript.append('All live local scenarios completed. Real fm-heavy.sh, fm-brief.sh, git and systemd-run were used; no SSH, Docker, or systemd substitutes were on PATH.\n')
finally:
    (EV/'local-cli-transcript.txt').write_text('\n'.join(transcript))
    shutil.rmtree(fixture)
