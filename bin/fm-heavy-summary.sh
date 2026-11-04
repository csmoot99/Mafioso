#!/usr/bin/env bash
# fm-heavy-summary.sh - where heavy-command time goes, per project and class.
#
# usage: fm-heavy-summary.sh [--since <epoch>] [--log <file>]
#
# Reads the log bin/fm-heavy.sh appends to (state/heavy-jobs.jsonl in the root
# Firstmate home; --log reads another file) and prints one row per project and
# command class: jobs, failed (non-zero exit), average and maximum slot wait in
# seconds, average and maximum run time in seconds, wait% (total wait over total
# wait plus run, the share of elapsed time spent queued), the largest peak
# memory in MiB, and unknown (jobs with no peak memory reading). Averages and
# maxima use only the jobs that have the value; a column with no values prints
# "unknown", and a job without a task or project is grouped under "unknown".
# --since keeps jobs whose slot request is at or after that epoch.
#
# Exit status: 0 on a report (also an empty one), 2 on a usage error.
set -u
export LC_ALL=C

log=; since=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    --since) since=${2:-}; shift 2 || break ;;
    --log) log=${2:-}; shift 2 || break ;;
    *) break ;;
  esac
done
[ "$#" -eq 0 ] || { echo "usage: fm-heavy-summary.sh [--since <epoch>] [--log <file>]" >&2; exit 2; }
case "$since" in ''|*[!0-9]*) echo "fm-heavy-summary.sh: --since needs epoch seconds" >&2; exit 2 ;; esac

if [ -z "$log" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fm-wake-lib.sh
  root=$(. "$SCRIPT_DIR/fm-wake-lib.sh" && fm_firstmate_root_home) || {
    echo "fm-heavy-summary.sh: cannot resolve the root Firstmate home" >&2; exit 2; }
  log=$root/state/heavy-jobs.jsonl
fi
[ -s "$log" ] || { echo "no heavy-command records in $log"; exit 0; }

jq -r --argjson since "$since" -s '
  def avg: if length == 0 then "unknown" else (add / length | round) end;
  def max_or: if length == 0 then "unknown" else max end;
  [.[] | select(.requested_at >= $since)]
  | group_by([(.project // "unknown"), .class])
  | map(. as $g | {
      project: ($g[0].project // "unknown"), class: $g[0].class, jobs: ($g | length),
      failed: ($g | map(select(.exit != 0)) | length),
      wait_avg: ($g | map(.wait_s) | avg), wait_max: ($g | map(.wait_s) | max_or),
      run_avg: ($g | map(.run_s) | avg), run_max: ($g | map(.run_s) | max_or),
      wait_pct: (($g | map(.wait_s) | add) as $w | ($g | map(.run_s) | add) as $r
        | if ($w + $r) == 0 then "unknown" else ($w * 100 / ($w + $r) | round) end),
      peak_mib: ($g | map(.peak_memory_bytes | select(. != null)) | if length == 0 then "unknown" else (max / 1048576 | round) end),
      unknown: ($g | map(select(.peak_memory_bytes == null)) | length)})
  | (["project","class","jobs","failed","wait_avg_s","wait_max_s","run_avg_s","run_max_s","wait_pct","peak_mib","unknown_peak"] | @tsv),
    (.[] | [.project, .class, .jobs, .failed, .wait_avg, .wait_max, .run_avg, .run_max, .wait_pct, .peak_mib, .unknown] | @tsv)
' "$log" | { if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi; }
