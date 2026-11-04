#!/bin/bash
#
# opensdn-flows-setup.sh
#
# Implements, in order, for each of N container pairs:
#   - Basic tutorial secs A & C: two containers, a veth pair, vif
#     attachment to vRouter Forwarder.
#   - Flows tutorial sec B: per-interface config with
#     VIF_FLAG_POLICY_ENABLED (flow-based forwarding), L2 (bridge)
#     nexthops + MPLS labels, and the L2 unicast routes for that pair.
# Hugepage/memory init, the VRF table, and the multicast/broadcast
# nexthop + route are all global (shared across every pair), not
# per-pair, since every pair now lives in ONE VRF and ONE 10.1.0.0/16
# network - the multicast nexthop is rebuilt after each pair so it always
# lists every pair's interfaces set up so far.
#
# Each pair i gets its own containers/veths/IP/nexthop/MPLS identifiers
# (see opensdn-lib.sh:set_pair_vars): containers cont<i>a/cont<i>b, veths
# veth<i>a/veth<i>b, IPs 10.1.<i>.11/10.1.<i>.22, nexthops 2i-1/2i, MPLS
# labels 2i-1/2i. Pair 1 uses the exact numbering (NH 1/2, MPLS 1/2)
# already validated end-to-end. VRF (1) and the multicast NH (100000) are
# shared constants from opensdn-lib.sh, not derived from i.
#
# After this script, each pair's two containers talk over the OpenSDN
# dataplane in FLOW mode: use opensdn-flows-install.sh next to install a
# fat-flow pair for each of them.
#
# PREREQUISITES (not automated here - see basic tutorial secs A/B):
#   - vrouter kernel module already built and loaded (lsmod | grep vrouter)
#   - the "opensdn-tools" container already running
#     (docker run --privileged --pid host --net host --name opensdn-tools -ti opensdn/opensdn-tools:latest)
#
# Usage: sudo ./opensdn-flows-setup.sh [N_PAIRS]
#   N_PAIRS = number of container pairs to set up (default 1)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/opensdn-lib.sh"

N_PAIRS="$(parse_pair_count "$@")"
IMAGE_TAG="net-test-ubuntu:22.04"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.ubuntu"

echo "== Pre-flight checks =="
require_vrouter_module
require_running_container "$TOOLS_CONTAINER"

SHARED_DOCKERFILE="${SCRIPT_DIR}/../Dockerfile.ubuntu"

# Refresh the local Dockerfile.ubuntu from the shared copy two directories
# up, if one exists there - see ovs-setup.sh's matching comment for why
# (sidesteps BuildKit's ELOOP issue with symlinks on cloud-sync mounts).
if [ -f "$SHARED_DOCKERFILE" ]; then
    rm -f "$DOCKERFILE"
    cp -f "$SHARED_DOCKERFILE" "$DOCKERFILE"
fi

echo "== Building test image ($IMAGE_TAG) if not already present =="
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    if [ ! -f "$DOCKERFILE" ]; then
        echo "ERROR: $DOCKERFILE not found next to this script." >&2
        exit 1
    fi
    docker build -t "$IMAGE_TAG" -f "$DOCKERFILE" "$SCRIPT_DIR"
else
    echo "   $IMAGE_TAG already built, skipping."
fi

# ---------------------------------------------------------------------------
# Flows tutorial sec B: vRouter Forwarder memory init - global, once only,
# regardless of how many pairs are being set up.
# ---------------------------------------------------------------------------
echo "== Initializing vRouter Forwarder memory (hugepages_conf) =="
render_and_run set_hugepages_conf <<'XML'
<?xml version="1.0"?>
<test>
  <test_name> sandesh req</test_name>
  <message>
    <vr_hugepage_config>
      <h_op type="i32" identifier="1">0</h_op>
      <vhp_mem type="list" identifier="2"><list type="u64" size="0"></list></vhp_mem>
      <vhp_psize type="list" identifier="3"><list type="u32" size="0"></list></vhp_psize>
      <vhp_mem_sz type="list" identifier="5"><list type="u32" size="0"></list></vhp_mem_sz>
      <vhp_file_paths type="list" identifier="6"><list type="byte" size="0"></list></vhp_file_paths>
      <vhp_file_path_sz type="list" identifier="7"><list type="u32" size="0"></list></vhp_file_path_sz>
    </vr_hugepage_config>
  </message>
</test>
XML

