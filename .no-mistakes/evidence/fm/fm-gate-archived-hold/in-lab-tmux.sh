#!/usr/bin/env bash
# Runs drive.sh inside a private fm-lab tmux server so every tmux call the
# lifecycle scripts make lands on that lab socket, never the default server.
set -u
ROOT=$1 SCEN=$2 OUT=$3
TD=$(mktemp -d /tmp/fmlt.XXXX)
env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$TD" \
  tmux -L fm-lab new-session -d -s primary -x 200 -y 50 \
  "bash /tmp/fm-live-driver/drive.sh '$ROOT' '$SCEN' > '$OUT' 2>&1; echo \"### TMUX=\$TMUX\" >> '$OUT'; touch '$TD/done'; sleep 600"
for _ in $(seq 1 240); do [ -e "$TD/done" ] && break; sleep 0.5; done
TMUX_TMPDIR="$TD" tmux -L fm-lab kill-server 2>/dev/null
rm -rf "$TD"
cat "$OUT"
