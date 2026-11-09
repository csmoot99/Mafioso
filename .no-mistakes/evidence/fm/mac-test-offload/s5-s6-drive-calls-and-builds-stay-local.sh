#!/usr/bin/env bash
. "$(dirname "$0")/drive-lib.sh"
cfg 'host fm-mac' 'project *' 'offload' 'timeout 300'
# Stand-in for the no-mistakes CLI: the routing decision is fm-heavy.sh's; never start a real pipeline here.
mkdir -p "$LAB/fakebin"; printf '#!/bin/sh\necho "no-mistakes $* ran on $(uname -s)"\n' > "$LAB/fakebin/no-mistakes"; chmod +x "$LAB/fakebin/no-mistakes"
: > "$LAB/ssh.log"
say "S5 this PC's slot is busy and the Mac is free; a worker's pipeline drive call under project * + offload"
hold_pc 5; h=$!
(PATH="$LAB/fakebin:$PATH"; hv --class test --task s5 --project alpha-shop -- no-mistakes axi run); echo "rc=$?"; pcrec
release_pc $h
echo "ssh calls during S5: $(wc -l < "$LAB/ssh.log")"
say "S5b --remote drive call under project *: refused (exit 2), nothing sent"
(PATH="$LAB/fakebin:$PATH"; hv --class test --task s5b --project alpha-shop --remote -- no-mistakes axi run); echo "rc=$?"
echo "ssh calls: $(wc -l < "$LAB/ssh.log")"
say "S6 a build under project * + offload with this PC's slot busy waits here"
hold_pc 4; h=$!
hv --class build --task s6 --project alpha-shop -- t/check.sh BUILD 0; echo "rc=$?"; pcrec
release_pc $h
echo "ssh calls: $(wc -l < "$LAB/ssh.log")"
say "S6b a job with no --project under project * never leaves (--remote refused)"
hv --class test --task s6b --project '' --remote -- t/check.sh NOPROJ 0; echo "rc=$?"
say "S6c project <name> approval covers only that project"
cfg 'host fm-mac' 'project alpha-shop' 'timeout 300'
hv --class test --task s6c --project zeta-other --remote -- t/check.sh Z 0; echo "zeta-other --remote rc=$?"
hv --class test --task s6c --project alpha-shop --remote -- t/check.sh ALPHA-NAMED 0; echo "alpha-shop --remote rc=$?"; pcrec
