#!/usr/bin/env bash
# fm-context-handoff.sh - the opt-in worker context handoff: instead of
# auto-compacting at its context threshold, a Claude or Codex worker writes a
# handoff document and firstmate replaces it with a fresh worker that
# continues the same task from that document.
#
# The whole feature is off unless the home holds the presence flag
# config/worker-context-handoff (docs/configuration.md "Worker context
# handoff"). bin/fm-spawn.sh reads the flag at every claude or codex ship or
# scout launch and relaunch, validates its optional `fallback-pct=<N>`,
# Claude-only `claude-fallback-pct=<N>`, and `codex-handoff-pct=<P>` lines
# (see fm-spawn's header for the exact rule), and only then wires the two
# hook commands below beside the busy-state hooks: into a claude worker's
# .claude/settings.local.json, and as session-flag hooks on a codex worker's
# launch command. A secondmate, the primary, and every other harness never
# get them.
#
# Codex mode (--codex-threshold-pct P on either hook): Codex's PreCompact
# cannot block a compaction (codex-cli 0.162.1 reports exit 2 as a failed hook
# and a block decision as invalid output, then compacts), so a codex worker
# gets the same outcome another way. fm-spawn moves Codex's own compaction
# to the fallback ceiling, PostToolUse watches the handoff threshold P itself
# in Codex's session log, and PreCompact only records that the fallback
# compaction arrived. With codex-handoff-pct configured, P is above the
# fallback ceiling instead: Codex compacts normally at the ceiling every time,
# PreCompact leaves the handoff check armed, and PostToolUse requests a handoff
# only if usage still reaches P. Both always exit 0; the records, status events, notice,
# and replacement are exactly the Claude ones.
#
# Haiku mode (--haiku-cap on both Claude hooks): fm-spawn selects this for
# an explicitly selected Haiku model. The absolute threshold is 80000 prompt
# tokens, including cache reads and cache creation, instead of the percentage.
# PostToolUse requests the handoff at the first observed crossing; PreCompact
# also checks it, but always allows compaction, including below the cap.
# Compaction never clears a pending handoff. This is a hook-observed threshold,
# not a pre-request token limiter: one response can overshoot it before a hook.
# A crossing means the T1 task was misclassified: the due marker carries
# `reclassify=T2`, its note says the task must be reclassified to T2, and
# `replace` refuses to relaunch it on a Haiku model.
# Other models and launches without the opt-in flag retain their behavior.
#
# Subcommands:
#
#   precompact <state-dir> <id> --gen G --data-dir D --fm-root R [--ceiling-pct N] [--codex-threshold-pct P | --haiku-cap]
#       Claude PreCompact hook (matcher `auto`; a manual /compact is never
#       blocked). Reads the hook payload on stdin. Except in Haiku mode above,
#       the threshold is Claude's
#       own: the hook fires exactly when auto-compaction would, which
#       CLAUDE_AUTOCOMPACT_PCT_OVERRIDE from config/launch-env places at the
#       home's chosen percentage. Exit 2 blocks the compaction (Claude skips a
#       proactive compaction and the session continues uncompacted); exit 0
#       lets it proceed. Decision, per incarnation:
#         - no marker yet: derive the window and ceiling (below), write the
#           handoff-due marker bound to G, append one `note:` status event so
#           firstmate learns the handoff is due, and block;
#         - marker `due` and usage below the ceiling: block silently;
#         - marker `due` and usage at or past the ceiling: move the marker to
#           `fallback`, append one `note:` status event saying the handoff
#           did not happen in time, and let compaction proceed (later fires
#           proceed silently);
#         - marker `no-override`: proceed silently.
#       Without a usable override the hook only ever fires near the full
#       window, too late for a safe handoff, so it writes a `no-override`
#       marker, appends one `note:` saying why, and proceeds. A usable
#       override is an integer from 1 to N-1, N being the fallback ceiling
#       percentage below: at N and above the ceiling would already be behind
#       the first fire.
#       Fallback ceiling: at the first block the transcript's latest
#       assistant `message.usage` (input_tokens + cache_read_input_tokens +
#       cache_creation_input_tokens, which is what Claude counts as context)
#       sits at the configured percentage P of the window, so the window is
#       usage * 100 / P and the ceiling is N percent of that (usage * N /
#       P). N is the --ceiling-pct argument fm-spawn bakes into the hook
#       command from the flag file's optional `claude-fallback-pct=<N>` line,
#       else its `fallback-pct=<N>` line (fm-spawn validates it; the hook
#       only refuses a value it could never have baked), and a hook command
#       written without the argument means 80, so a worker launched before
#       the setting existed keeps its ceiling.
#       Claude clamps its own threshold near 83 percent because it reserves a
#       response buffer, so 80 is the highest N and keeps the fallback
#       compaction inside the space Claude itself treats as safe. The marker
#       records both the derived token ceiling and N. The estimate is
#       conservative: if Claude measures its percentage against a window
#       smaller than the model's full one, the derived ceiling is lower, never
#       higher.
#       A gen that no longer matches the armed incarnation, an unreadable
#       payload, a missing transcript, or any other error lets compaction
#       proceed: this hook must never break Claude's own lifecycle, exactly as
#       the busy hooks tolerate a refused event.
#       With --codex-threshold-pct (Codex mode above) it never blocks: on an
#       auto compaction while the marker is `due`, it moves the marker to
#       `fallback` and notes the missed handoff exactly as the ceiling path
#       does; with no marker for G yet (usage jumped past the threshold and
#       the ceiling between two tool calls) it writes a `fallback` marker and
#       the same note, so this incarnation hands off no later, as on Claude.
#       When P is above N instead, it leaves the marker untouched on every
#       compaction so the later handoff check remains armed.
#
#   posttooluse <state-dir> <id> --gen G --data-dir D --fm-root R [--ceiling-pct N] [--codex-threshold-pct P | --haiku-cap]
#       Claude PostToolUse hook, every tool. Except in Haiku mode above,
#       with no marker for the task it is
#       one file-existence test and exits 0 with no output, so the common path
#       costs nothing. In Codex mode the no-marker path instead reads the
#       latest `token_count` record in the payload's transcript_path (the
#       Codex session log), ignoring any written before the log's latest
#       `compacted` record: once `last_token_usage.total_tokens` reaches P
#       percent of its `model_context_window`, it writes the `due` marker and
#       note the Claude PreCompact writes at its first block (window from the
#       log, ceiling N percent of it) and delivers the notice on this call.
#       With a `due` marker for gen G and no handoff file yet,
#       it returns hookSpecificOutput.additionalContext telling the worker to
#       finish the step in hand and start nothing new, read the handoff skill
#       at its absolute path, write the handoff to the exact durable path the
#       marker names, then report it and end the turn. The notice is
#       delivered on the first call and then every sixth call while the
#       handoff is still missing, never on every call. Once the handoff file
#       exists it stays silent.
#
#   replace <id> [--harness H] [--model M] [--effort E]
#       Firstmate side, FM_HOME-resolved like bin/fm-control.sh. Loaded by the
#       context-handoff skill on the worker's `blocked [key=context-handoff-N]`
#       handoff-ready event. Checks that the task's marker names a handoff, that
#       the marker is bound to the currently armed incarnation, and that the
#       handoff exists and holds more than whitespace; refuses with a precise
#       message otherwise. Then drives `fm-control.sh <id> relaunch --note`
#       (the note tells the replacement to start at the handoff's continuation
#       header and read no earlier handoff unless it names one), which keeps
#       the same isolated copy and owns its own checkpoint, journal, and
#       rollback. --harness, --model, and --effort pass through to that
#       relaunch; without them it keeps the same harness, model, and effort.
#       A marker carrying `reclassify=T2` (the Haiku cap) is refused unless
#       --model names a model other than Haiku; the refusal names the T2 route
#       from config/crew-dispatch.json, which firstmate picks. The relaunch arms a fresh
#       incarnation and clears the marker, so the replacement's next threshold
#       crossing hands off again. On success it appends the closing
#       `resolved [key=context-handoff-N]` event. FM_CONTROL_BIN overrides the
#       control plane's path for tests only.
#
# Durable records:
#   state/<id>.context-handoff   one line, atomically replaced, mode 600:
#       v1 gen=G state=due|fallback|no-override seq=N handoff=<path>
#          key=context-handoff-N usage=U pct=P window=W ceiling=C
#          [reclassify=T2] notices=K calls=M at=<epoch>
#       bin/fm-spawn.sh removes it at every launch and relaunch of the task
#       (a marker never outlives its incarnation) and bin/fm-teardown.sh at
#       teardown. Safe to delete: the next auto fire starts over.
#   data/<id>/handoff-<N>.md     the handoff itself, written by the worker; N
#       is one more than the handoffs already there, so an earlier handoff is
#       never overwritten and survives teardown with the task's other data.
#
# Status events (bin/fm-classify-lib.sh owns the syntax):
#   note [at=E]: context handoff due: ...       informational, handoff-due
#   note [at=E]: context handoff missed: ...    informational, fallback taken
#   note [at=E]: context handoff skipped: ...   informational, no usable override
#   blocked [key=context-handoff-N] [at=E]: context handoff ready at <path>
#       written by the WORKER per the skill; a captain-relevant verb, so it
#       wakes firstmate as actionable, and a keyed one, so it stays open until
#   resolved [key=context-handoff-N] [at=E]: replaced the worker from context handoff <path>
#       which `replace` appends after the relaunch succeeds.
#
# Exit codes: precompact 0 proceed, 2 block; posttooluse always 0; replace 0
# replaced, 1 refused or failed, 2 usage.
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  fm-context-handoff.sh precompact <state-dir> <id> --gen G --data-dir D --fm-root R [--ceiling-pct N] [--codex-threshold-pct P | --haiku-cap]   (PreCompact payload on stdin)
  fm-context-handoff.sh posttooluse <state-dir> <id> --gen G --data-dir D --fm-root R [--ceiling-pct N] [--codex-threshold-pct P | --haiku-cap]  (PostToolUse payload on stdin)
  fm-context-handoff.sh replace <id> [--harness H] [--model M] [--effort E]           (FM_HOME-resolved)
