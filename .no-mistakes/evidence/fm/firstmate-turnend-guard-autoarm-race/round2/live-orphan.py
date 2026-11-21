import os,pathlib,subprocess,json,time,shutil,signal
root=pathlib.Path.cwd();lab=root/'.o';project=lab/'project';ev=root/'.phase-test/orphan-live';ev.mkdir(exist_ok=True)
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True)
project.mkdir();shutil.copytree(root/'bin',project/'bin');shutil.copytree(root/'docs',project/'docs')
(project/'AGENTS.md').write_text('Disposable orphan replacement test. Follow the supplied test prompt.\n')
subprocess.run(['git','init','-q',str(project)],check=True)
(lab/'config/supervision-host-off').touch();(project/'.claude').mkdir()
(project/'bin/e2e-autoarm.sh').write_text('''#!/usr/bin/env bash
payload=$(cat)
sid=$(printf '%s' "$payload" | jq -r .session_id)
printf '%s' "$payload" | "$(dirname "$0")/fm-claude-stop-autoarm.sh" > "$FM_HOME/state/hook.$sid.out" 2>&1
rc=$?
printf '%s\\n' "$rc" > "$FM_HOME/state/hook.$sid.rc"
cat "$FM_HOME/state/hook.$sid.out" >&2
exit "$rc"
''')
(project/'bin/e2e-finish.sh').write_text('''#!/usr/bin/env bash
rm -f "$FM_HOME/state/probe.check.sh" "$FM_HOME/state/probe.check-trust"
printf 'NEED_RETIRED\\n'
''')
for f in project.glob('bin/e2e-*'):f.chmod(0o700)
settings={'hooks':{'SessionStart':[{'hooks':[{'type':'command','command':'"$CLAUDE_PROJECT_DIR"/bin/fm-lock.sh'}]}],'Stop':[{'hooks':[{'type':'command','command':'"$CLAUDE_PROJECT_DIR"/bin/e2e-autoarm.sh','asyncRewake':True,'timeout':180}]}]}}
(project/'.claude/settings.json').write_text(json.dumps(settings))
(lab/'state/probe.check.sh').write_text('#!/usr/bin/env bash\nif [ -e "$FM_HOME/state/trigger" ]; then echo ready; fi\n');(lab/'state/probe.check.sh').chmod(0o700)
env=os.environ.copy()
for k in list(env):
 if k.endswith('_OVERRIDE') or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:env.pop(k,None)
env.update(FM_HOME=str(lab),FM_POLL='1',FM_CHECK_INTERVAL='1',FM_HEARTBEAT='600',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',CLAUDE_CODE_SEND_FEEDBACK='0')
subprocess.run([str(project/'bin/fm-check-register.sh'),'probe'],env=env,check=True)
socket=str(lab/'s')
def tm(*args,**kw):return subprocess.run(['tmux','-S',socket,*args],env=env,**kw)
def start(name):
 prompt='This is an isolated Stop-hook test. Initially reply exactly CYCLE0 and stop without tools. If Stop hook feedback wakes you, run exactly bin/e2e-finish.sh with Bash, reply ACK and stop. Do no other work.'
 tm('new-session','-d','-s',name,'-x','120','-y','40','-c',str(project),'claude','-p',prompt,'--dangerously-skip-permissions','--effort','low','--output-format','stream-json','--verbose',check=True)
def waitfor(pred,label,limit=120):
 for _ in range(limit):
  if pred():return
  time.sleep(1)
 raise RuntimeError('Timed out: '+label)
def text(p):return p.read_text() if p.exists() else ''
def epoch():return text(lab/'state/.claude-autoarm-epoch')
try:
 start('old')
 waitfor(lambda:'outcome=arming' in epoch() and (lab/'state/.watch.lock/pid').exists(),'old hook and real watcher')
 old_epoch=epoch(); old_pid=int(text(lab/'state/.lock').strip())
 (ev/'old-epoch.txt').write_text(old_epoch)
 os.kill(old_pid,signal.SIGKILL)
 # The exact lock-owning Claude died; its Stop hook and watcher are left intact.
 start('replacement')
 waitfor(lambda:epoch()!=old_epoch and 'epoch=2 ' in epoch() and 'outcome=arming' in epoch(),'replacement superseded claim')
 # Confirm attachment by finding a real arm child of the new hook, not just its claim.
 hook=int(epoch().split('owner_pid=')[1].split()[0])
 def arm_started():
  for d in pathlib.Path('/proc').iterdir():
   if not d.name.isdigit():continue
   try:
    st=(d/'stat').read_text().split(') ',1)[1].split()
    cmd=(d/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
    if int(st[1])==hook and str(project/'bin/fm-watch-arm.sh') in cmd:return True
   except (OSError,ValueError):pass
  return False
 waitfor(arm_started,'real replacement arm started')
 (ev/'replacement-epoch.txt').write_text(epoch());(lab/'state/trigger').touch()
 waitfor(lambda:'outcome=rewake' in epoch(),'replacement delivered wake')
 waitfor(lambda:len(list((lab/'state').glob('hook.*.rc')))>=2,'both hooks finished')
 rcs={p.name:text(p).strip() for p in (lab/'state').glob('hook.*.rc')}
 assert sorted(rcs.values())==['0','2'],rcs
 outputs={p.name:text(p) for p in (lab/'state').glob('hook.*.out')}
 assert sum('firstmate watcher wake' in s for s in outputs.values())==1,outputs
 waitfor(lambda:not (lab/'state/probe.check.sh').exists(),'real Claude handled wake')
 (ev/'final-state.json').write_text(json.dumps({p.name:text(p) for p in (lab/'state').iterdir() if p.is_file() and p.stat().st_size<100000},indent=2))
 cap=tm('capture-pane','-p','-J','-S','-','-t','replacement',text=True,capture_output=True);(ev/'replacement-transcript.txt').write_text(cap.stdout)
 print('PASS: killed only the original lab Claude; replacement superseded its open real hook, attached a real arm, delivered exactly one wake; orphan exited 0, replacement exited 2; real Claude retired the check.')
finally:
 tm('kill-server',capture_output=True)
 # Stop only this lab's remaining watcher through its public interface.
 subprocess.run([str(project/'bin/fm-watch-arm.sh'),'--stop'],env=env,capture_output=True)
 shutil.rmtree(lab)
