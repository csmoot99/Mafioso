#!/usr/bin/env bash
. "$(dirname "$0")/drive-lib.sh"
# An already-present Linux image on the Mac with python3 (the runner's execute step needs only that for a project without package.json).
cfg 'host fm-mac' 'project *' 'image mia-tailscale-lab:local' 'timeout 300'
say "config/heavy-remote"; cat "$LAB/config/heavy-remote"
say "S7a job 1 in the image writes into each tool cache"
hv --class e2e --task s7 --project alpha-shop --remote -- t/cache.sh write; echo "rc=$?"; pcrec
say "S7b job 2, a fresh container, reads what job 1 cached"
hv --class e2e --task s7 --project beta-api --remote -- t/cache.sh read; echo "rc=$?"; pcrec
say "On the Mac host: the caches live under the mounted ~/.fm-heavy-remote/linux/cache"
mac 'find ~/.fm-heavy-remote -name fm-lab-marker'
say "No fm-heavy containers remain: [$(mac 'PATH=/opt/homebrew/bin:$PATH docker ps -a --filter name=fm-heavy- --format "{{.Names}}"')]"
say "Mac scratch: $(mac 'ls -A ~/.fm-heavy-remote')"