See the header comment for the full contract.
EOF
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

case "${1:-}" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

CMD=${1:-}
case "$CMD" in
  precompact|posttooluse|replace) shift ;;
  *) usage ;;
esac

# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

NOTICE_EVERY=6
CEILING_PCT_DEFAULT=80

id_ok() { case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

marker_path() { printf '%s/%s.context-handoff' "$1" "$2"; }

# marker_field <marker-line> <field> -> value (empty when absent)
marker_field() {
  local rest
  case "$1" in
    *" $2="*) rest=${1#* "$2"=}; printf '%s' "${rest%% *}" ;;
    "$2="*) rest=${1#"$2"=}; printf '%s' "${rest%% *}" ;;
  esac
}

# marker_write <marker-path> <line>: atomic replace, private mode.
marker_write() {
  local tmp="$1.tmp.$$"
  ( umask 077; printf '%s\n' "$2" > "$tmp" ) && mv -f "$tmp" "$1"
}

# status_note <status-file> <line-without-stamp>: append one stamped event.
status_note() {
  local epoch verb rest
  epoch=$(date +%s 2>/dev/null || true)
  verb=${2%%:*}; rest=${2#*:}
  case "$epoch" in ''|*[!0-9]*) printf '%s\n' "$2" >> "$1" ;; *) printf '%s [at=%s]:%s\n' "$verb" "$epoch" "$rest" >> "$1" ;; esac
}

