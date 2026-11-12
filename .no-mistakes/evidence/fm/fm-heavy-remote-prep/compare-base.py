from pathlib import Path
import subprocess,os,json
root=Path.cwd();lab=root/'.nm-heavy-lab';ev=Path('/home/work/.no-mistakes/evidence/01M78QZ3R87TWXYC2Q39EHFTAP')
env=dict(os.environ,GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TMPDIR=str(lab/'tmp'),PATH=str(lab/'clientbin')+':'+os.environ['PATH'])
for key in ['GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(key,None)
repo=lab/'comparison-repo'
subprocess.run(['git','clone','-q',str(lab/'dependency-fallback/repo'),str(repo)],env=env,check=True)
results=[]
for variant,script,want in [('base',lab/'basebin/fm-heavy.sh',78),('target',root/'bin/fm-heavy.sh',0)]:
 home=lab/('comparison-'+variant);(home/'config').mkdir(parents=True);(home/'state').mkdir()
 (home/'config/heavy-remote').write_text('host heavy-loopback\nproject p\nimage fm-heavy-live-01m78q:2\ntimeout 30\n')
 runenv=dict(env,FM_HOME=str(home),FM_HEAVY_LOCK=str(home/'slot.lock'))
 with (ev/('comparison-'+variant+'.log')).open('w') as f:
  result=subprocess.run([str(script),'--class','test','--project','p','--remote','--','python3','t/job.py'],env=runenv,cwd=repo,stdout=f,stderr=subprocess.STDOUT)
 assert result.returncode==want,(variant,result.returncode)
 record=json.loads((home/'state/heavy-jobs.jsonl').read_text())
 if variant=='base':assert record['host']=='heavy-loopback' and record['outcome']=='failed' and record['exit']==78 and record['fallback'] is None
 else:assert record['host']=='local' and record['fallback']=='prepare-failed' and record['exit']==0
 results.append({'revision':variant,'exit':result.returncode,'record':record})
 (ev/('comparison-'+variant+'-record.json')).write_text(json.dumps(record,indent=2))
(ev/'base-target-comparison.json').write_text(json.dumps(results,indent=2))
print('Same real npm preparation failure: base exits 78 without running tests; target runs once locally and exits 0.')
