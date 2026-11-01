#!/usr/bin/env bash
tree=$1
T=$(mktemp -d /tmp/fm-seqdrv/legacy.XXXXXX); mkdir -p "$T/account"
export FM_REMOTE_JOB_STATE_ROOT="$T/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
. "$tree/bin/fm-remote-job-lib.sh"
fm_remote_job_prepare_state "$T/account" || exit 2
C="$T/state/.seq-claims"
echo "# seed legacy directory claims 1-5 (as an older version made them), drop the seq hint"
rm -f -- "$T/state/seq"; for i in 1 2 3 4 5; do mkdir "$C/$i"; done
pids=(); for i in $(seq 1 20); do fm_remote_job_next_seq > "$T/o-$i" & pids+=("$!"); done
for p in "${pids[@]}"; do wait "$p" || echo "allocator failed"; done
got=$(cat "$T"/o-* | sort -n | tr '\n' ' '); echo "20 concurrent allocations returned: $got"
[ "$got" = "$(seq 6 25 | tr '\n' ' ')" ] && echo "PASS: legacy directory claims counted as taken; new claims unique 6..25" || echo "FAIL"
echo "claim kinds now on disk: dirs=$(find "$C" -mindepth 1 -maxdepth 1 -type d | wc -l) files=$(find "$C" -mindepth 1 -maxdepth 1 -type f | wc -l)"
echo "# adversarial: next value pre-occupied by a legacy directory while the hint points just below it"
mkdir "$C/26"; printf '25\n' > "$T/state/seq" 2>/dev/null
v=$(fm_remote_job_next_seq); echo "next allocation with legacy dir 26 present: $v"; [ "$v" -ge 27 ] && echo "PASS: skipped occupied legacy claim" || echo "FAIL"
echo "# adversarial: a symlink planted at the next claim slot"
nxt=$((v+1)); ln -s /tmp "$C/$nxt"
if out=$(fm_remote_job_next_seq 2>&1); then echo "FAIL: allocator handed out $out despite symlink at $nxt"; else echo "PASS: allocator refused (exit non-zero) with symlink planted at $nxt; /tmp untouched"; fi
echo "# reaping: expire legacy dir 1 and file claim 6, keep fresh ones"
touch -t 200001010000 "$C/1" "$C/6"; rm -f -- "$T/state/.seq-claims-reaped"
fm_remote_job_reap_stale "$T/account"
[ ! -e "$C/1" ] && echo "PASS: expired legacy directory claim reaped" || echo "FAIL: dir 1 survived"
[ ! -e "$C/6" ] && echo "PASS: expired file claim reaped" || echo "FAIL: file 6 survived"
[ -d "$C/2" ] && [ -f "$C/7" ] && echo "PASS: fresh dir claim 2 and fresh file claim 7 kept" || echo "FAIL: fresh claim reaped"
[ -L "$C/$nxt" ] && echo "symlink $nxt left in place (not matched by -type f/-type d)"
rm -rf "$T"
