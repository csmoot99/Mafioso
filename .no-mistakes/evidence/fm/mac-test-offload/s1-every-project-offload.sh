#!/usr/bin/env bash
. "$(dirname "$0")/drive-lib.sh"
cfg 'host fm-mac' 'project *' 'offload' 'timeout 300'
say "config/heavy-remote"; cat "$LAB/config/heavy-remote"
say "Mac lab slot before: $(mac "FM_HEAVY_HOST_LOCK=$MACLAB/host.lock python3 - busy" < "$WT/bin/fm-heavy-remote-runner.py"; echo " rc=$?")"
hold_pc 60; holder=$!; sleep 0.5
say "S1a this PC's only slot is held; a test job of project alpha-shop queues"
hv --class test --task t1 --project alpha-shop -- t/check.sh ALPHA 2 "$TL"; echo "rc=$?"; pcrec
say "S1b another project, beta-api, e2e class"
hv --class e2e --task t2 --project beta-api -- t/check.sh BETA 1 "$TL"; echo "rc=$?"; pcrec
echo "local holder still alive: $(kill -0 $holder 2>/dev/null && echo yes || echo no)"; release_pc $holder
say "Mac timeline"; mac "cat $TL"
say "Mac scratch left behind: $(mac 'ls -A ~/.fm-heavy-remote 2>/dev/null | grep -v linux | wc -l' | tr -d ' ') job dirs"
