#!/usr/bin/env bash
. "$(dirname "$0")/drive-lib.sh"
cfg 'host fm-mac' 'project *' 'offload' 'timeout 300'
: > "$LAB/ssh.log"
say "S1c this PC's slot is free: an approved job under project * + offload runs here, no ssh"
flock -n "$LAB/pc.lock" true && echo "PC slot free"
hv --class test --task t3 --project alpha-shop -- t/check.sh ALPHA-LOCAL 0; echo "rc=$?"; pcrec
echo "ssh calls: $(wc -l < "$LAB/ssh.log")"
