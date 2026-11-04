#!/usr/bin/env bash
# Live drive of bin/fm-heavy.sh --remote: real ssh client, real sshd on loopback, real runner,
# real tar/sha256sum (no delay shims): the stop is timed by watching for the real process.
LABS=$(cat /tmp/fm-lab-ssh.path)
WT=/home/work/.no-mistakes/worktrees/5f69104d19ce/01M6KW1A7HBHYPDWWTC97M612A
EV=/home/work/.no-mistakes/evidence/01M6KW1A7HBHYPDWWTC97M612A
T=$EV/live-transcript.txt
BIG='head -c 2147483648 /dev/zero'
say() { printf '%s\n' "$*" | tee -a "$T"; }
mkcase() {  # <name> <job body> <fix|base>
  C=$LABS/cases/$1; rm -rf "$C" "$LABS"/host/.fm-heavy-remote; mkdir -p "$C/repo/t"
  BIN=$WT/bin; [ "$3" = fix ] || BIN=$LABS/base/bin
  "$WT/bin/fm-lab-home.sh" create "$C/home" >/dev/null
  printf '%s\n' 'host lab-mac' 'command bash t/job.sh' 'timeout 200' > "$C/home/config/heavy-remote"
  printf '%s\n' "$2" > "$C/repo/t/job.sh"
  git -C "$C/repo" init -q; git -C "$C/repo" add -A
  git -C "$C/repo" -c user.name=lab -c user.email=lab@example.invalid commit -q -m candidate
  ENVV=(env -u NO_MISTAKES_GATE PATH="$LABS/shim:$PATH" FM_HOME="$C/home" FM_HEAVY_LOCK="$C/slot.lock"
        FM_HEAVY_REMOTE_RECONNECT_TRIES=2 FM_HEAVY_REMOTE_RECONNECT_SLEEP=1)
}
rec() { tail -1 "$C/home/state/heavy-jobs.jsonl" 2>/dev/null | jq -c '{host,outcome,exit,job,candidate:(.candidate[0:8]),collect_s,cpu_usec}'; }
openrecs() { ls "$C/home/state/heavy-remote/unknown-lab-mac" 2>/dev/null | wc -l; }
hostjobs() { ls -A "$LABS/host/.fm-heavy-remote" 2>/dev/null | wc -l; }
report() {  # <label> <rc> <stderr file>
  say "[$1] wrapper exit=$2 record=$(rec) open_records=$(openrecs) host_jobs=$(hostjobs)"
  [ -s "$3" ] && sed 's/^/    stderr: /' "$3" | tee -a "$T"
  return 0
}
run_plain() {  # <label>
  (cd "$C/repo" && "${ENVV[@]}" "$BIN/fm-heavy.sh" --class test --task lab --project lab --remote -- bash t/job.sh >/dev/null 2>"$C/err")
  report "$1" $? "$C/err"
}
# stop_when <label> <pgrep -f regex> <signal> [group|one]: start the wrapper in its own
# group, wait for the real process to appear, then signal the group (or just that process).
stop_when() {
  local label=$1 pat=$2 s=$3 how=${4:-group} pid hit n=0
  (cd "$C/repo" && exec setsid "${ENVV[@]}" --default-signal=INT "$BIN/fm-heavy.sh" --class test --task lab --project lab --remote -- bash t/job.sh >/dev/null 2>"$C/err") &
  pid=$!
  until hit=$(pgrep -s "$pid" -f "$pat" | head -1) && [ -n "$hit" ]; do
    n=$((n + 1)); [ "$n" -lt 9000 ] || { say "[$label] never saw $pat"; kill -KILL -- "-$pid"; return 1; }
    kill -0 "$pid" 2>/dev/null || { say "[$label] wrapper ended before $pat appeared"; break; }
    sleep 0.02
  done
  say "[$label] live process at the stop: $(ps -o pid=,args= -p "$hit" | cut -c1-110)"
  if [ "$how" = group ]; then kill "-$s" -- "-$pid"; else kill "-$s" "$hit"; fi
  wait "$pid"
  report "$label" $? "$C/err"
}
