#!/usr/bin/env bash
. "$(dirname "$0")/drive-lib.sh"
cfg 'host fm-mac' 'project *' 'offload' 'timeout 300'
busy() { mac "FM_HEAVY_HOST_LOCK=$MACLAB/host.lock python3 - busy" < "$WT/bin/fm-heavy-remote-runner.py"; }
mac "rm -f $TL"
say "S2 (re-run, local-safe command) the Mac's own test is running; this PC's queued job waits and takes this PC's slot when it frees"
macjob A 12 & ma=$!; sleep 3
echo "Mac lab slot: $(busy)"
hold_pc 6; h=$!
hv --class test --task s2 --project gamma-web -- t/check.sh GAMMA 1; echo "PC job rc=$?"; pcrec
release_pc $h
wait $ma; echo "Mac job A rc=$?"
echo "timeline:"; mac "cat $TL"; mac "tail -1 $MACLAB/home/state/heavy-jobs.jsonl" | jq -c '{project,exit,run_s}'