# payload_field <field>: one string field of the JSON payload held in PAYLOAD.
payload_field() {
  printf '%s' "$PAYLOAD" | perl -MJSON::PP -e '
    local $/; my $t = <STDIN>; my $d = eval { JSON::PP->new->decode($t) };
    exit 1 unless ref $d eq "HASH";
    my $v = $d->{$ARGV[0]}; exit 1 unless defined $v && !ref $v;
    print $v;' -- "$1" 2>/dev/null
}

# transcript_usage <transcript-path> [scanner] -> what the scanner prints for
# the latest usage record, reading a bounded tail first and the whole file only
# when the tail holds none. The default scanner reads a Claude transcript: the
# context tokens of the latest assistant record carrying message.usage (input +
# cache_read + cache_creation). _codex_usage_scan reads a Codex session log.
transcript_usage() {
  local f=$1 scan=${2:-_transcript_usage_scan} n
  [ -f "$f" ] && [ -r "$f" ] || return 1
  n=$(tail -n 400 "$f" 2>/dev/null | "$scan") && [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  n=$("$scan" < "$f") && [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  return 1
}
_transcript_usage_scan() {
  perl -MJSON::PP -ne '
    next unless /"usage"/;
    my $d = eval { JSON::PP->new->decode($_) } or next;
    next unless ref $d eq "HASH" && ($d->{type} // "") eq "assistant";
    my $u = ref $d->{message} eq "HASH" ? $d->{message}{usage} : undef;
    next unless ref $u eq "HASH";
    my $t = 0;
    for my $k (qw(input_tokens cache_read_input_tokens cache_creation_input_tokens)) {
      my $v = $u->{$k}; $t += $v if defined $v && $v =~ /^\d+$/;
    }
    $last = $t;
    END { print $last if defined $last }'
}
# "<usage> <window>" from the latest Codex token_count event: the context the
# last model response used (last_token_usage.total_tokens, what Codex's own
# compaction limit is measured against) and the model's effective window.
# A compaction record voids every earlier event: until Codex writes the
# post-compaction token_count there is no current usage to report.
_codex_usage_scan() {
  perl -MJSON::PP -ne '
    next unless /"token_count"|"compacted"/;
    my $d = eval { JSON::PP->new->decode($_) } or next;
    next unless ref $d eq "HASH";
    if (($d->{type} // "") eq "compacted") { undef $last; next }
    next unless ($d->{type} // "") eq "event_msg" && ref $d->{payload} eq "HASH";
    my $i = $d->{payload}{info};
    next unless ($d->{payload}{type} // "") eq "token_count" && ref $i eq "HASH" && ref $i->{last_token_usage} eq "HASH";
    my ($u, $w) = ($i->{last_token_usage}{total_tokens}, $i->{model_context_window});
    next unless defined $u && $u =~ /^\d+$/ && defined $w && $w =~ /^[1-9]\d*$/;
    $last = "$u $w";
    END { print $last if defined $last }'
}

# next_handoff_number <data-dir> <id> -> one more than the handoffs on disk.
next_handoff_number() {
  local dir="$1/$2" f n max=0
  [ -d "$dir" ] || { printf 1; return 0; }
  for f in "$dir"/handoff-*.md; do
    [ -e "$f" ] || continue
    n=${f##*/handoff-}; n=${n%.md}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -le "$max" ] || max=$n
  done
  printf '%s' $((max + 1))
}

# --- hook side ----------------------------------------------------------------

hook_args() {
  STATE=${1:-}; ID=${2:-}
  [ -n "$STATE" ] && [ -n "$ID" ] || usage
  shift 2
  GEN=; DATA_DIR=; SKILL_ROOT=; CEILING_PCT=$CEILING_PCT_DEFAULT; CODEX_PCT=; HAIKU_CAP=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --gen) GEN=${2:-}; shift 2 || usage ;;
      --data-dir) DATA_DIR=${2:-}; shift 2 || usage ;;
      --fm-root) SKILL_ROOT=${2:-}; shift 2 || usage ;;
      --ceiling-pct) CEILING_PCT=${2:-}; shift 2 || usage ;;
      --codex-threshold-pct) CODEX_PCT=${2:-}; shift 2 || usage ;;
      --haiku-cap) HAIKU_CAP=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$GEN" ] && [ -n "$DATA_DIR" ] && [ -n "$SKILL_ROOT" ] || usage
  # fm-spawn validates the ceiling against the flag file before baking it in;
  # a hook command carrying anything else is a wiring error, not a decision.
  case "$CEILING_PCT" in ''|*[!0-9]*) usage ;; esac
  [ "$CEILING_PCT" -ge 1 ] && [ "$CEILING_PCT" -le "$CEILING_PCT_DEFAULT" ] || usage
  MARKER_MAX_PCT=$((CEILING_PCT - 1))
  # Below the ceiling means handoff first; above it means compact first.
  # fm-spawn validates the configured ordering before baking these values in.
  case "$CODEX_PCT" in
    '') ;;
    *[!0-9]*) usage ;;
    *) [ "$CODEX_PCT" -ge 1 ] && [ "$CODEX_PCT" -le "$CEILING_PCT_DEFAULT" ] && [ "$CODEX_PCT" -ne "$CEILING_PCT" ] || usage ;;
  esac
  [ "$HAIKU_CAP" = 0 ] || [ -z "$CODEX_PCT" ] || usage
  id_ok "$ID" || usage
  STATUS="$STATE/$ID.status"
  MARKER=$(marker_path "$STATE" "$ID")
}

