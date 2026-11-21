import os,pathlib,subprocess,json,time,shutil,sys
mode=sys.argv[1]
root=pathlib.Path.cwd(); ev=pathlib.Path('/home/work/.no-mistakes/evidence/01M803CXX7TKJC35F8S804SHBH/round3')/mode; ev.mkdir(parents=True,exist_ok=True); lab=root/'.v'; project=lab/'project'
subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True)
project.mkdir(); (lab/'tmux').mkdir(); (lab/'config/supervision-host-off').touch()
shutil.copytree(root/'bin',project/'bin'); shutil.copytree(root/'docs',project/'docs')
if mode=='baseline':
 (project/'bin/fm-turnend-guard.sh').write_bytes(subprocess.check_output(['git','show','9e414d107ee7b463396146def893c21352ecd9a9:bin/fm-turnend-guard.sh']))
(project/'AGENTS.md').write_text('Disposable hook validation primary. Follow the supplied test prompt.\n')
subprocess.run(['git','init','-q',str(project)],check=True)
(project/'.claude').mkdir()
# Hook instrumentation preserves the public payload, exit code, and output.
(project/'bin/e2e-guard.sh').write_text('''#!/usr/bin/env bash
p=$(cat)
printf 'guard-start %s\\n' "$(date +%s.%N)" >> "$FM_HOME/state/timing.log"
printf '%s\\n' "$p" | "$(dirname "$0")/fm-turnend-guard.sh" --claude > "$FM_HOME/state/guard.out" 2> "$FM_HOME/state/guard.err"
r=$?
printf 'guard-end %s rc=%s\\n' "$(date +%s.%N)" "$r" >> "$FM_HOME/state/timing.log"
cat "$FM_HOME/state/guard.out"
cat "$FM_HOME/state/guard.err" >&2
exit "$r"
''')
(project/'bin/e2e-autoarm.sh').write_text('''#!/usr/bin/env bash
p=$(cat)
printf 'autoarm-delay-start %s\\n' "$(date +%s.%N)" >> "$FM_HOME/state/timing.log"
sleep 3
printf 'autoarm-exec %s\\n' "$(date +%s.%N)" >> "$FM_HOME/state/timing.log"
printf '%s\\n' "$p" | "$(dirname "$0")/fm-claude-stop-autoarm.sh"
''')
(project/'bin/e2e-finish.sh').write_text('''#!/usr/bin/env bash
rm -f "$FM_HOME/state/probe.check.sh" "$FM_HOME/state/probe.check-trust"
printf 'NEED_RETIRED\\n'
''')
for f in project.glob('bin/e2e-*'): f.chmod(0o700)
settings={'hooks':{'SessionStart':[{'hooks':[{'type':'command','command':'"$CLAUDE_PROJECT_DIR"/bin/fm-lock.sh'}]}], 'Stop':[{'hooks':[{'type':'command','command':'"$CLAUDE_PROJECT_DIR"/bin/e2e-guard.sh'},{'type':'command','command':'"$CLAUDE_PROJECT_DIR"/bin/e2e-autoarm.sh','asyncRewake':True,'timeout':120}]}]}}
if mode=='missing': settings['hooks']['Stop'][0]['hooks'].pop()
(project/'.claude/settings.json').write_text(json.dumps(settings))
(lab/'state/probe.check.sh').write_text('#!/usr/bin/env bash\nif [ -e "$FM_HOME/state/trigger" ]; then echo ready; fi\n')
(lab/'state/probe.check.sh').chmod(0o700)
env=os.environ.copy()
for k in list(env):
 if k.endswith('_OVERRIDE') or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),FM_POLL='1',FM_CHECK_INTERVAL='1',FM_HEARTBEAT='600',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',CLAUDE_CODE_SEND_FEEDBACK='0')
subprocess.run([str(project/'bin/fm-check-register.sh'),'probe'],env=env,check=True)
prompt='This is an isolated Stop-hook integration test. Do not inspect any files or execute tools on the initial turn. Reply exactly CYCLE0 and stop. If Stop hook feedback wakes you, run exactly bin/e2e-finish.sh once using Bash, reply ACK and stop. Do not arm watchers, delegate, or do other work.'
cmd=['tmux','-L','fm-lab','new-session','-d','-x','120','-y','40','-s','primary','-c',str(project),'-e','FM_HOME='+str(lab),'claude','-p',prompt,'--dangerously-skip-permissions','--effort','low','--output-format','stream-json','--verbose']
# The session command is the real harness, not a shell pretending to be it.
try:
 subprocess.run(cmd,env=env,check=True)
 subprocess.run(['tmux','-L','fm-lab','set-option','-w','-t','primary','remain-on-exit','on'],env=env,check=True)
 # Capture the live pane repeatedly; no UI input is needed for print mode.
 transcript=[]; triggered=False; last=''
 for i in range(120):
  cap=subprocess.run(['tmux','-L','fm-lab','capture-pane','-p','-J','-S','-','-t','primary'],env=env,text=True,capture_output=True)
  if cap.returncode==0 and cap.stdout != last:
   last=cap.stdout; (ev/'claude-live-pane.txt').write_text(last)
  if mode in ['baseline','missing'] and (state_path:=lab/'state/guard.err').exists() and 'TURN WOULD END BLIND' in state_path.read_text():
   (lab/'state/trigger').touch()
  state=lab/'state'
  if not triggered and (state/'.watch.lock/pid').exists() and (state/'.last-watcher-beat').exists():
   (ev/'live-healthy-state.json').write_text(json.dumps({f.name:f.read_text(errors='replace') for f in state.iterdir() if f.is_file() and f.name in ['.lock','.lock-session','.claude-autoarm-epoch','.last-watcher-beat','timing.log']},indent=2))
   (state/'trigger').touch(); triggered=True
  if (state/'timing.log').exists(): shutil.copy2(state/'timing.log',ev/'live-timing.log')
  if cap.returncode!=0 or '"type":"result"' in last: break
  time.sleep(1)
 (ev/'live-final-state.json').write_text(json.dumps({f.name:f.read_text(errors='replace') for f in (lab/'state').iterdir() if f.is_file() and f.stat().st_size <100000},indent=2))
 print(json.dumps({'triggered':triggered,'seconds':i,'last_capture':last[-2200:]}))
finally:
 subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True)
 shutil.rmtree(lab)
