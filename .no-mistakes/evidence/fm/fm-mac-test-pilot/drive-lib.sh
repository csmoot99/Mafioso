# Shared helpers for the live drives. LAB is a disposable fm-lab home; WT the run worktree.
WT=/home/work/.no-mistakes/worktrees/5f69104d19ce/01M6KK70Z00D0EW6CPCYVRJ4E3
EV=/home/work/.no-mistakes/evidence/01M6KK70Z00D0EW6CPCYVRJ4E3
LAB=$(cat /tmp/fm-lab-current-path)
export LAB
APPROVED='bash tests/fm-ci-select.test.sh'
cfg() { printf '%s\n' "$@" > "$LAB/config/heavy-remote"; }
# run through the real wrapper from the repository root; ssh goes via the pass-through shim
hv() { (cd "${REPO:-$WT}" && PATH="$LAB/shim:$PATH" FM_HOME="$LAB" "$WT/bin/fm-heavy.sh" "$@"); }
rec() { tail -1 "$LAB/state/heavy-jobs.jsonl" | jq -c '{host,outcome,exit,fallback,slot,wait_s,prepare_s,run_s,collect_s,started_at,candidate:(.candidate//""|.[0:12]),job}'; }
mac() { /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 fm-mac "$@"; }
mac_scratch() { echo "mac scratch entries: $(mac 'ls -A ~/.fm-heavy-remote 2>/dev/null | wc -l' | tr -d ' ')"; }
mac_owned() { echo "mac owned processes: $(mac "ps -axo pid=,command= | grep -E '[f]m-heavy-remote|[f]m-ci-select' | wc -l" | tr -d ' ')"; }
wait_started() { # until the job's "runner.py wait" call is in flight
  local i=0
  while [ "$i" -lt 240 ]; do grep -q 'runner.py wait' "$LAB/ssh.log" 2>/dev/null && return 0; sleep 0.25; i=$((i+1)); done
  echo "job never reached wait"; return 1
}
drop_wait_client() { # kill -9 this machine's real ssh client carrying the wait
  local p; p=$(pgrep -f '^/usr/bin/ssh .*runner.py wait' | head -1)
  [ -n "$p" ] && kill -9 "$p" && echo "killed real ssh client pid $p"
}
starts() { grep -c 'runner.py start' "$LAB/ssh.log"; }
open_records() { echo "open records: $(ls "$LAB/state/heavy-remote/unknown-fm-mac" 2>/dev/null | wc -l)"; }
H=(--class test --task fm-mac-test-pilot --project firstmate)
say() { printf '\n### %s\n' "$*"; }
