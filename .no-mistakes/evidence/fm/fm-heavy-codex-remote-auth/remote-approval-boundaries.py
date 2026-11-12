import json, os, pathlib, shutil, subprocess, tempfile
repo=pathlib.Path.cwd()
evidence=pathlib.Path('/home/work/.no-mistakes/evidence/01M78EJVQ754X0B7H1ZZQDJF1D')
lab=pathlib.Path(tempfile.mkdtemp(prefix='approval-lab-',dir=repo/'.test-tmp'))
records=[]
try:
    root=lab/'root'; child=lab/'child'
    for home in (root,child):
        subprocess.run([str(repo/'bin/fm-lab-home.sh'),'create',str(home)],check=True,capture_output=True)
    (child/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={root}\n')
    marker=lab/'unexpected-command-ran'
    payload=['bash','-c',f'touch {marker}']
    cases=[
      ('missing-config',None,None,root,'test','420usa'),
      ('hostless-config','project 420usa\n',None,root,'test','420usa'),
      ('unapproved-command','host fm-mac\ncommand 420usa -- true\n',None,root,'test','420usa'),
      ('unapproved-e2e-command','host fm-mac\ncommand 420usa -- true\n',None,root,'e2e','420usa'),
      ('child-config-cannot-expand-root-approvals','host fm-mac\ncommand 420usa -- true\n','host child-host\nproject 420usa\n',child,'test','420usa'),
      ('child-config-cannot-create-missing-root-approval',None,'host child-host\nproject 420usa\n',child,'test','420usa'),
      ('unapproved-project','host fm-mac\nproject 420usa\n',None,root,'test','not-approved'),
      ('build-class-excluded','host fm-mac\nproject 420usa\n',None,root,'build','420usa'),
      ('malformed-config','host fm-mac\nhost child-host\nproject 420usa\n',None,root,'test','420usa'),
    ]
    for name, root_cfg, child_cfg, home, cls, project in cases:
        for h, cfg in ((root,root_cfg),(child,child_cfg)):
            path=h/'config/heavy-remote'
            if path.exists(): path.unlink()
            if cfg is not None: path.write_text(cfg)
        env=os.environ.copy()
        for key in list(env):
            if key.startswith('FM_') and key.endswith('_OVERRIDE'): del env[key]
        env['FM_HOME']=str(home)
        cmd=[str(repo/'bin/fm-heavy.sh'),'--class',cls,'--remote','--project',project,'--',*payload]
        p=subprocess.run(cmd,cwd=repo,env=env,text=True,capture_output=True,timeout=10)
        record=dict(scenario=name,command=cmd,FM_HOME=str(home),root_approval_config=root_cfg,child_approval_config=child_cfg,exit=p.returncode,stdout=p.stdout,stderr=p.stderr,payload_executed=marker.exists())
        records.append(record)
        assert p.returncode == 2, record
        assert not marker.exists(), record
    (evidence/'heavy-approval-boundaries.json').write_text(json.dumps(records,indent=2)+'\n')
    with (evidence/'heavy-approval-boundaries.txt').open('w') as out:
        for record in records:
            out.write(f"{record['scenario']}\n$ FM_HOME={record['FM_HOME']} {' '.join(record['command'])}\n{record['stdout']}{record['stderr']}exit={record['exit']}; payload_executed={record['payload_executed']}\n\n")
    print('Real fm-heavy refused all unauthorized requests before payload execution; transcript preserved.')
finally:
    shutil.rmtree(lab)