# incarnation_current: 0 when --gen is the armed incarnation.
incarnation_current() {
  local current
  current=$(fm_busy_current_gen "$STATE" "$ID") || return 1
  [ "$current" = "$GEN" ]
}

do_precompact() {
  # Every failure path below ends in `exit 0` (proceed): a hook that cannot
  # decide must never block Claude.
  local trigger transcript usage pct marker state ceiling handoff epoch
  hook_args "$@"
  PAYLOAD=$(cat 2>/dev/null || true)
  if [ -n "$CODEX_PCT" ]; then codex_precompact; exit 0; fi
  trigger=$(payload_field trigger) || exit 0
  [ "$trigger" = auto ] || exit 0
  if [ "$HAIKU_CAP" = 1 ]; then haiku_mark_due_at_threshold; exit 0; fi
  incarnation_current || exit 0
  [ -d "$STATE" ] || exit 0

  marker=
  [ ! -f "$MARKER" ] || IFS= read -r marker < "$MARKER" || marker=
  if [ -n "$marker" ] && [ "$(marker_field "$marker" gen)" != "$GEN" ]; then
    marker=
  fi
  state=$(marker_field "$marker" state)

  case "$state" in
    no-override|fallback) exit 0 ;;
  esac

  pct=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}
  case "$pct" in
    ''|*[!0-9]*) pct= ;;
    *) [ "$pct" -ge 1 ] && [ "$pct" -le "$MARKER_MAX_PCT" ] || pct= ;;
  esac
  if [ -z "$pct" ]; then
    [ -n "$state" ] && exit 0
    marker_write "$MARKER" "v1 gen=$GEN state=no-override seq=1 at=$(date +%s 2>/dev/null || echo 0)" || exit 0
    status_note "$STATUS" "note: context handoff skipped: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is '${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-unset}', not a lowering threshold from 1 to $MARKER_MAX_PCT, so compaction was allowed at Claude's own threshold" || true
    exit 0
  fi

  transcript=$(payload_field transcript_path) || exit 0
  usage=$(transcript_usage "$transcript") || exit 0
  case "$usage" in ''|*[!0-9]*|0) exit 0 ;; esac
  epoch=$(date +%s 2>/dev/null || echo 0)

  if [ "$state" = due ]; then
    ceiling=$(marker_field "$marker" ceiling)
    case "$ceiling" in ''|*[!0-9]*) exit 0 ;; esac
    handoff=$(marker_field "$marker" handoff)
    if [ "$usage" -ge "$ceiling" ]; then
      marker_write "$MARKER" "$(printf '%s' "$marker" | sed 's/ state=due / state=fallback /') usage_now=$usage fallback_at=$epoch" || exit 0
      status_note "$STATUS" "note: context handoff missed: compaction allowed at $usage tokens, past the $ceiling-token ceiling, before $handoff appeared" || true
      exit 0
    fi
    echo "firstmate: auto-compaction held while the context handoff to $handoff is pending" >&2
    exit 2
  fi

  # First fire for this incarnation.
  ceiling=$((usage * CEILING_PCT / pct))
  mark_due "$usage" "$pct" $((usage * 100 / pct)) "$ceiling" || exit 0
  echo "firstmate: auto-compaction blocked; write the context handoff to $DUE_HANDOFF first (fallback compaction at $ceiling tokens)" >&2
  exit 2
}

