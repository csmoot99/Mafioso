#!/usr/bin/env bash
# fm-heavy-summary.sh - where heavy-command time goes, per project, class and host.
#
# usage: fm-heavy-summary.sh [--since <epoch>] [--until <epoch>] [--executions] [--log <file>]
#
# Reads the log bin/fm-heavy.sh appends to (state/heavy-jobs.jsonl in the root
# Firstmate home; --log reads another file) and prints one row per project,
# command class and host: jobs, failed (non-zero exit), average and maximum slot
# wait in seconds, average and maximum run time in seconds, wait_pct (total wait
# over total wait plus run, the share of elapsed time spent queued), the largest
# peak memory in MiB, and unknown_peak (jobs with no peak memory reading). Averages
# and maxima use only the jobs that have the value; a column with no values
# prints "unknown", and a job without a task or project is grouped under
# "unknown". A job that ran on another machine through fm-heavy.sh --remote has its
# own row, with that host's average preparation (transfer and checkout) and
# result-collection seconds in the last columns; local jobs are host "local" and
# show "unknown" there, having neither stage.
# A job killed while queued has a wait but null run time and exit: it counts in
# jobs and in the wait columns, and not as failed.
# --since keeps jobs whose slot request is at or after that epoch.
# --executions prints TSV counts grouped by project, command_sha256 and
# source_sha256 over command_started_at in [since, until). Counts deduplicate
# execution_id, exclude drivers, reattachments, not-started and legacy records.
# Executions lacking command or source identity remain uncounted. Verified
# reconciled results in heavy-remote/ beside the log resolve unknown executions without changing the
# ledger. The unknown column counts unresolved jobs, using requested_at for the
# period when command start is unknown. It counts invocations, not test cases or
# equivalent environments; the wrapper header owns identity coverage limitations.
# Without --executions, --until filters requested_at with an exclusive upper bound.
#
# Exit status: 0 on a report (also an empty one), 2 on a usage error.
set -u
export LC_ALL=C

log=; since=0; until=999999999999; executions=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    --executions) executions=1; shift ;;
    --until) until=${2:-}; shift 2 || break ;;
    --since) since=${2:-}; shift 2 || break ;;
    --log) log=${2:-}; shift 2 || break ;;
    *) break ;;
  esac
done
[ "$#" -eq 0 ] || { echo "usage: fm-heavy-summary.sh [--since <epoch>] [--until <epoch>] [--executions] [--log <file>]" >&2; exit 2; }
case "$since" in ''|*[!0-9]*) echo "fm-heavy-summary.sh: --since needs epoch seconds" >&2; exit 2 ;; esac

case "$until" in ''|*[!0-9]*) echo "fm-heavy-summary.sh: --until needs epoch seconds" >&2; exit 2 ;; esac

