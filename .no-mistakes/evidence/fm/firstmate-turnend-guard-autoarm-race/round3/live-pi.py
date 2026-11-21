import os,pathlib,subprocess,shutil,json,time
root=pathlib.Path.cwd(); lab=root/'.p'; ev=pathlib.Path('/home/work/.no-mistakes/evidence/01M803CXX7TKJC35F8S804SHBH/round3/pi-live');ev.mkdir(parents=True,exist_ok=True)
project=lab/'project'; config=lab/'config'; home=lab/'home'
subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True)
project.mkdir(parents=True); config.mkdir(); (lab/'tmux').mkdir()
(project/'.pi/extensions').mkdir(parents=True)
shutil.copy2(root/'.pi/extensions/fm-calm.ts', project/'.pi/extensions/fm-calm.ts')
shutil.copytree(root/'.pi/extensions/lib',project/'.pi/extensions/lib')
(project/'AGENTS.md').write_text('Disposable rendering validation primary.\n')
subprocess.run(['git','init','-q',str(project)],check=True)
package=pathlib.Path('/home/work/firstmate/data/firstmate-turnend-guard-autoarm-race/typecheck/node_modules/@earendil-works/pi-coding-agent')
pi=str(package/'dist/cli.js')
(project/'node_modules/@earendil-works').mkdir(parents=True)
(project/'node_modules/@earendil-works/pi-coding-agent').symlink_to(package)
(project/'node_modules/@earendil-works/pi-tui').symlink_to(package/'node_modules/@earendil-works/pi-tui')
(project/'node_modules/typebox').symlink_to(package/'node_modules/typebox')
session=lab/'session.jsonl'; now='2026-11-21T17:00:00.000Z'
rows=[{'type':'session','version':3,'id':'11111111-1111-4111-8111-111111111111','timestamp':now,'cwd':str(project)}]
for i,txt in enumerate(['LIVE_ORDINARY_ROW','\u2063FIRSTMATE_OP: v1 watcher: LIVE_OPERATIONAL_ROW'],1):
 rows.append({'type':'message','id':f'a000000{i}','parentId':None if i==1 else 'a0000001','timestamp':now,'message':{'role':'user','content':[{'type':'text','text':txt}],'timestamp':i}})
session.write_text('\n'.join(json.dumps(row) for row in rows)+'\n')
env=os.environ.copy();env.update(FM_HOME=str(home),PI_CODING_AGENT_DIR=str(config),PI_OFFLINE='1',FM_OPERATIONAL_INPUT_SCRIPT=str(root/'bin/fm-operational-input.sh'))
for k in [k for k in env if k.endswith('_OVERRIDE')]+['TMUX','CLAUDECODE','CLAUDE_CODE_ENTRYPOINT']:
 env.pop(k,None)
env['TMUX_TMPDIR']=str(lab/'tmux')
def tm(*args,**kwargs):return subprocess.run(['tmux','-L','fm-lab',*args],env=env,**kwargs)
def launch():
 tm('new-session','-d','-x','120','-y','40','-s','pi','-c',str(project),'node',pi,'--tui-mode','regular','--approve','--no-skills','--no-prompt-templates','--no-context-files','--session',str(session),check=True)
def screen():return tm('capture-pane','-p','-J','-S','-','-t','pi',text=True,capture_output=True).stdout
def waitfor(check,label):
 for i in range(200):
  s=screen()
  if check(s): (ev/(label+'.txt')).write_text(s);return s
  time.sleep(.1)
 (ev/(label+'-failed.txt')).write_text(s);raise RuntimeError('Pi did not reach '+label)
def calm():
 tm('send-keys','-t','pi','-l','/calm',check=True);tm('send-keys','-t','pi','Enter',check=True)
try:
 launch()
 waitfor(lambda s:'LIVE_OPERATIONAL_ROW' in s and 'LIVE_ORDINARY_ROW' in s,'off')
 calm()
 waitfor(lambda s:'LIVE_ORDINARY_ROW' in s and 'LIVE_OPERATIONAL_ROW' not in s and (home/'config/calm').exists(),'on')
 tm('kill-session','-t','pi',check=True)
 launch()
 waitfor(lambda s:'LIVE_ORDINARY_ROW' in s and 'LIVE_OPERATIONAL_ROW' not in s,'resumed-on')
 calm()
 waitfor(lambda s:'LIVE_OPERATIONAL_ROW' in s and 'LIVE_ORDINARY_ROW' in s,'resumed-off')
 print('PASS: Pi 1.6.0 real TUI rendered ordinary and operational rows, toggled Calm, persisted and restored session, and revealed the operational row again.')
finally:
 tm('kill-server',capture_output=True)
 shutil.rmtree(lab)
