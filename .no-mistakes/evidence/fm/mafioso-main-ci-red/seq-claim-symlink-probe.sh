#!/usr/bin/env bash
T=$(mktemp -d /tmp/fm-seqdrv/sym.XXXXXX); mkdir -p "$T/account"
export FM_REMOTE_JOB_STATE_ROOT="$T/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
. "$1/bin/fm-remote-job-lib.sh"
fm_remote_job_prepare_state "$T/account" || { echo "prep: $FM_REMOTE_JOB_ERROR"; exit 2; }
a=$(fm_remote_job_next_seq); C="$T/state/.seq-claims"
ln -s /dev/null "$C/$((a+1))"
b=$(fm_remote_job_next_seq); rc=$?
echo "first=$a second=$b rc=$rc (slot $((a+1)) is a symlink to /dev/null); claims dir mode=$(stat -c %a "$C")"
rm -rf "$T"
