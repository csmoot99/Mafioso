#!/usr/bin/env bash
# replay.sh <lab> <id> <real-codex-log> <ceiling> <P>: truncate the real Codex
# session log at each compaction boundary and run the generated PostToolUse hook
# (with the given thresholds) on it, reporting whether a handoff was requested.
set -u
lab=$1 id=$2 log=$3 ceil=$4 p=$5
ROOT=/home/work/.no-mistakes/worktrees/5f69104d19ce/01M5GBFE0QEKRV5P3XY7Y8JVGE
gen=$(cat "$lab/state/$id.busy-gen")
tmp=$(mktemp -d); n=0
run() { # <last-line> <label>
  head -n "$1" "$log" > "$tmp/log.jsonl"
  rm -f "$lab/state/$id.context-handoff" "$lab/state/$id.status"
  out=$(printf '{"session_id":"s1","transcript_path":"%s","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":""}}\n' "$tmp/log.jsonl" \
    | "$ROOT/bin/fm-context-handoff.sh" posttooluse "$lab/state" "$id" --gen "$gen" --data-dir "$lab/data" --fm-root "$ROOT" --ceiling-pct "$ceil" --codex-threshold-pct "$p" 2>/dev/null)
  st=$(sed -n 's/.*[[:space:]]state=\([^[:space:]]*\).*/\1/p' "$lab/state/$id.context-handoff" 2>/dev/null | head -1); pct=$(sed -n 's/.*[[:space:]]pct=\([^[:space:]]*\).*/\1/p' "$lab/state/$id.context-handoff" 2>/dev/null | head -1); [ -z "$st" ] || st="$st(pct=$pct)"
  printf '%-58s marker=%-12s notice=%s\n' "$2" "${st:-none}" "$([ -n "$out" ] && echo yes || echo no)"
}
grep -n '"type":"compacted"' "$log" | cut -d: -f1 | head -3 | while read -r c; do
  n=$((n+1))
  run $((c-1)) "compaction $n: log ends at pre-compaction token_count"
  run "$c"     "compaction $n: log ends at compacted record (stale usage)"
  f=$(awk -v c="$c" 'NR>c && /"token_count"/ {print NR; exit}' "$log")
  run "$f"     "compaction $n: log ends at fresh post-compaction token_count"
done
rm -f "$lab/state/$id.context-handoff" "$lab/state/$id.status"; rm -rf "$tmp"
