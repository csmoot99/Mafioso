# Shared helpers for this run's live drives against the real fm-mac.
# PC side: disposable lab FM_HOME ($LAB) with its own slot lock; this branch's bin/.
# Mac side: $MACLAB on fm-mac holds this branch's bin/ and a lab "host lock"; the SSH
# shim ($LAB/shim/ssh, a pass-through to /usr/bin/ssh) exports FM_HEAVY_HOST_LOCK to
# that lab lock so the Mac's real /tmp/fm-heavy.lock and its real workers are never touched.
WT=/home/work/.no-mistakes/worktrees/5f69104d19ce/01M70Q5R6MPDSMVZY93044P7P7
LAB=$(cat /tmp/fm-lab-mac-offload-path); MACLAB=$(cat "$LAB/maclab")
TL=$MACLAB/timeline
mac() { /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 fm-mac "$@"; }
cfg() { printf '%s\n' "$@" > "$LAB/config/heavy-remote"; }
# PC job through the real wrapper, from the fixture repo root
hv() { (cd "$LAB/proj" && PATH="$LAB/shim:$PATH" FM_HOME="$LAB" FM_HEAVY_LOCK="$LAB/pc.lock" FM_HEAVY_REMOTE_RECHECK=3 "$WT/bin/fm-heavy.sh" "$@"); }
# the Mac's own job through this branch's fm-heavy.sh on macOS, sharing the lab host lock
macjob() {  # <label> <seconds>
  mac "cd $MACLAB/repo && PATH=/opt/homebrew/bin:\$PATH FM_HOME=$MACLAB/home FM_HEAVY_LOCK=$MACLAB/host.lock $MACLAB/bin/fm-heavy.sh --class test --task mac-own --project mac-own-$1 -- sh -c 'echo \"MAC-$1 start \$(date +%T)\" >> $TL; sleep $2; echo \"MAC-$1 end \$(date +%T)\" >> $TL'"
}
hold_pc() { setsid flock "$LAB/pc.lock" sleep "$1" & }  # another PC heavy job holding this machine's only slot (own process group)
release_pc() { kill -- "-$1" 2>/dev/null; wait "$1" 2>/dev/null; }
pcrec() { tail -1 "$LAB/state/heavy-jobs.jsonl" | jq -c '{project,class,cmd,host,outcome,exit,fallback,wait_s,run_s}'; }
macrecs() { mac "cat $MACLAB/home/state/heavy-jobs.jsonl" | jq -c '{project,host,exit,slot,wait_s,run_s,peak_memory_bytes,cpu_usec}'; }
waiters() { mac "ls $MACLAB/host.lock.waiting 2>/dev/null | wc -l" | tr -d ' '; }
say() { printf '\n### %s  [%s]\n' "$*" "$(date +%T)"; }
