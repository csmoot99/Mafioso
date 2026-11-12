exec(pathlib_source := __import__('pathlib').Path('/home/work/.no-mistakes/evidence/01M78PKTATJJVSPR18T9AWQ6VC/live-heavy-validation.py').read_text().partition('\ntry:\n')[0])
import signal
try:
    daemonlog=open(EVID/'live-boundaries-sshd.log','w')
    DAEMON=subprocess.Popen([str(LAB/'openssh/usr/sbin/sshd'),'-D','-e','-f',str(LAB/'sshd_config')],stdout=daemonlog,stderr=subprocess.STDOUT,env=ENV)
    time.sleep(.3)
    # A worker's real linked-worktree layout, including source-common control files.
    source=LAB/'dirty/repo'; linked=LAB/'linked-worker'
    git(source,'worktree','add','--detach',linked,'HEAD')
    (linked/'tracked').write_text('staged\n'); git(linked,'add','tracked'); (linked/'tracked').write_text('modified\n')
    (linked/'deleted').unlink(); (linked/'new').write_text('untracked\n'); (linked/'.env').write_text('test-only-secret\n')
    (linked/'ignored-force').write_text('force-added\n'); git(linked,'add','-f','ignored-force')
    (linked/'link').symlink_to('tracked'); (linked/'execfile').write_text('#!/bin/sh\nexit 0\n'); (linked/'execfile').chmod(0o755)
    case=LAB/'linked'; home=case/'home'; (home/'config').mkdir(parents=True)
    (home/'config/heavy-remote').write_text('host fm-loopback\ncommand p -- bash t/job.sh\noffload\n')
    env=ENV|{'FM_HOME':str(home),'FM_HEAVY_LOCK':str(case/'slot.lock'),'PATH':str(LAB/'bin')+':'+ENV['PATH']}
    before=fingerprint(linked); common=fingerprint(source)
    p=heavy(linked,env,'--remote'); rec=save('linked-worktree',linked,home,p,before)
    assert rec['snapshot'] and rec['outcome']=='pass' and common==fingerprint(source)
    (EVID/'live/linked-worktree/common-source-before.json').write_text(json.dumps(common,indent=2)+'\n')
    (EVID/'live/linked-worktree/common-source-after.json').write_text(json.dumps(fingerprint(source),indent=2)+'\n')
    # The original dirty-tree bottleneck using the actual base scripts and slot.
    base=LAB/'base-bin'; base.mkdir()
    for src in (ROOT/'bin').iterdir():
        if src.name not in ('fm-heavy.sh','fm-heavy-remote.sh'): (base/src.name).symlink_to(src)
    for name in ('fm-heavy.sh','fm-heavy-remote.sh'):
        (base/name).write_text(run(['git','show','b5d0b6d1557caba0d8ef49b14b40bfbe4f80db94:bin/'+name]).stdout)
        (base/name).chmod(0o755)
    c,r,h,e=setup('regression','echo test-command-ran')
    (r/'dirty').write_text('uncommitted work\n')
    with open(c/'slot.lock','a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        baselineout=open(c/'base.log','w')
        proc=subprocess.Popen([str(base/'fm-heavy.sh'),'--class','test','--project','p','--','bash','t/job.sh'],cwd=r,env=e,stdout=baselineout,stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                if 'dirty-tree' in (c/'base.log').read_text(): break
                time.sleep(.05)
            else: raise AssertionError('baseline did not reproduce dirty-tree fallback')
            assert proc.poll() is None and not (h/'state/heavy-jobs.jsonl').exists(),'baseline should wait for local capacity'
            (EVID/'baseline-queued.log').write_text((c/'base.log').read_text()+'Observed: base wrapper remains queued with the sole local slot occupied.\n')
        finally:
            fcntl.flock(lock,fcntl.LOCK_UN)
            proc.wait(timeout=20); baselineout.close()
        (EVID/'baseline-heavy-job.json').write_text(json.dumps(record(h),indent=2)+'\n')
        assert record(h)['fallback']=='dirty-tree' and record(h)['host']=='local'
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        p=heavy(r,e); rec=save('regression-fixed',r,h,p)
        assert rec['host']=='fm-loopback' and rec['snapshot'] and rec['outcome']=='pass'
    # Interrupt real snapshot hashing; a signalled job may not execute anywhere.
    c,r,h,e=setup('cancel','echo forbidden-execution; touch executed')
    (r/'large-uncommitted').write_bytes(os.urandom(64*1024*1024))
    before=fingerprint(r); out=open(c/'cancel.log','w')
    proc=subprocess.Popen([str(ROOT/'bin/fm-heavy.sh'),'--class','test','--project','p','--remote','--','bash','t/job.sh'],cwd=r,env=e,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
    found=False
    try:
        for _ in range(1000):
            # Process inspection observes the real Git child, without replacing it.
            tree=subprocess.run(['ps','-eo','pid=,sid=,args='],capture_output=True,text=True).stdout
            for line in tree.splitlines():
                fields=line.split(None,2)
                if len(fields)==3 and fields[1]==str(proc.pid) and fields[2]=='git add -A':
                    found=True; break
            if found: os.killpg(proc.pid,signal.SIGTERM); break
            if proc.poll() is not None: break
            time.sleep(.003)
        proc.wait(timeout=30)
    finally:
        if proc.poll() is None: os.killpg(proc.pid,signal.SIGTERM); proc.wait(timeout=10)
        out.close()
    assert found,'could not observe real snapshot stage; cannot claim cancellation proof'
    assert proc.returncode==143 and not (r/'executed').exists()
    p=subprocess.CompletedProcess([],proc.returncode,(c/'cancel.log').read_text())
    rec=save('snapshot-cancellation',r,h,p,before)
    assert rec['outcome']=='cancelled' and rec['exit']==143
    assert not list((LAB/'ssh-home/.fm-heavy-remote').glob('*'))
    TRANS.append('Linked worktree, base-vs-target queued regression, and real snapshot cancellation passed.\n')
finally:
    if DAEMON:
        DAEMON.terminate()
        try: DAEMON.wait(timeout=5)
        except subprocess.TimeoutExpired: DAEMON.kill(); DAEMON.wait()
    (EVID/'live-boundaries-transcript.log').write_text('\n'.join(TRANS))
