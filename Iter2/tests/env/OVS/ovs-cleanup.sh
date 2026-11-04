#!/bin/bash
#
# ovs-cleanup.sh - Tear down N container pairs (containers, veths, netns
# links) created by ovs-setup.sh.
#
# The bridge itself is shared across every pair, so it is only removed
# with --full - removing it while other pairs still exist would break
# them, and tearing down only some pairs shouldn't take the rest of the
# bridge down with it.
#
# Usage: ./ovs-cleanup.sh [N_PAIRS] [--full]
#   N_PAIRS = number of container pairs to tear down (default 1)
#   --full  = also remove the OVS bridge itself

set -uo pipefail   # no -e: cleanup should keep going even if a step 404s
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovs-lib.sh"

N_PAIRS="$(parse_pair_count "$@")"
FULL=0
for arg in "$@"; do
    [ "$arg" == "--full" ] && FULL=1
done

for i in $(seq 1 "$N_PAIRS"); do
    set_pair_vars "$i"
    echo "== Removing pair $i: $CONT1/$CONT2 =="
    for CONT in "$CONT1" "$CONT2"; do
        docker rm -f "$CONT" >/dev/null 2>&1 || true
        rm -f "/var/run/netns/${CONT}"
    done
    ip link del "$VETH_HOST1" 2>/dev/null || true
    ip link del "$VETH_HOST2" 2>/dev/null || true
done

if [ "$FULL" -eq 1 ]; then
    echo "== --full: removing bridge $BRIDGE =="
    ovs-vsctl --if-exists del-br "$BRIDGE"
fi

echo "Cleaned up $N_PAIRS pair(s)."