# ---------------------------------------------------------------------------
# Flows tutorial sec B: ONE shared VRF table for every pair (VRF_ID=1 by
# default). All pairs' containers live in the same VRF and the same
# 10.1.0.0/16 network - this is global, not per-pair, and runs once.
# ---------------------------------------------------------------------------
echo "== Creating shared VRF table $VRF_ID =="
render_and_run set_vrf <<XML
<?xml version="1.0"?>
<test>
  <test_name> sandesh req</test_name>
  <message>
    <vr_vrf_req>
      <h_op type="i32" identifier="1">0</h_op>
      <vrf_rid type="i16" identifier="2">0</vrf_rid>
      <vrf_idx type="i32" identifier="3">${VRF_ID}</vrf_idx>
      <vrf_flags type="i32" identifier="4">1</vrf_flags>
    </vr_vrf_req>
  </message>
</test>
XML

# ---------------------------------------------------------------------------
# Shared multicast (broadcast) nexthop: since every pair lives in the same
# VRF, there can only be ONE ff:ff:ff:ff:ff:ff bridge route for that VRF -
# so its composite nexthop must list EVERY pair's unicast nexthops, not
# just one pair's. These arrays accumulate across the loop below, and the
# composite gets rebuilt (not appended to) after each pair so it always
# covers every pair set up so far in this run.
# ---------------------------------------------------------------------------
ALL_NH=()
ALL_MPLS=()

rebuild_mcast_br_nh_and_route() {
    echo "== Rebuilding shared multicast nexthop $MCAST_NH (now covers ${#ALL_NH[@]} interfaces) =="
    render_and_run set_mcast_br_nh <<XML
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
  <vr_nexthop_req>
    <h_op type="i32" identifier="1">0</h_op>
    <nhr_type type="byte" identifier="2">6</nhr_type>
    <nhr_family type="byte" identifier="3">7</nhr_family>
    <nhr_id type="i32" identifier="4">${MCAST_NH}</nhr_id>
    <nhr_vrf type="i32" identifier="9">${VRF_ID}</nhr_vrf>
    <nhr_flags type="u32" identifier="16">2105353</nhr_flags>
    <nhr_nh_list type="list" identifier="18">
      $(xml_i32_list "${#ALL_NH[@]}" "${ALL_NH[@]}")
    </nhr_nh_list>
    <nhr_label_list type="list" identifier="19">
      $(xml_i32_list "${#ALL_MPLS[@]}" "${ALL_MPLS[@]}")
    </nhr_label_list>
  </vr_nexthop_req>
</message></test>
XML

    echo "== L2 broadcast route: FF:FF:FF:FF:FF:FF -> mcast nh $MCAST_NH =="
    render_and_run set_mcast_br_rt <<XML
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
  <vr_route_req>
    <h_op type="i32" identifier="1">0</h_op>
    <rtr_vrf_id type="i32" identifier="2">${VRF_ID}</rtr_vrf_id>
    <rtr_family type="i32" identifier="3">7</rtr_family>
    <rtr_rid type="i16" identifier="6">0</rtr_rid>
    <rtr_nh_id type="i32" identifier="9">${MCAST_NH}</rtr_nh_id>
    <rtr_mac type="list" identifier="12">
      $(xml_byte_list 6 255 255 255 255 255 255)
    </rtr_mac>
  </vr_route_req>
</message></test>
XML
}

