#!/usr/bin/env bash
# Round 2: the image-mode job resolves its pnpm store with the image's REAL pnpm and the store persists across containers.
. "$(dirname "$0")/drive-lib.sh"
IMG=fm-ci-177l-runner:prepared   # existing Linux image on fm-mac with python3 + pnpm (no new image built)
cfg 'host fm-mac' 'project *' "image $IMG" 'timeout 600'
say "config/heavy-remote"; cat "$LAB/config/heavy-remote"
mac "rm -rf ~/.fm-heavy-remote/linux/cache/tools/pnpm-store/fm-lab-marker ~/.fm-heavy-remote/linux/cache/tools/pnpm-store/v*/fm-lab-marker"
say "S8a job 1 (project alpha-shop) in a fresh container: real pnpm resolves the store, job writes into it"
hv --class e2e --task r2s8 --project alpha-shop --remote -- t/pnpm-cache.sh write; echo "rc=$?"; pcrec
say "S8b job 2 (project beta-api), another fresh container: real pnpm resolves the same store and finds job 1's file"
hv --class e2e --task r2s8 --project beta-api --remote -- t/pnpm-cache.sh read; echo "rc=$?"; pcrec
say "On the Mac host: where the store file really lives (the mounted ~/.fm-heavy-remote/linux/cache)"
mac 'find ~/.fm-heavy-remote -name fm-lab-marker -path "*pnpm-store*"'
say "No fm-heavy containers remain: [$(mac 'PATH=/opt/homebrew/bin:$PATH docker ps -a --filter name=fm-heavy- --format "{{.Names}}"')]"
say "Mac scratch job dirs left: $(mac 'ls -A ~/.fm-heavy-remote 2>/dev/null | grep -v linux | wc -l' | tr -d ' ')"
