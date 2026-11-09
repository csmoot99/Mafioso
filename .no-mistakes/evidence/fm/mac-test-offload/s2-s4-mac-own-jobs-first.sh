#!/usr/bin/env bash
. "$(dirname "$0")/drive-lib.sh"
cfg 'host fm-mac' 'project *' 'offload' 'timeout 300'
mac "rm -f $TL $MACLAB/home/state/heavy-jobs.jsonl"
busy() { mac "FM_HEAVY_HOST_LOCK=$MACLAB/host.lock python3 - busy" < "$WT/bin/fm-heavy-remote-runner.py"; }

say "S2 the Mac's own test job (macOS fm-heavy.sh, no systemd-run) is running; this PC's queued job never goes there and the Mac job is not stopped"
macjob A 12 & ma=$!; sleep 3
echo "Mac lab slot: $(busy)"
hold_pc 6; h=$!
hv --class test --task s2 --project gamma-web -- t/check.sh GAMMA 1 "$TL"; echo "PC job rc=$?"; pcrec
release_pc $h
wait $ma; echo "Mac job A rc=$?"
say "S2b --remote while the Mac's own job runs: destination-busy, runs here"
macjob A2 8 & ma=$!; sleep 3
hv --class test --task s2b --project gamma-web --remote -- t/check.sh GAMMA-REMOTE 0; echo "PC job rc=$?"; pcrec
wait $ma; echo "Mac job A2 rc=$?"

say "S3 the Mac's worker queues its own next test while one runs: both go before this PC's queued job"
mac "rm -f $TL"
macjob B1 10 & mb1=$!; sleep 3
macjob B2 6 & mb2=$!; sleep 3
echo "Mac waiter markers while B2 queues: $(waiters); Mac lab slot: $(busy)"
hold_pc 120; h=$!
hv --class test --task s3 --project delta-svc -- t/check.sh DELTA 2 "$TL"; echo "PC job rc=$?"; pcrec
wait $mb1; echo "Mac B1 rc=$?"; wait $mb2; echo "Mac B2 rc=$?"
release_pc $h
echo "timeline:"; mac "cat $TL"

say "S4 this PC's job is running on the Mac when the Mac's worker starts its own test: the Mac job waits, the sent job is not stopped"
mac "rm -f $TL"
hold_pc 120; h=$!
hv --class test --task s4 --project epsilon-app -- t/check.sh EPSILON 12 "$TL" > "$LAB/s4.out" 2>&1 & pj=$!
until mac "grep -q 'EPSILON start' $TL 2>/dev/null"; do sleep 1; done
echo "sent job started on the Mac; Mac lab slot: $(busy)"
macjob C 2 & mc=$!; sleep 3
echo "Mac waiter markers while C queues: $(waiters)"
wait $pj; echo "PC job rc=$?"; cat "$LAB/s4.out"; pcrec
wait $mc; echo "Mac C rc=$?"
release_pc $h
echo "timeline:"; mac "cat $TL"

say "Mac's own job records (macOS: no memory scope, counters null)"; macrecs
say "Mac lab waiter markers left: $(waiters); Mac scratch job dirs left: $(mac 'ls -A ~/.fm-heavy-remote 2>/dev/null | grep -v linux | wc -l' | tr -d ' ')"