# ---------------------------------------------------------------------------
# Everything below runs once per pair. set_pair_vars fills in
# CONT1/CONT2/VETH1/VETH1C/VETH2/VETH2C/IP1/IP2/NH1/NH2/MPLS1/MPLS2 for
# pair $1 before this function's body runs (VRF_ID and MCAST_NH stay fixed
# and shared, set above).
# ---------------------------------------------------------------------------
setup_pair() {
    local i="$1"
    set_pair_vars "$i"
    echo
    echo "===== Pair $i: $CONT1/$CONT2  (shared VRF $VRF_ID)  IPs $IP1/$IP2 ====="

    # -----------------------------------------------------------------------
    # Basic tutorial sec A: two containers with default docker networking
    # -----------------------------------------------------------------------
    for CT in "$CONT1" "$CONT2"; do
        echo "== Container $CT =="
        rcode=`container_is_running $CT`
        echo "return $rcode"
        if [ $rcode -eq 1 ]; then
            echo "Container $CT is running"
        else
            docker rm -f "$CT" >/dev/null 2>&1 || true
            docker run -d --cap-add=NET_ADMIN --name "$CT" "$IMAGE_TAG" sleep infinity >/dev/null
        fi
    done

    # -----------------------------------------------------------------------
    # Basic tutorial sec C: veth pair (host <-> container netns).
    # /16 (not /24): every pair's address is treated as on-link within the
    # shared 10.1.0.0/16, so a container's own route table needs no extra
    # routes to reach another pair's containers in the same VRF.
    # -----------------------------------------------------------------------
    make_veth() {
        local veth="$1" vethc="$2" cont="$3" ip_cidr="$4"
        local pid
        pid=$(docker inspect -f '{{.State.Pid}}' "$cont")
        echo "== veth $veth/$vethc for $cont (pid $pid), IP $ip_cidr =="
        ip link del "$veth" 2>/dev/null || true
        ip link add "$veth" type veth peer name "$vethc"
        ip link set "$vethc" netns "$pid"
        ip link set dev "$veth" up
        docker exec "$cont" ip link set dev "$vethc" up
        docker exec "$cont" ip addr add "$ip_cidr" dev "$vethc"
    }

    rcode=`interface_is_present $VETH1`
    if [ $rcode -eq 0 ]; then
        make_veth "$VETH1" "$VETH1C" "$CONT1" "${IP1}/16"
    fi
    rcode=`interface_is_present $VETH2`
    if [ $rcode -eq 0 ]; then
        make_veth "$VETH2" "$VETH2C" "$CONT2" "${IP2}/16"
    fi

    # -----------------------------------------------------------------------
    # Basic tutorial sec C: attach veth1/veth2 to vRouter Forwarder
    # -----------------------------------------------------------------------
    echo "== Attaching $VETH1 / $VETH2 to vRouter Forwarder =="
    tools_exec vif --add "$VETH1" --mac "$VIF_MAC" --vrf "$VRF_ID" --type virtual --transport virtual
    tools_exec vif --add "$VETH2" --mac "$VIF_MAC" --vrf "$VRF_ID" --type virtual --transport virtual

    # ---- interface config with VIF_FLAG_POLICY_ENABLED (flow-based) ------
    IFIDX1=$(get_ifindex "$VETH1")
    IFIDX2=$(get_ifindex "$VETH2")
    IP1_INT=$(ip_to_int "$IP1")
    IP2_INT=$(ip_to_int "$IP2")
    read -ra VIFMAC_ARR <<< "$(mac_to_dec_array "$VIF_MAC")"

    echo "== $VETH1 ifindex=$IFIDX1  $VETH2 ifindex=$IFIDX2 =="

    vif_ip_req() {
        local ifidx="$1" ip_int="$2" nh_id="$3"
        cat <<XML
<?xml version="1.0"?>
<test>
  <test_name> sandesh req</test_name>
  <message>
    <vr_interface_req>
      <h_op type="i32" identifier="1">0</h_op>
      <vifr_idx type="i32" identifier="6">${ifidx}</vifr_idx>
      <vifr_ip type="u32" identifier="39">${ip_int}</vifr_ip>
      <vifr_nh_id type="i32" identifier="48">${nh_id}</vifr_nh_id>
      <vifr_flags type="i32" identifier="4">193</vifr_flags>
      <vifr_vrf type="i32" identifier="5">${VRF_ID}</vifr_vrf>
      <vifr_mcast_vrf type="i32" identifier="63">${VRF_ID}</vifr_mcast_vrf>
      <vifr_mac type="list" identifier="38">
        $(xml_byte_list 6 "${VIFMAC_ARR[@]}")
      </vifr_mac>
    </vr_interface_req>
  </message>
</test>
XML
    }

    echo "== Configuring $VETH1 (VIF_FLAG_POLICY_ENABLED, VRF $VRF_ID, nexthop $NH1) =="
    vif_ip_req "$IFIDX1" "$IP1_INT" "$NH1" | render_and_run "set_vif${i}a_ip"
    echo "== Configuring $VETH2 (VIF_FLAG_POLICY_ENABLED, VRF $VRF_ID, nexthop $NH2) =="
    vif_ip_req "$IFIDX2" "$IP2_INT" "$NH2" | render_and_run "set_vif${i}b_ip"

    # ---- L2 (bridge) nexthops: encap = [container MAC][VIF_MAC][0x0800] --
    CMAC1=$(get_container_mac "$CONT1" "$VETH1C")
    CMAC2=$(get_container_mac "$CONT2" "$VETH2C")
    read -ra CMAC1_ARR <<< "$(mac_to_dec_array "$CMAC1")"
    read -ra CMAC2_ARR <<< "$(mac_to_dec_array "$CMAC2")"

    echo "== $VETH1C MAC: $CMAC1   $VETH2C MAC: $CMAC2 =="

    br_nh_req() {
        local nh_id="$1" ifidx="$2"; shift 2
        local mac_arr=("$@")
        cat <<XML
<?xml version="1.0"?>
<test>
  <test_name> sandesh req</test_name>
  <message>
    <vr_nexthop_req>
      <h_op type="i32" identifier="1">0</h_op>
      <nhr_type type="byte" identifier="2">2</nhr_type>
      <nhr_family type="byte" identifier="3">7</nhr_family>
      <nhr_id type="i32" identifier="4">${nh_id}</nhr_id>
      <nhr_encap_oif_id type="list" identifier="6">
        $(xml_i32_list 3 "${ifidx}" "-1" "-1")
      </nhr_encap_oif_id>
      <nhr_encap_len type="i32" identifier="7">14</nhr_encap_len>
      <nhr_vrf type="i32" identifier="9">${VRF_ID}</nhr_vrf>
      <nhr_flags type="u32" identifier="16">2097153</nhr_flags>
      <nhr_encap type="list" identifier="17">
        $(xml_byte_list 14 "${mac_arr[@]}" "${VIFMAC_ARR[@]}" "8" "0")
      </nhr_encap>
      <nhr_encap_valid type="list" identifier="30">
        $(xml_i32_list 3 "1" "0" "0")
      </nhr_encap_valid>
    </vr_nexthop_req>
  </message>
</test>
XML
    }

    echo "== L2 nexthop $NH1 -> $VETH1C ($CMAC1) =="
    br_nh_req "$NH1" "$IFIDX1" "${CMAC1_ARR[@]}" | render_and_run "set_cont${i}a_br_nh"
    echo "== L2 nexthop $NH2 -> $VETH2C ($CMAC2) =="
    br_nh_req "$NH2" "$IFIDX2" "${CMAC2_ARR[@]}" | render_and_run "set_cont${i}b_br_nh"

    echo "== MPLS labels: $MPLS1 -> nh $NH1, $MPLS2 -> nh $NH2 =="
    render_and_run "set_mpls${i}a" <<XML
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
  <vr_mpls_req>
    <h_op type="i32" identifier="1">0</h_op>
    <mr_label type="i32" identifier="2">${MPLS1}</mr_label>
    <mr_nhid  type="i32" identifier="4">${NH1}</mr_nhid>
  </vr_mpls_req>
</message></test>
XML
    render_and_run "set_mpls${i}b" <<XML
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
  <vr_mpls_req>
    <h_op type="i32" identifier="1">0</h_op>
    <mr_label type="i32" identifier="2">${MPLS2}</mr_label>
    <mr_nhid  type="i32" identifier="4">${NH2}</mr_nhid>
  </vr_mpls_req>
</message></test>
XML

    echo "== Extending shared multicast nexthop $MCAST_NH with $NH1, $NH2 =="
    ALL_NH+=("$NH1" "$NH2")
    ALL_MPLS+=("$MPLS1" "$MPLS2")
    rebuild_mcast_br_nh_and_route

    # ---- L2 (bridge) routes: MAC prefix -> nexthop ------------------------
    br_rt_req() {
        local nh_id="$1"; shift
        local mac_arr=("$@")
        cat <<XML
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
  <vr_route_req>
    <h_op type="i32" identifier="1">0</h_op>
    <rtr_vrf_id type="i32" identifier="2">${VRF_ID}</rtr_vrf_id>
    <rtr_family type="i32" identifier="3">7</rtr_family>
    <rtr_rid type="i16" identifier="6">0</rtr_rid>
    <rtr_nh_id type="i32" identifier="9">${nh_id}</rtr_nh_id>
    <rtr_mac type="list" identifier="12">
      $(xml_byte_list 6 "${mac_arr[@]}")
    </rtr_mac>
  </vr_route_req>
</message></test>
XML
    }

    echo "== L2 route: $CMAC1 -> nh $NH1 =="
    br_rt_req "$NH1" "${CMAC1_ARR[@]}" | render_and_run "set_cont${i}a_br_rt"
    echo "== L2 route: $CMAC2 -> nh $NH2 =="
    br_rt_req "$NH2" "${CMAC2_ARR[@]}" | render_and_run "set_cont${i}b_br_rt"
}

for i in $(seq 1 "$N_PAIRS"); do
    setup_pair "$i"
done

cat <<EOF

Setup complete for $N_PAIRS pair(s), all in shared VRF ${VRF_ID} and the
10.1.0.0/16 network. For pair i: containers cont<i>a (10.1.<i>.11) and
cont<i>b (10.1.<i>.22) are wired through vRouter Forwarder in FLOW mode
(VIF_FLAG_POLICY_ENABLED).

Next: run opensdn-flows-install.sh $N_PAIRS to install a fat-flow pair
for UDP port ${UDP_PORT} on each of them.
EOF
