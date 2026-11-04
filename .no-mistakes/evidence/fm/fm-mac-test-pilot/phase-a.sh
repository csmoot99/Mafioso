#!/usr/bin/env bash
. "$(dirname "$0")/drive-lib.sh"
set -u
H=(--class test --task fm-mac-test-pilot --project firstmate)
say() { printf '\n### %s\n' "$*"; }
: > "$LAB/ssh.log"

say "A1 no config/heavy-remote: --remote refuses, nothing contacts ssh"
hv "${H[@]}" --remote -- $APPROVED; echo "rc=$?"; echo "ssh calls: $(wc -l < "$LAB/ssh.log")"; echo "records: $(wc -l < "$LAB/state/heavy-jobs.jsonl" 2>/dev/null || echo 0)"

cfg '# lab only' 'host fm-mac' "command $APPROVED" 'timeout 600'
say "A2 an unapproved command refuses"
hv "${H[@]}" --remote -- bash tests/fm-heavy.test.sh; echo "rc=$?"
say "A3 a class other than test refuses"
hv --class build --remote -- $APPROVED; echo "rc=$?"
say "A4 malformed config with an unterminated last line refuses"
printf 'host fm-mac\ncommand %s\nsurprise 1' "$APPROVED" > "$LAB/config/heavy-remote"
hv "${H[@]}" --remote -- $APPROVED; echo "rc=$?"
echo "ssh calls after A1-A4: $(wc -l < "$LAB/ssh.log")"

say "A5 no --remote: today's local path, no remote fields set, no ssh"
hv "${H[@]}" -- echo plain-local-run; echo "rc=$?"; rec; echo "ssh calls: $(wc -l < "$LAB/ssh.log")"

say "A6 unreachable destination (real ssh, unresolvable alias): runs locally under the slot"
cfg 'host fm-lab-unreachable.invalid' 'command echo ran-locally'
hv "${H[@]}" --remote -- echo ran-locally; echo "rc=$?"; rec

say "A7 dirty tree in a clone: runs locally, fallback dirty-tree, nothing reaches the Mac"
CL=$LAB/clone; git clone -q "$WT" "$CL" 2>/dev/null; touch "$CL/untracked-file"
cfg 'host fm-mac' 'command echo ran-locally'
: > "$LAB/ssh.log"
REPO=$CL hv "${H[@]}" --remote -- echo ran-locally; echo "rc=$?"; rec; echo "ssh calls: $(wc -l < "$LAB/ssh.log")"
rm -f "$CL/untracked-file"
say "A8 below the repository root: runs locally, fallback not-repository-root"
REPO=$CL/bin hv "${H[@]}" --remote -- echo ran-locally; echo "rc=$?"; rec

say "A9 TERM to the fm-heavy.sh pid alone during the probe of a silent host: the command never runs"
cfg 'host 10.255.255.1' "command touch $LAB/ran-a9"
(cd "$WT" && PATH="$LAB/shim:$PATH" FM_HOME="$LAB" exec "$WT/bin/fm-heavy.sh" "${H[@]}" --remote -- touch "$LAB/ran-a9") &
pid=$!; sleep 2; kill -TERM "$pid"; wait "$pid"; echo "rc=$?"; sleep 12
[ -e "$LAB/ran-a9" ] && echo "RAN LOCALLY" || echo "command did not run"; rec

say "A10 TERM to the whole process group during the probe: the command never runs"
cfg 'host 10.255.255.1' "command touch $LAB/ran-a10"
setsid bash -c 'cd "$1" && PATH="$2/shim:$PATH" FM_HOME="$2" exec "$1/bin/fm-heavy.sh" --class test --task fm-mac-test-pilot --project firstmate --remote -- touch "$2/ran-a10"' _ "$WT" "$LAB" &
pid=$!; sleep 2; kill -TERM -- "-$pid"; wait "$pid"; echo "rc=$?"; sleep 1
[ -e "$LAB/ran-a10" ] && echo "RAN LOCALLY" || echo "command did not run"; rec