# mark_due <usage> <pct> <window> <ceiling> [reason [field]]: write the
# incarnation's `due` marker naming the next handoff (left in DUE_HANDOFF) and
# append the one handoff-due note.
mark_due() {
  local n key reason=${5:-"usage $1 of about $3 tokens at $2 percent"}
  n=$(next_handoff_number "$DATA_DIR" "$ID")
  DUE_HANDOFF="$DATA_DIR/$ID/handoff-$n.md"
  key="context-handoff-$n"
  marker_write "$MARKER" "v1 gen=$GEN state=due seq=$n handoff=$DUE_HANDOFF key=$key usage=$1 pct=$2 window=$3 ceiling=$4 ceiling_pct=$CEILING_PCT${6:+ $6} notices=0 calls=0 at=$(date +%s 2>/dev/null || echo 0)" || return 1
  status_note "$STATUS" "note: context handoff due: $reason; the worker was told to write $DUE_HANDOFF and report it with key $key" || true
}

# Haiku uses the same prompt-usage reader as Claude PreCompact, without
# inferring a window from an auto-compaction percentage. Zero pct/window
# fields mean unknown, and ceiling records the absolute cap.
haiku_mark_due_at_threshold() {
  local marker='' usage
  incarnation_current || return 1
  [ -d "$STATE" ] || return 1
  [ ! -f "$MARKER" ] || IFS= read -r marker < "$MARKER" || marker=
  [ -z "$marker" ] || [ "$(marker_field "$marker" gen)" != "$GEN" ] || return 0
  usage=$(transcript_usage "$(payload_field transcript_path)") || return 1
  [ "$usage" -ge 80000 ] || return 1
  mark_due "$usage" 0 0 80000 "Haiku prompt usage $usage crossed the 80000-token Haiku cap (including cache reads), so this T1 task was misclassified and must be reclassified to T2: replace it on the T2 route from config/crew-dispatch.json, never on Haiku" reclassify=T2
}