if [ -z "$log" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fm-wake-lib.sh
  root=$(. "$SCRIPT_DIR/fm-wake-lib.sh" && fm_firstmate_root_home) || {
    echo "fm-heavy-summary.sh: cannot resolve the root Firstmate home" >&2; exit 2; }
  log=$root/state/heavy-jobs.jsonl
fi
[ -s "$log" ] || { echo "no heavy-command records in $log"; exit 0; }

if [ -n "$executions" ]; then
  evidence=()
  while IFS= read -r job; do
    case "$job" in ''|*[!0-9-]*) continue ;; esac
    for name in reconciled result; do
      path=$(dirname "$log")/heavy-remote/$job/$name.json
      [ ! -s "$path" ] || evidence+=("$path")
    done
  done < <(jq -r 'select(.entry_kind == "unknown" and .job == .execution_id) | .job // empty' "$log" | sort -u)
  jq -rs --argjson since "$since" --argjson until "$until" '
    . as $records
    | (map(select(.reconciled_at != null)) | INDEX(.job)) as $settled
    | (map(select(.schema == "fm-heavy-remote.v1")) | INDEX(.id)) as $results
    | [$records[] | select(.entry_kind == "execution" or .entry_kind == "unknown")
      | if .entry_kind == "unknown" then
          $settled[.job // ""] as $receipt | $results[.job // ""] as $result
          | if .job != null and .execution_id == .job and .candidate != null
              and $receipt.candidate == .candidate then
              if $receipt.outcome == "absent" then .entry_kind = "not-started"
              elif ($receipt.outcome | IN("pass", "failed", "timeout", "cancelled", "prepare-failed"))
                and $result.id == .job and $result.sha == .candidate
                and $result.command_sha256 == .command_sha256 then
                if ($result.command_started_at | type) == "number" and .source_sha256 != null then
                  .entry_kind = "execution" | .command_started_at = $result.command_started_at
                elif $receipt.outcome == "prepare-failed" then .entry_kind = "not-started"
                elif $receipt.outcome == "cancelled" and $result.outcome == "cancelled"
                  and ($result | has("command_started_at")) and $result.command_started_at == null
                  and ($result.preparation_step | IN("container-start", "services", "runtime", "dependencies", "browsers"))
                then .entry_kind = "not-started"
                else . end
              else . end
            else . end
        else . end
      | select((.entry_kind == "unknown") or (.entry_kind == "execution" and .execution_id != null
          and .command_sha256 != null and .source_sha256 != null and .command_started_at != null))
      | (.command_started_at // .requested_at) as $at | select($at >= $since and $at < $until)]
    | group_by([.project, .command_sha256, .source_sha256])
    | (["project", "command_sha256", "source_sha256", "executions", "unknown"] | @tsv),
      (.[] | group_by(.execution_id) | map(sort_by(.entry_kind != "execution") | .[0])
        | [ (.[0].project // "unknown"),
        (.[0].command_sha256 // "unknown"), (.[0].source_sha256 // "unknown"),
        (map(select(.entry_kind == "execution")) | length),
        (map(select(.entry_kind == "unknown")) | length)] | @tsv)
  ' "$log" ${evidence[@]+"${evidence[@]}"}
  exit "$?"
fi

jq -r --argjson since "$since" --argjson until "$until" -s '
  def avg: if length == 0 then "unknown" else (add / length | round) end;
  def max_or: if length == 0 then "unknown" else max end;
  [.[] | select(.requested_at >= $since and .requested_at < $until)]
  | group_by([(.project // "unknown"), .class, (.host // "local")])
  | map(. as $g | {
      project: ($g[0].project // "unknown"), class: $g[0].class, host: ($g[0].host // "local"), jobs: ($g | length),
      prep: ($g | map(.prepare_s | values) | avg), coll: ($g | map(.collect_s | values) | avg),
      failed: ($g | map(.exit | values | select(. != 0)) | length),
      wait_avg: ($g | map(.wait_s | values) | avg), wait_max: ($g | map(.wait_s | values) | max_or),
      run_avg: ($g | map(.run_s | values) | avg), run_max: ($g | map(.run_s | values) | max_or),
      wait_pct: (($g | map(.wait_s | values) | add // 0) as $w | ($g | map(.run_s | values) | add // 0) as $r
        | if ($w + $r) == 0 then "unknown" else ($w * 100 / ($w + $r) | round) end),
      peak_mib: ($g | map(.peak_memory_bytes | values) | if length == 0 then "unknown" else (max / 1048576 | round) end),
      unknown: ($g | map(select(.peak_memory_bytes == null)) | length)})
  | (["project","class","jobs","failed","wait_avg_s","wait_max_s","run_avg_s","run_max_s","wait_pct","peak_mib","unknown_peak","host","prepare_avg_s","collect_avg_s"] | @tsv),
    (.[] | [.project, .class, .jobs, .failed, .wait_avg, .wait_max, .run_avg, .run_max, .wait_pct, .peak_mib, .unknown, .host, .prep, .coll] | @tsv)
' "$log" | { if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi; }
