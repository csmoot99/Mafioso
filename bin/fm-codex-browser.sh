#!/usr/bin/env bash
# fm-codex-browser.sh <command> [args...] - a task browser for a Codex launch.
# Uses an installed Playwright Chromium from its default Linux cache, starts
# loopback-only CDP with a fresh profile and an OS-selected port, and gives the
# worker a unique chrome-devtools-axi session. No Codex permission flags change:
# socket operations inside the worker still need reviewed escalation.
# Hosts without this optional browser installation keep their ordinary launch
# with an explicit warning. An installed browser that fails to start stops the
# launch. EXIT cleanup stops only this session and browser, removing its profile.
set -eu

browser=
for candidate in "${XDG_CACHE_HOME:-$HOME/.cache}"/ms-playwright/chromium-*/chrome-linux64/chrome; do
  [ ! -x "$candidate" ] || browser=$candidate
done
if [ -z "$browser" ]; then
  echo 'warning: no Playwright Chromium in the user cache; Codex browser setup skipped' >&2
  exec "$@"
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-browser.XXXXXXXX")
browser_pid=
export CHROME_DEVTOOLS_AXI_SESSION="${scratch##*/}"
cleanup() {
  # A bridge may have been started by the worker; stop exactly its session.
  if command -v chrome-devtools-axi >/dev/null 2>&1; then
    chrome-devtools-axi stop >/dev/null 2>&1 || true
  fi
  if [ -n "$browser_pid" ]; then
    # Chromium's helpers outlive its main process and keep writing the
    # profile; stop the whole process group and wait for it to be gone.
    kill -- "-$browser_pid" 2>/dev/null || true
    wait "$browser_pid" 2>/dev/null || true
    for ((attempt = 0; attempt < 50; attempt++)); do
      kill -0 -- "-$browser_pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -rf -- "$scratch" || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

setsid "$browser" --headless=new --no-sandbox --use-mock-keychain --password-store=basic \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=0 \
  --user-data-dir="$scratch/profile" >"$scratch/chromium.log" 2>&1 &
browser_pid=$!
port=
for ((attempt = 0; attempt < 100; attempt++)); do
  kill -0 "$browser_pid" 2>/dev/null || break
  if [ -s "$scratch/profile/DevToolsActivePort" ]; then
    IFS= read -r port < "$scratch/profile/DevToolsActivePort" || true
    case "$port" in
      '' | *[!0-9]*) port= ;;
      *) [ "$port" -gt 0 ] && [ "$port" -le 65535 ] && break; port= ;;
    esac
  fi
  sleep 0.1
done
if [ -z "$port" ]; then
  echo 'error: task Chromium did not publish a loopback CDP port' >&2
  tail -n 10 "$scratch/chromium.log" >&2
  exit 1
fi
export CHROME_DEVTOOLS_AXI_BROWSER_URL="http://127.0.0.1:$port"
"$@"
