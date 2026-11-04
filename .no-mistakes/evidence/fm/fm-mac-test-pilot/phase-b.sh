#!/usr/bin/env bash
. "$(dirname "$0")/drive-lib.sh"
set -u
cd "$WT"
cfg '# lab only: the approved portable command' 'host fm-mac' "command $APPROVED" 'timeout 600'

say "B1 opt-in pass on the real Mac, plain PATH, no shim"
echo "candidate HEAD $(git rev-parse HEAD)"
t0=$(date +%s)
FM_HOME="$LAB" "$WT/bin/fm-heavy.sh" "${H[@]}" --remote -- $APPROVED > "$LAB/b1.out" 2> "$LAB/b1.err"; rc=$?
echo "rc=$rc elapsed=$(( $(date +%s)-t0 ))s"; grep -E '^(ok|not ok)' "$LAB/b1.out"; echo "too-many-open-files lines: $(grep -c 'Too many open files' "$LAB/b1.out")"
cat "$LAB/b1.err"; rec
J=$(tail -1 "$LAB/state/heavy-jobs.jsonl" | jq -r .job); D=$LAB/state/heavy-remote/$J
ls "$D"; jq -c '{schema,id,sha,tree,outcome,exit_code,run_s,cpu_usec,artifacts}' "$D/result.json"
echo "local run.log: $(wc -c < "$D/run.log") bytes $(sha256sum "$D/run.log" | cut -d' ' -f1)"
open_records; mac_scratch; mac_owned; echo "mac open-file limit over ssh: $(mac 'ulimit -n')"

say "B3 timeout 5 s on the real Mac: exit 124, only the job's own processes stop"
cfg 'host fm-mac' "command $APPROVED" 'timeout 5'
S=$(mac 'nohup sleep 120 >/dev/null 2>&1 & echo $!'); echo "unrelated Mac process pid $S"
hv "${H[@]}" --remote -- $APPROVED > "$LAB/b3.out" 2> "$LAB/b3.err"; echo "rc=$?"; cat "$LAB/b3.err"; rec
echo "unrelated Mac process alive: $(mac "kill -0 $S 2>/dev/null && echo yes || echo NO")"; mac "kill $S" 
open_records; mac_scratch; mac_owned

say "B4 group TERM while running on the real Mac: 143 cancelled, no local run"
cfg 'host fm-mac' "command $APPROVED" 'timeout 600'
: > "$LAB/ssh.log"
S=$(mac 'nohup sleep 120 >/dev/null 2>&1 & echo $!')
setsid bash -c 'cd "$1" && PATH="$2/shim:$PATH" FM_HOME="$2" exec "$1/bin/fm-heavy.sh" --class test --task fm-mac-test-pilot --project firstmate --remote -- bash tests/fm-ci-select.test.sh' _ "$WT" "$LAB" > "$LAB/b4.out" 2> "$LAB/b4.err" &
pid=$!; wait_started; sleep 4; echo "mid-run: $(mac_owned)"; kill -TERM -- "-$pid"; wait "$pid"; echo "rc=$?"; cat "$LAB/b4.err"; rec
echo "local records for this job: $(tail -1 "$LAB/state/heavy-jobs.jsonl" | jq -r .host)"
echo "unrelated Mac process alive: $(mac "kill -0 $S 2>/dev/null && echo yes || echo NO")"; mac "kill $S"
open_records; mac_scratch; mac_owned

say "B7 the job's own supervisor and group are SIGKILLed on the Mac: lost, never green"
: > "$LAB/ssh.log"
hv "${H[@]}" --remote -- $APPROVED > "$LAB/b7.out" 2> "$LAB/b7.err" &
pid=$!; wait_started; sleep 3
mac 'cd ~/.fm-heavy-remote/* && python3 -c "import json,os; o=json.load(open(\"owner.json\")); os.kill(o[\"supervisor_pid\"],9); os.killpg(o[\"group\"],9); print(\"killed owned supervisor and group\")"'
wait "$pid"; echo "rc=$?"; cat "$LAB/b7.err"; rec; open_records; mac_scratch; mac_owned

say "B5 real ssh client killed mid-wait, plus a second request while the first runs"
: > "$LAB/ssh.log"
hv "${H[@]}" --remote -- $APPROVED > "$LAB/b5.out" 2> "$LAB/b5.err" &
pid=$!; wait_started; sleep 2; drop_wait_client
hv "${H[@]}" --remote -- $APPROVED > "$LAB/b5b.out" 2> "$LAB/b5b.err"; echo "second request rc=$?"; cat "$LAB/b5b.err"
wait "$pid"; echo "first request rc=$?"; cat "$LAB/b5.err"
tail -2 "$LAB/state/heavy-jobs.jsonl" | jq -c '{host,outcome,exit,fallback,slot,job}'
echo "remote starts: $(starts); ok lines in first run's relayed log: $(grep -c '^ok' "$LAB/b5.out")"; open_records; mac_scratch; mac_owned

say "B6 a real job outlives the link: unknown 75, then reconcile"
: > "$LAB/ssh.log"
(export FM_HEAVY_REMOTE_RECONNECT_TRIES=1; hv "${H[@]}" --remote -- $APPROVED > "$LAB/b6a.out" 2> "$LAB/b6a.err") &
pid=$!; wait_started; sleep 1; touch "$LAB/outage"; drop_wait_client
wait "$pid"; echo "first request rc=$?"; rm -f "$LAB/outage"; cat "$LAB/b6a.err"; rec
J=$(tail -1 "$LAB/state/heavy-jobs.jsonl" | jq -r .job)
open_records; mac_scratch; echo "host status of $J: $(mac "python3 .fm-heavy-remote/$J/runner.py status .fm-heavy-remote/$J")"
echo '--- second request while it still runs'
hv "${H[@]}" --remote -- $APPROVED > "$LAB/b6b.out" 2> "$LAB/b6b.err"; echo "second request rc=$?"; cat "$LAB/b6b.err"; rec
echo "remote starts so far: $(starts)"; open_records
echo '--- third request after it finished'
i=0; until [ "$(mac "python3 .fm-heavy-remote/$J/runner.py status .fm-heavy-remote/$J")" = done ] || [ "$i" -ge 40 ]; do sleep 3; i=$((i+1)); done
hv "${H[@]}" --remote -- $APPROVED > "$LAB/b6c.out" 2> "$LAB/b6c.err"; echo "third request rc=$?"; cat "$LAB/b6c.err"; rec
echo "reconciled.json: $(cat "$LAB/state/heavy-remote/$J/reconciled.json")"
echo "remote starts: $(starts)"; open_records; mac_scratch; mac_owned

say "B2 the same command locally, then the summary"
hv "${H[@]}" -- $APPROVED > "$LAB/b2.out" 2> "$LAB/b2.err"; echo "rc=$?"; grep -cE '^ok' "$LAB/b2.out"; rec
FM_HOME="$LAB" "$WT/bin/fm-heavy-summary.sh"
echo "worktree dirty files: $(git -C "$WT" status --porcelain | wc -l)"
