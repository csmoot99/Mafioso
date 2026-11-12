import os, sys, json, subprocess, pathlib, time, signal, shutil, fcntl
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.nm-heavy-lab'; EV=pathlib.Path('/home/work/.no-mistakes/evidence/01M78QZ3R87TWXYC2Q39EHFTAP')
REMOTE=LAB/'remotehome'; IMAGE='fm-heavy-live-01m78q:2'
ENV=dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='live-test',GIT_AUTHOR_EMAIL='live@example.invalid',GIT_COMMITTER_NAME='live-test',GIT_COMMITTER_EMAIL='live@example.invalid')
for key in ['GIT_DIR','GIT_COMMON_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE']:
 ENV.pop(key,None)
ENV['TMPDIR']=str(LAB/'tmp'); ENV['npm_config_cache']=str(LAB/'npm-cache')
SELECT=set(sys.argv[1:])
RESULTS=json.loads((EV/'live-results.json').read_text()) if (EV/'live-results.json').exists() else []
def run(args, **kw):
 return subprocess.run(list(map(str,args)),env=ENV,check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,**kw).stdout

def setup(name, package=None, image=IMAGE, limit=None, timeout=30, body=None):
 case=LAB/name; repo=case/'repo'; home=case/'home'
 (repo/'t').mkdir(parents=True); (home/'config').mkdir(parents=True);(home/'state').mkdir()
 proof=case/'executions.jsonl'
 script=body or f'''import os,json\nfrom pathlib import Path\np=Path.cwd()/'execution.json'\nwith p.open('a') as f: f.write(json.dumps({{'home':os.environ['HOME'],'pid':os.getpid()}})+'\\n')\nprint('TEST EXECUTED home='+os.environ['HOME'])\n'''
 (repo/'t/job.py').write_text(script)
 if package:
  package=dict(package,name='live-heavy-'+name)
  (repo/'package.json').write_text(json.dumps(package))
  args=['pnpm','install','--lockfile-only','--ignore-scripts'] if 'packageManager' in package else ['npm','install','--package-lock-only','--ignore-scripts','--no-audit','--no-fund']
  print(run(args,cwd=repo),flush=True)
 run(['git','init','-q'],cwd=repo);run(['git','add','-A'],cwd=repo);run(['git','commit','-qm','scenario'],cwd=repo)
 config=f'host heavy-loopback\nproject p env=npm_config_build_from_source=true\ntimeout {timeout}\n'
 if image:config+=f'image {image}\n'
 if limit is not None:config+=f'nofile {limit}\n'
 (home/'config/heavy-remote').write_text(config)
 env=dict(ENV,FM_HOME=str(home),FM_HEAVY_LOCK=str(case/'local.lock'),PATH=str(LAB/'clientbin')+':'+ENV['PATH'])
 argv=[str(ROOT/'bin/fm-heavy.sh'),'--class','test','--task',name,'--project','p','--remote','--','python3','t/job.py']
 return case,repo,home,proof,env,argv

