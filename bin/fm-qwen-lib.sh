#!/usr/bin/env bash
# Qwen Code process identity.
# Sourced by bin/fm-tmux-lib.sh (so every copy of that adapter, including the
# remote transport's staged bin tree, needs this file beside it),
# bin/fm-agent-process-lib.sh, and bin/fm-harness.sh. This file is sourced by
# scripts and has no side effects on source.
#
# Why one owner: Qwen Code ships as a node bundle (a Gemini CLI fork), so a
# live qwen pane presents as an interpreter and nothing about its command NAME
# says qwen. Measured on qwen 0.25.1 with Node v24.21.0 on Linux, one worker's
# foreground process group read:
#
#   comm  : MainThread
#   argv0 : node
#   args  : node /home/<user>/.local/bin/qwen -y ... -i <brief>
#
# `comm` is MainThread because modern Node renames its main thread, and argv[0]
# is the interpreter. Only argv[1] - the script path - carries the identity, so
# the liveness classifier has to read the arguments rather than the name. This
# is the same hazard bin/fm-gemini-lib.sh closes for gemini and
# bin/fm-cursor-lib.sh for cursor-agent, and the rule is deliberately the same
# shape: structural only, no subprocess, because probing a stranger's binary
# during a liveness poll is exactly what must not happen.
#
# Detection of firstmate's OWN harness uses these structural rules for the
# ancestry fallback. The QWEN_CODE_CLI environment marker in bin/fm-harness.sh
# remains the load-bearing path for the installed bundle shape on modern Node;
# fm_qwen_marker_is_qwen below owns what that marker must look like.

# True when path $1 carries Qwen Code's own structural evidence: the file is
# named qwen, or it sits inside the published @qwen-code/qwen-code package
# tree. A directory component merely named `qwen` is never enough on its own,
# and a bare interpreter is always rejected.
fm_qwen_path_is_qwen() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "$path" in
    -*) return 1 ;;
  esac
  case "${path##*/}" in
    qwen) return 0 ;;
  esac
  case "$path" in
    */@qwen-code/qwen-code/*) return 0 ;;
  esac
  return 1
}

# True when $1 is the value Qwen Code stamps into QWEN_CODE_CLI. Unlike
# GEMINI_CLI=1, the marker's value is the CLI entry script's absolute path
# (verified on qwen 0.25.1: `/.../@qwen-code/qwen-code/cli-entry.js`, exported
# by the launcher and inherited by every tool subprocess), so a bare "1" or
# an arbitrary word is NOT the verified marker and must not claim the
# identity. The same path rule as the process classifier applies.
fm_qwen_marker_is_qwen() {  # <QWEN_CODE_CLI value>
  local value=$1
  [ -n "$value" ] || return 1
  case "$value" in
    /*) fm_qwen_path_is_qwen "$value" ;;
    *) return 1 ;;
  esac
}

# True when process $1 has Qwen Code's structural argv evidence. Linux exposes
# argv as NUL-delimited fields, which preserves a script path containing spaces
# that `ps -o args=` necessarily flattens into an ambiguous string.
fm_qwen_pid_is_qwen() {  # <pid>
  local pid=$1 token argv0='' index=0
  [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' token; do
    if [ "$index" -eq 0 ]; then
      argv0=$token
      fm_qwen_path_is_qwen "$argv0" && return 0
      case "${argv0##*/}" in
        node|node-*|node[0-9]*|MainThread) ;;
        *) return 1 ;;
      esac
    else
      case "$token" in
        -*) ;;
        *) fm_qwen_path_is_qwen "$token" && return 0; return 1 ;;
      esac
    fi
    index=$((index + 1))
  done < "/proc/$pid/cmdline"
  return 1
}

# True when the whitespace-separated command line $1 is a Qwen Code process.
#
# Accepted: a command whose own argv[0] is qwen (a future natively-named
# binary), and an interpreter whose first non-flag argument is Qwen Code's
# script or package path.
#
# Rejected: a bare interpreter with no qwen argument, and any command line
# whose only mention of qwen is a later flag value, a model name such as
# qwen3-coder:30b, a working directory, or a prompt string - only argv[0] and
# the script argument are ever consulted, so an unrelated command that merely
# TALKS about qwen never matches.
fm_qwen_args_are_qwen() {  # <args>
  local args=$1 argv0 rest token
  [ -n "$args" ] || return 1
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_qwen_path_is_qwen "$argv0" && return 0
  case "${argv0##*/}" in
    node|node-*|node[0-9]*|MainThread) ;;
    *) return 1 ;;
  esac
  rest=${args#"$argv0"}
  # The first non-flag token after the interpreter is the script it runs.
  # Node's own options are skipped so `node --max-old-space-size=10000 <script>`
  # still resolves.
  while [ -n "$rest" ]; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      -*) continue ;;
    esac
    fm_qwen_path_is_qwen "$token" && return 0
    return 1
  done
  return 1
}
