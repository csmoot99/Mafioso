#!/usr/bin/env bash
# Opt-in Consigliere readiness guard. Configuration is owned by
# docs/configuration.md; ship-landing owns review dispatch and correction.
# fm_consigliere_mode <home> prints on/off; missing config is off, invalid
# configuration refuses. FM_CONFIG_OVERRIDE selects the config directory.
# fm_consigliere_require_review <home> <task-id> <canonical-pr-url> <live-head>
# refuses readiness without a supervisor-authored data/<task-id>/consigliere.json
# receipt for this exact PR/head. FM_DATA_OVERRIDE selects the data directory.
# Receipt fields: pr, head, round (1 or 2), verdict (clear), blocker (0),
# major (0), minor (nonnegative integer), builder_family, reviewer_family,
# report (absolute path), gates (absolute path). Families are the actual model
# provider families, not harness names. Both evidence files must be nonempty.
# Same-family exceptions additionally require exception=opus-independent or
# fable-independent and a nonempty reason; ship-landing owns their eligibility.
# The supervisor writes the receipt only after checking the underlying evidence;
# it is an attestation, not an automatic interpretation of a worker's report.
# This guard never writes files or calls a forge. The caller supplies a freshly
# read head, and merge callers must bind their merge command to that same head.

fm_consigliere_mode() { # <home>
  local file="${FM_CONFIG_OVERRIDE:-$1/config}/consigliere" mode
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'off\n'
    return 0
  fi
  if [ -f "$file" ] && [ -r "$file" ] && mode=$(cat "$file"); then
    case "$mode" in
      on|off) printf '%s\n' "$mode"; return 0 ;;
    esac
  fi
  printf 'error: config/consigliere must contain on or off\n' >&2
  return 1
}

fm_consigliere_require_review() { # <home> <task-id> <url> <live-head>
  local home=$1 id=$2 url=$3 head=$4 mode receipt files report gates
  mode=$(fm_consigliere_mode "$home") || return 1
  [ "$mode" = on ] || return 0
  if [[ ! "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] \
    || [[ ! "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]; then
    printf 'error: Consigliere requires a task identity and a readable current PR head\n' >&2
    return 1
  fi
  receipt="${FM_DATA_OVERRIDE:-$home/data}/$id/consigliere.json"
  if ! files=$(jq -ser --arg pr "$url" --arg head "$head" '
      def count: type == "number" and . >= 0 and floor == .;
      def text: type == "string" and length > 0;
      def path: text and startswith("/") and (test("[\\n\\r]") | not);
      if length == 1 then .[0] else error("expected one receipt") end
      | select(.pr == $pr and .head == $head
        and (.round == 1 or .round == 2) and .verdict == "clear"
        and .blocker == 0 and .major == 0 and (.minor | count)
        and (.builder_family | text) and (.reviewer_family | text)
        and ((.builder_family != .reviewer_family)
          or ((.exception == "opus-independent" or .exception == "fable-independent")
            and (.reason | text)))
        and (.report | path) and (.gates | path))
      | .report, .gates' "$receipt" 2>/dev/null); then
    printf 'error: Consigliere review pending or invalid for %s at %s; follow ship-landing\n' "$url" "$head" >&2
    return 1
  fi
  report=${files%%$'\n'*}
  gates=${files#*$'\n'}
  if [ ! -f "$report" ] || [ ! -s "$report" ] || [ ! -f "$gates" ] || [ ! -s "$gates" ]; then
    printf 'error: Consigliere report or gate evidence is unavailable\n' >&2
    return 1
  fi
}
