#!/usr/bin/env bash
# Durable, opt-in integration preparation. No caller uses this automatically.
# The state machine, storage and command contract live in the sibling Python
# implementation; --help exposes its version-matched CLI. Python 3's sqlite3
# transactions and fcntl.flock provide crash-safe records and OS-released leases
# on Linux and macOS without requiring the flock executable.
#
# Internal --admit reuses the merge entrypoint's owner-hold and authority reads
# under the same per-task control lock. Like an attended fm-pr-merge invocation,
# invoking this helper is not itself evidence of human approval: the supervisor
# must already possess merge authority. No new standing grant is inferred here.
# Internal --active refuses preparation alongside any active legacy validation
# on the same project/base; ordinary single-PR conflict checks remain unchanged.
# Publication is GitHub-only and disabled unless the canonical project path
# is listed in the private config/integration-queue-projects file. The existing
# merge entrypoint owns every live landing guard and calls the publication
# primitive only after those guards; no queue caller uses ordinary PR merge.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME FM_STATE_OVERRIDE="$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

case "${1:-}" in
  --admit)
    [ "$#" -eq 6 ] || exit 2
    shift
    ID=$1 URL=$2 HEAD=$3 PROJECT=$4 BASE=$5
    # shellcheck source=bin/fm-merge-authority-lib.sh
    . "$SCRIPT_DIR/fm-merge-authority-lib.sh"
    # shellcheck source=bin/fm-tangle-lib.sh
    . "$SCRIPT_DIR/fm-tangle-lib.sh"
    fm_pr_task_id_valid "$ID" && fm_pr_head_valid "$HEAD" && fm_pr_url_parse "$URL" || exit 2
    META="$STATE/$ID.meta"
    [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || exit 1
    CONTROL="$STATE/.control-$ID.lock"
    fm_lock_acquire_wait "$CONTROL"
    trap 'fm_afk_contract_lock_release || true; fm_lock_release "$CONTROL" || true' EXIT
    [ -f "$META" ] && [ ! -L "$META" ] || exit 1
    value() { sed -n "s/^$1=//p" "$META" | tail -1; }
    [ "$(value project)" = "$PROJECT" ] && [ "$(value pr)" = "$URL" ] || {
      echo 'error: submission does not match task project/PR' >&2; exit 1;
    }
    TASK_BASE=$(value base_branch)
    [ -n "$TASK_BASE" ] || TASK_BASE=$(fm_default_branch "$PROJECT")
    [ "$TASK_BASE" = "$BASE" ] || { echo 'error: task base differs' >&2; exit 1; }
    case "$(value kind)" in ''|ship) ;; *) echo 'error: only ship tasks may queue' >&2; exit 1 ;; esac
    HOLD=0
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || HOLD=$?
    case "$HOLD" in
      1|3) ;;
      0) echo 'error: task is still held for the owner' >&2; exit 1 ;;
      *) echo 'error: owner hold could not be read' >&2; exit 1 ;;
    esac
    . "$SCRIPT_DIR/fm-consigliere-lib.sh"
    fm_consigliere_require_review "$FM_HOME" "$ID" "$URL" "$HEAD" || exit 1
    fm_afk_contract_lock_hold "$STATE" || exit 1
    fm_merge_authority_resolve "$FM_HOME" "$STATE" "$META" "$ID" || {
      echo 'error: merge authority could not be read' >&2; exit 1;
    }
    ;;
  --account)
    [ "$#" -eq 5 ] || exit 2
    ID=$2 URL=$3 AUTHORITY=$4 HEAD=$5
    . "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
    . "$SCRIPT_DIR/fm-merge-authority-lib.sh"
    fm_pr_task_id_valid "$ID" && fm_pr_url_parse "$URL" && fm_pr_head_valid "$HEAD" || exit 2
    [ "$FM_PR_PROVIDER" = github ] || exit 2
    case "$AUTHORITY" in attended|away) ;; *) exit 2 ;; esac
    PROOF=$(gh-axi api "repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" --jq \
      'if .merged == true and .head.sha == "'"$HEAD"'" then "fm-queue-merged" else "fm-queue-unproved" end')
    [ "$PROOF" = fm-queue-merged ] || exit 1
    META="$STATE/$ID.meta"
    if [ -f "$META" ]; then
      CONTROL="$STATE/.control-$ID.lock"
      fm_lock_acquire_wait "$CONTROL"
      trap 'fm_lock_release "$CONTROL" || true' EXIT
      LOCK=$(fm_meta_lock_path "$META")
      fm_lock_acquire_wait "$LOCK"
      RC=0
      fm_merge_authority_persist "$STATE" "$ID" "$META" github "$FM_PR_HOST" \
        "$FM_PR_PATH" "$FM_PR_NUMBER" "$AUTHORITY" || RC=$?
      fm_lock_release "$LOCK" || exit 1
      [ "$RC" -eq 0 ] || exit "$RC"
    fi
    fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self "$AUTHORITY"
    ;;
  --active)
    [ "$#" -eq 3 ] || exit 2
    PROJECT=$2 BASE=$3
    # shellcheck source=bin/fm-nm-run-lib.sh
    . "$SCRIPT_DIR/fm-nm-run-lib.sh"
    # shellcheck source=bin/fm-tangle-lib.sh
    . "$SCRIPT_DIR/fm-tangle-lib.sh"
    DEFAULT=$(fm_default_branch "$PROJECT")
    for META in "$STATE"/*.meta; do
      [ -f "$META" ] && [ ! -L "$META" ] || continue
      value() { sed -n "s/^$1=//p" "$META" | tail -1; }
      [ "$(value project)" = "$PROJECT" ] && [ "$(value mode)" = no-mistakes ] || continue
      case "$(value kind)" in ''|ship) ;; *) continue ;; esac
      TASK_BASE=$(value base_branch)
      [ "${TASK_BASE:-$DEFAULT}" = "$BASE" ] || continue
      WT=$(value worktree)
      [ -d "$WT" ] || continue
      BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD) || continue
      RC=0
      RUN=$(fm_nm_run_bounded "$WT" 10 axi status 2>/dev/null) || RC=$?
      if printf '%s\n' "$RUN" | grep -q '^error: repo not initialized'; then continue; fi
      if [ "$RC" -ne 0 ] || [ -z "$RUN" ]; then
        echo "error: legacy validation cannot be read for ${META##*/}" >&2; exit 1
      fi
      [ "$(fm_nm_strip_quotes "$(fm_nm_field "$RUN" branch)")" = "$BRANCH" ] || continue
      if fm_nm_run_is_active "$RUN"; then
        echo "error: active legacy validation on $BASE: ${META##*/}" >&2; exit 1
      fi
    done
    ;;
  *) exec python3 "$SCRIPT_DIR/fm-integration-queue.py" "$@" ;;
esac
