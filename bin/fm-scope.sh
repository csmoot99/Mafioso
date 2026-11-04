#!/usr/bin/env bash
# fm-scope.sh - declared task scope: advisory overlap, out-of-scope report, ownership.
#
# Usage: fm-scope.sh overlap <task-id>
#        fm-scope.sh changed <task-id>
#        fm-scope.sh own <owner-id> <dependent-id>...
#
# The scope record lives in state/<id>.meta, written by bin/fm-spawn.sh:
#   base_sha=    DETECTED: the starting revision of the task's copy
#   scope=       DECLARED at intake (--scope, repeatable): comma-separated
#                repo-relative exact paths or directories the task expects to change
#   interfaces=  DECLARED at intake (--interface, repeatable): comma-separated names of
#                the shared contracts (types, schemas, config, CLI registration) it changes
# Actual changed files are DETECTED here from the task's copy; dependencies are not
# stored here, they are the backlog's own blocked-by edges.
#
# overlap: explains how the task's declared scope and interfaces meet the other live
#   ship tasks of the same project (their declared scope, declared interfaces, and
#   actual changed files). It is advisory: it prints, exits 0, and never blocks or
#   serializes. Overlap is not a conflict; bin/fm-spawn.sh runs it during a fresh dispatch.
# changed: lists the files the task changed (committed, uncommitted, untracked) against
#   its fork point (for a local-only task, the local default branch it lands on), and
#   those outside its declared scope. Workers run it before a done report and name any
#   outside file there. Prints nothing when no scope was declared.
# own: temporary ownership of an unstable interface, expressed as the existing backlog
#   dependency. Each dependent becomes blocked-by the owner, so bin/fm-spawn.sh will not
#   dispatch it until the owner is Done; there is no separate lock. Refuses a dependent that
#   is already dispatched, an owner already Done, and any edge that would close a cycle.
#   Ownership ends when the owner lands or is cleaned up without a retained captain call,
#   both of which close its row to Done. A retained owner returns to Queued and keeps its
#   dependents queued until the captain answers. To end it early (owner cancelled), run
#   `bin/fm-tasks-axi.sh unblock <dependent> --by <owner>` for each dependent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
fail() { printf 'fm-scope: %s\n' "$*" >&2; exit 2; }

meta_get() {  # <id> <key>
  sed -n "s/^$2=//p" "$STATE/$1.meta" 2>/dev/null | tail -1
}

# True when path <1> falls under scope entry <2> (exact path or directory prefix).
in_entry() {
  case "$1" in "$2"|"${2%/}"/*) return 0 ;; esac
  return 1
}

# Two declared entries overlap when either one covers the other.
entries_overlap() { in_entry "$1" "$2" || in_entry "$2" "$1"; }

# Files changed by task <1>, one per line.
changed_files() {
  local wt base ref mb landed
  wt=$(meta_get "$1" worktree)
  [ -d "$wt" ] || return 0
  base=$(meta_get "$1" base_sha)
  mb=
  for ref in "origin/$(meta_get "$1" base_branch)" origin/HEAD; do
    case "$ref" in origin/) continue ;; esac
    mb=$(git -C "$wt" merge-base HEAD "$ref" 2>/dev/null) && [ -n "$mb" ] && break
    mb=
  done
  mb=${mb:-$base}
  [ -n "$mb" ] || return 0
  # A local-only landing moves only the local default branch, so the task forks from
  # there unless that branch is merely behind the point found above.
  if [ "$(meta_get "$1" mode)" = local-only ] \
    && landed=$(git -C "$wt" merge-base HEAD "refs/heads/$(default_branch "$wt")" 2>/dev/null) \
    && git -C "$wt" merge-base --is-ancestor "$mb" "$landed" 2>/dev/null; then
    mb=$landed
  fi
  { git -C "$wt" -c core.quotePath=false diff --name-only "$mb" 2>/dev/null
    git -C "$wt" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null; } | sort -u
}

csv_each() { printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d'; }

cmd_changed() {
  local id=$1 scope f e outside=
  [ -f "$STATE/$id.meta" ] || fail "no task record for $id"
  scope=$(meta_get "$id" scope)
  [ -n "$scope" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local hit=0
    while IFS= read -r e; do in_entry "$f" "$e" && { hit=1; break; }; done < <(csv_each "$scope")
    [ "$hit" = 1 ] || outside="$outside${outside:+, }$f"
  done < <(changed_files "$id")
  if [ -n "$outside" ]; then
    printf 'outside declared scope (%s): %s\n' "$scope" "$outside"
  else
    printf 'within declared scope (%s)\n' "$scope"
  fi
}

cmd_overlap() {
  local id=$1 scope ifaces project other m reasons other_changed f e o i
  [ -f "$STATE/$id.meta" ] || fail "no task record for $id"
  scope=$(meta_get "$id" scope)
  ifaces=$(meta_get "$id" interfaces)
  [ -n "$scope$ifaces" ] || return 0
  project=$(meta_get "$id" project)
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] && [ ! -L "$m" ] || continue
    other=${m##*/}; other=${other%.meta}
    [ "$other" != "$id" ] || continue
    case "$(meta_get "$other" kind)" in ''|ship) ;; *) continue ;; esac
    [ "$(meta_get "$other" project)" = "$project" ] || continue
    reasons=
    while IFS= read -r i; do
      csv_each "$(meta_get "$other" interfaces)" | grep -qxF -- "$i" \
        && reasons="$reasons
  - both change interface $i"
    done < <(csv_each "$ifaces")
    other_changed=
    [ -z "$scope" ] || other_changed=$(changed_files "$other")
    while IFS= read -r e; do
      while IFS= read -r o; do
        entries_overlap "$e" "$o" && reasons="$reasons
  - declared scope $e meets its declared scope $o"
      done < <(csv_each "$(meta_get "$other" scope)")
      while IFS= read -r f; do
        in_entry "$f" "$e" && reasons="$reasons
  - $f, which it has already changed, is in declared scope $e"
      done <<< "$other_changed"
    done < <(csv_each "$scope")
    [ -z "$reasons" ] || printf 'scope overlap (advisory) between %s and live task %s:%s\n' "$id" "$other" "$(printf '%s\n' "$reasons" | awk '!s[$0]++')"
  done
}

