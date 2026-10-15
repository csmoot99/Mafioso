#!/usr/bin/env bash
# Live guard for the Codex push guard rules file.
#
# .agents/skills/harness-adapters/references/harness/codex-push-guard.rules is
# the one source of the rules an operator installs as
# ~/.codex/rules/firstmate-push-guard.rules. The verdict comes from the
# installed codex's own policy evaluator, `codex execpolicy check`, which also
# validates every rule's match and not_match examples when it loads the file:
# a rule codex can no longer parse, or one that stops forbidding a force push
# or a push to main or master, or starts forbidding an ordinary fm/ branch
# push, fails here naming the version.
#
# It spends no model tokens and reads only the tracked file, never the
# operator's installed copy, so it runs by default wherever codex is installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CODEX_PUSH_GUARD_LIVE codex jq

CODEX_VERSION=$(codex --version 2>&1)
RULES="$ROOT/.agents/skills/harness-adapters/references/harness/codex-push-guard.rules"
[ -r "$RULES" ] || fail "the tracked push guard rules file is missing: $RULES"

# decision <command words...>: codex's decision for the command, or `allowed`
# when no rule matched.
decision() {
  local out
  out=$(codex execpolicy check --rules "$RULES" "$@" 2>&1) ||
    fail "codex $CODEX_VERSION: execpolicy check refused the rules file for '$*': $out"
  printf '%s' "$out" | jq -r '.decision // "allowed"' 2>/dev/null ||
    fail "codex $CODEX_VERSION: execpolicy check printed no decision for '$*': $out"
}

# expect_decisions <expected> <<< "one command per line"
expect_decisions() {
  local expected=$1 line got
  local -a words
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r -a words <<<"$line"
    got=$(decision "${words[@]}")
    [ "$got" = "$expected" ] ||
      fail "codex $CODEX_VERSION: '$line' is '$got' under the push guard, expected '$expected'"
  done
}

expect_decisions forbidden <<'EOF'
git push --force origin fm/x
git push -f origin fm/x
git push --force-with-lease origin fm/x
git push --force-if-includes origin fm/x
git push --mirror origin
git push -u --force origin fm/x
git push --set-upstream -f origin fm/x
git push origin --force fm/x
git push origin -f fm/x
git push upstream --force-with-lease fm/x
git push origin +HEAD
git push -u origin --force fm/x
git push --set-upstream origin +HEAD
git push origin main
git push origin master
git push origin HEAD:main
git push origin +HEAD:main
git push origin HEAD:refs/heads/main
git push origin +main
git push origin :main
git push origin --delete main
git push upstream master
git push -u origin main
git push --set-upstream origin HEAD:master
EOF
pass "codex $CODEX_VERSION: the push guard forbids force pushes and pushes to main or master"

expect_decisions allowed <<'EOF'
git push origin fm/fm-codex-worker-parity
git push -u origin fm/fm-codex-worker-parity
git push --set-upstream origin HEAD:fm/fm-codex-worker-parity
git push origin HEAD
git push origin maintenance
git push origin --delete fm/old-branch
git push --dry-run origin fm/x
git status
EOF
pass "codex $CODEX_VERSION: the push guard lets ordinary fm/ branch pushes through"
