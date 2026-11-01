#!/usr/bin/env bash
# usage: drive.sh <tree> <N> <rounds>
tree=$1 n=$2 rounds=$3
dup_rounds=0 fail_rounds=0
for r in $(seq 1 "$rounds"); do
  T=$(mktemp -d /tmp/fm-seqdrv/run.XXXXXX)
  mkdir -p "$T/account"
  export FM_REMOTE_JOB_STATE_ROOT="$T/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
  . "$tree/bin/fm-remote-job-lib.sh"
  fm_remote_job_prepare_state "$T/account" || { echo "prepare failed: $FM_REMOTE_JOB_ERROR"; exit 2; }
  rm -f -- "$T/state/seq"
  pids=()
  for i in $(seq 1 "$n"); do fm_remote_job_next_seq > "$T/out-$i" 2>/dev/null & pids+=("$!"); done
  bad=0; for p in "${pids[@]}"; do wait "$p" || bad=1; done
  got=$(cat "$T"/out-* | sort -n); dups=$(printf '%s\n' "$got" | uniq -d | tr '\n' ' ')
  [ "$got" = "$(seq 1 "$n")" ] || { dup_rounds=$((dup_rounds+1)); echo "round $r: NOT unique/monotonic; duplicates: ${dups:-none}; count=$(printf '%s\n' "$got" | grep -c .)"; }
  [ $bad = 0 ] || fail_rounds=$((fail_rounds+1))
  rm -rf "$T"
done
echo "tree=$tree N=$n rounds=$rounds bad_rounds=$dup_rounds allocator_failures=$fail_rounds"