cmd_own() {
  local owner=$1 dep out
  shift
  [ "$#" -gt 0 ] || fail "own needs an owner and at least one dependent"
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH"
  tasks_axi() { FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" "$@"; }
  field() { printf '%s\n' "$1" | sed -n "s/^  $2: *//p" | head -1; }
  out=$(tasks_axi show "$owner" 2>&1) || fail "owner $owner has no backlog item"
  [ "$(field "$out" state)" != "done" ] || fail "owner $owner is already Done; there is nothing to wait for"
  for dep in "$@"; do
    out=$(tasks_axi show "$dep" 2>&1) || fail "dependent $dep has no backlog item"
    [ "$(field "$out" state)" = queued ] || fail "dependent $dep is already dispatched or closed; ownership only orders dispatch"
    reaches "$owner" "$dep" && fail "refusing: $owner already waits on $dep, so $dep waiting on $owner would be a cycle"
  done
  for dep in "$@"; do
    tasks_axi block "$dep" --by "$owner" >/dev/null || fail "could not record $dep blocked-by $owner"
    printf '%s waits for %s: dispatch resumes once %s is Done\n' "$dep" "$owner" "$owner"
  done
}

# True when task <1> is, through blocked-by edges, waiting on task <2>.
reaches() {
  local queue=$1 seen=' ' cur b
  while [ -n "$queue" ]; do
    cur=${queue%% *}
    [ "$cur" != "$queue" ] && queue=${queue#* } || queue=
    case "$seen" in *" $cur "*) continue ;; esac
    seen="$seen$cur "
    for b in $(tasks_axi show "$cur" 2>/dev/null | sed -n 's/^  blocked_by: *//p' | head -1 | tr ',"' '  '); do
      [ "$b" != none ] || continue
      [ "$b" != "$2" ] || return 0
      queue="$queue${queue:+ }$b"
    done
  done
  return 1
}

case "${1:-}" in
  -h|--help|'') usage; [ -n "${1:-}" ] ;;
  overlap) [ "$#" -eq 2 ] || fail "usage: overlap <task-id>"; cmd_overlap "$2" ;;
  changed) [ "$#" -eq 2 ] || fail "usage: changed <task-id>"; cmd_changed "$2" ;;
  own) shift; [ "$#" -ge 2 ] || fail "usage: own <owner-id> <dependent-id>..."; cmd_own "$@" ;;
  *) fail "unknown command $1" ;;
esac