def drive(name, package=None, image=IMAGE, limit=None, timeout=30, expected_exit=0, expected_host='local', fallback='prepare-failed', step=None, body=None, cancel=False, hold_local=False):
 if SELECT and name not in SELECT:return
 if (LAB/name).exists():shutil.rmtree(LAB/name)
 case,repo,home,proof,env,argv=setup(name,package,image,limit,timeout,body)
 log=EV/(name+'.log')
 locker=None
 if hold_local:
  locker=(case/'local.lock').open('w');fcntl.flock(locker,fcntl.LOCK_EX)
 with log.open('w') as out:
  out.write('COMMAND: bin/fm-heavy.sh --class test --task '+name+' --project p --remote -- python3 t/job.py\n');out.flush()
  proc=subprocess.Popen(argv,cwd=repo,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  if hold_local:
   end=time.monotonic()+40
   while 'staying in the local queue' not in log.read_text():
    assert proc.poll() is None,'exited while local slot held'
    assert time.monotonic()<end,'never reached local queue'
    time.sleep(.1)
   time.sleep(.5)
   assert proc.poll() is None and 'TEST EXECUTED' not in log.read_text(),'ran without the local slot'
   out.write('OBSERVED: preparation failed; command remains queued while local slot is held\n');out.flush()
   fcntl.flock(locker,fcntl.LOCK_UN);locker.close()
  if cancel:
   end=time.monotonic()+50
   while time.monotonic()<end:
    files=list((REMOTE/'.fm-heavy-remote').glob('*/preparation.json'))
    if any(json.loads(f.read_text()).get('step')=='dependencies' for f in files):break
    if proc.poll() is not None:raise AssertionError('exited before cancellation')
    time.sleep(.1)
   else:raise AssertionError('preparation did not start')
   time.sleep(1);os.killpg(proc.pid,signal.SIGTERM)
  code=proc.wait(timeout=150)
 assert code==expected_exit,(name,code,log.read_text())
 records=home/'state/heavy-jobs.jsonl'
 record=json.loads(records.read_text().splitlines()[-1]) if records.exists() else None
 if expected_exit==2:
  assert record is None and not proof.exists(),record
 else:
  assert record['host']==expected_host,record
  assert record.get('fallback')==fallback,record
  if step:assert record.get('preparation_step')==step,record
  if cancel:assert 'TEST EXECUTED' not in log.read_text(),log.read_text()
  elif expected_exit==0:
   assert log.read_text().count('TEST EXECUTED home=')==1,'must run exactly once'
   assert ('TEST EXECUTED home='+str(REMOTE) in log.read_text())==(expected_host!='local'),log.read_text()
  savedir=EV/name;savedir.mkdir(exist_ok=True)
  (savedir/'heavy-record.json').write_text(json.dumps(record,indent=2)+'\n')
  for artifact in (home/'state/heavy-remote').glob('*/result.json'):
   shutil.copy2(artifact,savedir/'remote-result.json');shutil.copy2(artifact.parent/'run.log',savedir/'remote-run.log')
  if proof.exists():shutil.copy2(proof,savedir/'executions.jsonl')
  print(name,json.dumps(record),flush=True)
 RESULTS[:]=[r for r in RESULTS if r['name']!=name]
 RESULTS.append({'name':name,'result':'pass','live':True,'evidence':str(log)})
 (EV/'live-results.json').write_text(json.dumps(RESULTS,indent=2))

# Install the machine's real Node/npm in the job's documented Linux runtime location.
runtime=REMOTE/'.fm-heavy-remote/linux/runtimes/node/24.22.1';(runtime/'bin').mkdir(parents=True,exist_ok=True)
if not (runtime/'bin/node').exists():shutil.copy2('/home/work/.local/lib/nodejs/bin/node',runtime/'bin/node')
(runtime/'lib/node_modules').mkdir(parents=True,exist_ok=True)
for tool,entry in [('npm','bin/npm-cli.js'),('pnpm','bin/pnpm.mjs')]:
 if not (runtime/'lib/node_modules'/tool).exists():shutil.copytree('/home/work/.local/lib/nodejs/lib/node_modules/'+tool,runtime/'lib/node_modules'/tool)
 if not (runtime/'bin'/tool).exists():(runtime/'bin'/tool).symlink_to('../lib/node_modules/'+tool+'/'+entry)

# Real npm lifecycle scripts force deterministic preparation errors, without replacing any tool.
base={'name':'live-heavy','version':'1.0.0','private':True}
fail=dict(base,scripts={'postinstall':'node -e "console.error(\'INTENTIONAL INSTALL FAILURE\'); process.exit(42)"'})
hang=dict(base,scripts={'postinstall':'node -e "console.log(\'INSTALL WAITING\'); setTimeout(()=>{},300000)"'})
many=dict(base,packageManager='pnpm@11.25.0',scripts={'postinstall':'''python3 -c "import resource; print('NOFILE',resource.getrlimit(resource.RLIMIT_NOFILE),flush=True); f=[open('/dev/null') for _ in range(4096)]; print('OPENED',len(f),'FILES')"'''})
proofbody=lambda name, extra='': f'''import os,json,subprocess\nfrom pathlib import Path\n{extra}\np=Path.cwd()/'execution.json'\nwith p.open('a') as f:f.write(json.dumps({{'home':os.environ['HOME']}})+'\\n')\nprint('TEST EXECUTED home='+os.environ['HOME'])\n'''
try:
 drive('native-build',dict(base,dependencies={'tree-sitter-html':'0.23.2'},scripts={'postinstall':'cd node_modules/tree-sitter-html && node-gyp rebuild'}),expected_host='heavy-loopback',fallback=None,timeout=120,body=proofbody('native-build',"print(subprocess.check_output(['node','-e',\"console.log('NATIVE MODULE LOADED',require('tree-sitter-html').name)\"],text=True))\nprint(subprocess.check_output(['g++','--version'],text=True).splitlines()[0])"))
 drive('many-files-default',many,expected_host='heavy-loopback',fallback=None)
 drive('many-files-custom',many,limit=8192,expected_host='heavy-loopback',fallback=None)
 drive('many-files-low-fallback',many,limit=256,step='dependencies')
 drive('runtime-fallback',dict(base,engines={'node':'>=99.0.0'}),step='runtime')
 drive('dependency-fallback',fail,step='dependencies')
 drive('prepare-failure-waits-local-slot',fail,step='dependencies',hold_local=True)
 drive('preparation-timeout-fallback',hang,timeout=3,step='dependencies')
 drive('container-start-fallback',image='fm-heavy-live-01m78q:missing',step='container-start')
 drive('preparation-cancel',hang,timeout=30,cancel=True,expected_exit=143,expected_host='heavy-loopback',fallback=None)
 drive('command-exit78',image=None,expected_exit=78,expected_host='heavy-loopback',fallback=None,body="print('PROJECT COMMAND STARTED; exit=78',flush=True)\nraise SystemExit(78)\n")
 drive('command-timeout',image=None,timeout=2,expected_exit=124,expected_host='heavy-loopback',fallback=None,body="import time\nprint('PROJECT COMMAND STARTED; waiting',flush=True)\ntime.sleep(300)\n")
 for value in [0,1048577,'oops']:
  drive('invalid-nofile-'+str(value),limit=value,expected_exit=2)
 print('ALL LIVE SCENARIOS PASSED',flush=True)
except BaseException:
 import traceback;traceback.print_exc();sys.exit(1)
