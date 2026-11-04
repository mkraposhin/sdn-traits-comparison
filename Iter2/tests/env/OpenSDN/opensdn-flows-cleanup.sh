#!/bin/bash
#
# opensdn-flows-cleanup.sh
#
# Tears down everything created by opensdn-flows-setup.sh and
# opensdn-flows-install.sh for each of N container pairs (fat-flow
# variant):
#   - the fat forward/reverse flow table entries for that pair's UDP
#     6-tuple
#   - that pair's own L2 unicast route, nexthops, MPLS labels
#   - vifs for that pair's veths (vif --delete)
#   - veth pair on the host
#   - that pair's two containers
#
# The VRF table, the multicast/broadcast nexthop, and the broadcast route
# are SHARED across every pair (see opensdn-flows-setup.sh) and are
# therefore NOT touched by the per-pair loop below - removing them while
# other pairs still exist would break those pairs' broadcast traffic.
# They're only removed under --full, alongside opensdn-tools and the
# vrouter module.
#
# State-changing only - no table/list/dump commands are run.
#
# Pass --full to also remove the shared VRF/multicast nexthop/route,
# unload the vrouter module, and remove opensdn-tools.
#
# Usage: sudo ./opensdn-flows-cleanup.sh [N_PAIRS] [--full]
#   N_PAIRS = number of container pairs to tear down (default 1)
#   --full  = also remove shared VRF/mcast infra, opensdn-tools, vrouter module

set -uo pipefail   # no -e: cleanup should keep going even if a step 404s
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/opensdn-lib.sh"

N_PAIRS="$(parse_pair_count "$@")"
FULL=0
for arg in "$@"; do
    [ "$arg" == "--full" ] && FULL=1
done

TOOLS_UP=0
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$TOOLS_CONTAINER" && TOOLS_UP=1

# ---------------------------------------------------------------------------
# cleanup_pair <i> - tear down everything for pair number <i>. set_pair_vars
# fills in CONT1/CONT2/VETH1/VETH1C/VETH2/VETH2C/NH1/NH2/MPLS1/MPLS2 for
# this pair before the body runs (VRF_ID and MCAST_NH stay fixed and
# shared - see the note above).
# ---------------------------------------------------------------------------
cleanup_pair() {
    local i="$1"
    set_pair_vars "$i"
    echo
    echo "===== Pair $i: $CONT1/$CONT2  (shared VRF $VRF_ID) ====="

    if [ "$TOOLS_UP" -eq 1 ]; then
        echo "== Deleting flow table entries for ${IP1}/${IP2}:${UDP_PORT} =="
        tools_exec flow -l 2>/dev/null | awk -v ip1="$IP1" -v ip2="$IP2" '
            /^[[:space:]]*[0-9]+(<=>[0-9]+)?[[:space:]]/ {
                line=$0; gsub(/<=>.*/,"",line); gsub(/^[[:space:]]+/,"",line);
                split(line, a, "[[:space:]]+"); idx=a[1];
                match_this = ((index($0, ip1) > 0) || (index($0, ip2) > 0)) ? 1 : 0;
                next
            }
            match_this && /\(Gen:/ { print idx; match_this=0 }
        ' | sort -u | while read -r idx; do
                [ -n "$idx" ] && tools_exec flow -i "$idx" 2>/dev/null || true
            done

        echo "== Deleting this pair's L2 unicast routes (VRF $VRF_ID) =="
        CMAC1=$(get_container_mac "$CONT1" "$VETH1C" 2>/dev/null || true)
        CMAC2=$(get_container_mac "$CONT2" "$VETH2C" 2>/dev/null || true)
        [ -n "$CMAC1" ] && tools_exec rt --delete --vrf "$VRF_ID" --family bridge --mac "$CMAC1" 2>/dev/null || true
        [ -n "$CMAC2" ] && tools_exec rt --delete --vrf "$VRF_ID" --family bridge --mac "$CMAC2" 2>/dev/null || true

        echo "== Deleting nexthops ($NH1, $NH2) and MPLS labels ($MPLS1, $MPLS2) =="
        tools_exec mpls --delete "$MPLS1" 2>/dev/null || true
        tools_exec mpls --delete "$MPLS2" 2>/dev/null || true
        tools_exec nh --delete --id "$NH1" 2>/dev/null || true
        tools_exec nh --delete --id "$NH2" 2>/dev/null || true

        echo "== Detaching $VETH1/$VETH2 from vRouter Forwarder =="
        tools_exec vif --delete "$VETH1" 2>/dev/null || true
        tools_exec vif --delete "$VETH2" 2>/dev/null || true
    fi

    echo "== Removing veth pair on host =="
    ip link del "$VETH1" 2>/dev/null || true
    ip link del "$VETH2" 2>/dev/null || true

    echo "== Removing containers $CONT1 / $CONT2 =="
    docker rm -f "$CONT1" >/dev/null 2>&1 || true
    docker rm -f "$CONT2" >/dev/null 2>&1 || true
}

if [ "$TOOLS_UP" -ne 1 ]; then
    echo "NOTE: $TOOLS_CONTAINER is not running - skipping vRouter Forwarder"
    echo "      state cleanup (flows/routes/nexthops/vifs/VRF) for all pairs."
fi

for i in $(seq 1 "$N_PAIRS"); do
    cleanup_pair "$i"
done

rm -rf "$WORKDIR"

if [ "$FULL" -eq 1 ]; then
    if [ "$TOOLS_UP" -eq 1 ]; then
        echo
        echo "== --full: deleting shared multicast nexthop/route and VRF $VRF_ID =="
        tools_exec rt --delete --vrf "$VRF_ID" --family bridge --mac ff:ff:ff:ff:ff:ff 2>/dev/null || true
        tools_exec nh --delete --id "$MCAST_NH" 2>/dev/null || true
        render_and_run del_vrf <<XML 2>/dev/null || true
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
  <vr_vrf_req>
    <h_op type="i32" identifier="1">1</h_op>
    <vrf_rid type="i16" identifier="2">0</vrf_rid>
    <vrf_idx type="i32" identifier="3">${VRF_ID}</vrf_idx>
    <vrf_flags type="i32" identifier="4">1</vrf_flags>
  </vr_vrf_req>
</message></test>
XML
    fi
    echo "== --full: removing opensdn-tools and unloading vrouter module =="
    docker rm -f "$TOOLS_CONTAINER" >/dev/null 2>&1 || true
    rmmod vrouter 2>/dev/null || echo "   (vrouter module not loaded or busy, skipping rmmod)"
fi

echo
echo "Cleanup done for $N_PAIRS pair(s)."