# Codex mode: the marker this incarnation already has, or a new `due` one once
# the session log shows usage at the threshold. 0 when a marker for GEN exists
# afterwards.
codex_mark_due_at_threshold() {
  local marker='' scan usage window
  [ ! -f "$MARKER" ] || IFS= read -r marker < "$MARKER" || marker=
  [ -z "$marker" ] || [ "$(marker_field "$marker" gen)" != "$GEN" ] || return 0
  incarnation_current || return 1
  [ -d "$STATE" ] || return 1
  scan=$(transcript_usage "$(payload_field transcript_path)" _codex_usage_scan) || return 1
  usage=${scan% *} window=${scan#* }
  [ $((usage * 100)) -ge $((CODEX_PCT * window)) ] || return 1
  mark_due "$usage" "$CODEX_PCT" "$window" $((window * CEILING_PCT / 100))
}

# Codex mode PreCompact: never blocks; records that the fallback compaction
# arrived before a handoff did. In compact-first mode it leaves the handoff
# check armed, including a handoff already due.
codex_precompact() {
  local marker='' state usage handoff epoch
  [ "$CODEX_PCT" -lt "$CEILING_PCT" ] || return 0
  [ "$(payload_field trigger)" = auto ] || return 0
  incarnation_current || return 0
  [ -d "$STATE" ] || return 0
  [ ! -f "$MARKER" ] || IFS= read -r marker < "$MARKER" || marker=
  [ -z "$marker" ] || [ "$(marker_field "$marker" gen)" = "$GEN" ] || marker=
  state=$(marker_field "$marker" state)
  usage=$(transcript_usage "$(payload_field transcript_path)" _codex_usage_scan) || usage='? ?'
  usage=${usage% *}
  epoch=$(date +%s 2>/dev/null || echo 0)
  case "$state" in
    due)
      handoff=$(marker_field "$marker" handoff)
      [ -s "$handoff" ] && return 0
      marker_write "$MARKER" "$(printf '%s' "$marker" | sed 's/ state=due / state=fallback /') usage_now=$usage fallback_at=$epoch" || return 0
      status_note "$STATUS" "note: context handoff missed: codex compacted at $usage tokens, its fallback point, before $handoff appeared" || true
      ;;
    '')
      marker_write "$MARKER" "v1 gen=$GEN state=fallback seq=0 usage_now=$usage fallback_at=$epoch at=$epoch" || return 0
      status_note "$STATUS" "note: context handoff missed: codex compacted at $usage tokens before a tool call saw the $CODEX_PCT percent handoff threshold" || true
      ;;
  esac
  return 0
}

do_posttooluse() {
  local marker handoff key calls notices skill reason
  hook_args "$@"
  if [ -n "$CODEX_PCT" ]; then
    PAYLOAD=$(cat 2>/dev/null || true)
    codex_mark_due_at_threshold || exit 0
  elif [ "$HAIKU_CAP" = 1 ]; then
    PAYLOAD=$(cat 2>/dev/null || true)
    haiku_mark_due_at_threshold || exit 0
  fi
  [ -f "$MARKER" ] || exit 0
  cat >/dev/null 2>&1 || true
  IFS= read -r marker < "$MARKER" || exit 0
  [ "$(marker_field "$marker" gen)" = "$GEN" ] || exit 0
  [ "$(marker_field "$marker" state)" = due ] || exit 0
  incarnation_current || exit 0
  handoff=$(marker_field "$marker" handoff)
  key=$(marker_field "$marker" key)
  [ -n "$handoff" ] && [ -n "$key" ] || exit 0
  [ ! -s "$handoff" ] || exit 0
  calls=$(marker_field "$marker" calls); case "$calls" in ''|*[!0-9]*) calls=0 ;; esac
  notices=$(marker_field "$marker" notices); case "$notices" in ''|*[!0-9]*) notices=0 ;; esac
  calls=$((calls + 1))
  if [ $(( (calls - 1) % NOTICE_EVERY )) -ne 0 ]; then
    marker_write "$MARKER" "$(printf '%s' "$marker" | sed "s/ calls=[0-9]* / calls=$calls /")" || true
    exit 0
  fi
  notices=$((notices + 1))
  marker_write "$MARKER" "$(printf '%s' "$marker" | sed "s/ calls=[0-9]* / calls=$calls /; s/ notices=[0-9]* / notices=$notices /")" || true
  skill="$SKILL_ROOT/.agents/skills/context-handoff/SKILL.md"
  # Compact-first Codex has already compacted at the ceiling, so nothing is held off.
  reason="reached the handoff threshold, and auto-compaction is being held off so you can hand over instead"
  [ -z "$CODEX_PCT" ] || [ "$CODEX_PCT" -lt "$CEILING_PCT" ] ||
    reason="still reached the handoff threshold after auto-compaction, so you must hand over instead"
  [ "$HAIKU_CAP" = 0 ] || reason="crossed Haiku's 80000 prompt-token cap (including cache reads), so this task is being reclassified to T2 and you must hand over"
  perl -MJSON::PP -e '
    my ($id, $skill, $handoff, $status, $key, $reason) = @ARGV;
    my $text = "FIRSTMATE CONTEXT HANDOFF for task $id: this worker'"'"'s context $reason. Do these four things, in order.\n"
      . "1. Finish only the step already in hand and start nothing new. Never hand off in the middle of a running validation call: reach the next point where no pipeline call is in flight first.\n"
      . "2. Read and follow the handoff skill at $skill.\n"
      . "3. Write the handoff to exactly $handoff (create it; never overwrite an earlier handoff).\n"
      . "4. Report it by appending exactly this line to $status, with <epoch> replaced by the number `date +%s` prints: blocked [key=$key] [at=<epoch>]: context handoff ready at $handoff\n"
      . "Then end your turn and wait. A fresh worker replaces you and continues this task from the handoff.";
    print JSON::PP->new->canonical->encode({ hookSpecificOutput => { hookEventName => "PostToolUse", additionalContext => $text } }), "\n";
  ' -- "$ID" "$skill" "$handoff" "$STATUS" "$key" "$reason" 2>/dev/null || true
  exit 0
}

# --- firstmate side --------------------------------------------------------------

do_replace() {
  local marker state gen current handoff key note out rc line model=
  local profile=()
  ID=${1:-}
  [ -n "$ID" ] || usage
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness|--effort) [ -n "${2:-}" ] || usage; profile+=("$1" "$2"); shift 2 ;;
      --model) [ -n "${2:-}" ] || usage; model=$2; profile+=("$1" "$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  id_ok "$ID" || { echo "error: invalid task id '$ID'" >&2; exit 1; }
  if [ -z "${FM_HOME:-}" ]; then
    echo "error: FM_HOME is not set; fm-context-handoff refuses to resolve a task without an explicit firstmate home" >&2
    exit 1
  fi
  [ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  [ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for FM_HOME '$FM_HOME'" >&2; exit 1; }
  STATUS="$STATE/$ID.status"
  MARKER=$(marker_path "$STATE" "$ID")
  if [ ! -f "$MARKER" ]; then
    echo "error: no context handoff is recorded for task $ID ($MARKER is absent); nothing to replace from" >&2
    exit 1
  fi
  IFS= read -r marker < "$MARKER" || marker=
  state=$(marker_field "$marker" state)
  gen=$(marker_field "$marker" gen)
  handoff=$(marker_field "$marker" handoff)
  key=$(marker_field "$marker" key)
  case "$state" in
    due|fallback) ;;
    *) echo "error: task $ID's context handoff record reads state '$state', which names no handoff; nothing to replace from" >&2; exit 1 ;;
  esac
  [ -n "$handoff" ] && [ -n "$key" ] || { echo "error: task $ID's context handoff record names no handoff path or key; refusing to replace from it" >&2; exit 1; }
  case "$handoff" in
    "$DATA/$ID/handoff-"*.md) ;;
    *) echo "error: task $ID's recorded handoff $handoff is not under $DATA/$ID; refusing to replace from it" >&2; exit 1 ;;
  esac
  current=$(fm_busy_current_gen "$STATE" "$ID") || {
    echo "error: task $ID has no armed incarnation, so the handoff $handoff cannot be tied to a running worker; refusing to replace" >&2
    exit 1
  }
  if [ "$gen" != "$current" ]; then
    echo "error: the handoff $handoff belongs to a superseded incarnation of task $ID (recorded $gen, current $current); refusing to replace from it" >&2
    exit 1
  fi
  if [ ! -f "$handoff" ]; then
    echo "error: the handoff $handoff does not exist yet; the worker has not written it, so there is nothing to replace from" >&2
    exit 1
  fi
  if ! grep -q '[^[:space:]]' "$handoff" 2>/dev/null; then
    echo "error: the handoff $handoff is empty; refusing to replace a worker from a blank document" >&2
    exit 1
  fi
  if [ "$(marker_field "$marker" reclassify)" = T2 ]; then
    case "$model" in
      ''|*[Hh][Aa][Ii][Kk][Uu]*)
        echo "error: task $ID crossed the Haiku 80000 prompt-token cap, so it was misclassified as T1 and must be reclassified to T2; replace refuses to relaunch it on a Haiku model. Take the T2 route from config/crew-dispatch.json and pass it through as fm-control.sh relaunch's --harness/--model/--effort: fm-context-handoff.sh replace $ID --harness <harness> --model <model> --effort <effort>" >&2
        exit 1
        ;;
    esac
  fi
  note="Context handoff: the previous worker for this task reached its context limit and wrote a handoff document. After reading your steering inbox and confirming isolation as your instructions say, read the Continuation header at the top of $handoff first and start at its next action. Treat orientation as already done unless a fact it names turns out stale, and treat anything it marks as unverified as a claim to check, not a fact. Do not read earlier handoff-*.md files unless this one names one. Rerun only the checks invalidated since its validation receipt or never finished, and load only the skills the next step needs."
  out=$("${FM_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}" "$ID" relaunch ${profile[@]+"${profile[@]}"} --note "$note" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    echo "error: the replacement for task $ID could not be launched from $handoff (fm-control exit $rc); the handoff-ready record stays open" >&2
    exit 1
  fi
  line="resolved [key=$key]: replaced the worker from context handoff $handoff"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_wake_status_append_self_announced "$STATE" "$STATUS" "$line" || {
    rc=$?
    [ "$rc" -ne 2 ] || echo "warning: the replacement launched but the closing resolved event could not be appended to $STATUS" >&2
  }
  printf '%s\n' "$out"
  echo "replaced $ID from context handoff $handoff"
  exit 0
}

case "$CMD" in
  precompact) do_precompact "$@" ;;
  posttooluse) do_posttooluse "$@" ;;
  replace) do_replace "$@" ;;
esac
