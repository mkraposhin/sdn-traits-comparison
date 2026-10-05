#!/bin/bash
#
# opensdn-flows-install.sh
#
# Installs a fat-flow pair (per container pair) for owamp's TCP control
# channel AND a UDP data channel between cont<i>a (client) and cont<i>b
# (server):
#
#   UDP, any port - symmetric fat flow: both cont<i>a's and cont<i>b's
#   ports wildcarded (0/0). Installed FIRST.
#
#   TCP, port ${OWAMP_TCP_PORT} (owamp control channel) - asymmetric fat
#   flow: cont<i>a's source port wildcarded, cont<i>b's port fixed at
#   ${OWAMP_TCP_PORT}. Installed SECOND (after UDP).
#
# This script only changes vRouter Forwarder state - it does not print
# any tables.
#
# Requires opensdn-flows-setup.sh <N> to have been run already (VRF, vifs,
# nexthops, MPLS labels, bridge routes for each pair already in place).
#
# Usage: sudo ./opensdn-flows-install.sh [N_PAIRS]
#   N_PAIRS = number of container pairs to install fat flows for (default 1)
#
# EXPERIMENT (temporary): set FWD_ONLY=1 in the environment to install ONLY
# the forward flow for each pair (fr_index=-1, fr_rindex=-1, fr_flags=1) and
# skip creating the reverse flow + the fwd_link step entirely. This tests
# whether a never-linked, standalone forward flow survives contact with
# real traffic, or gets replaced by a fresh Hold entry the same way a fully
# linked one did. Remove this gate once that question is settled.
#   sudo FWD_ONLY=1 ./opensdn-flows-install.sh 2

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/opensdn-lib.sh"

: "${FWD_ONLY:=0}"

N_PAIRS="$(parse_pair_count "$@")"

require_running_container "$TOOLS_CONTAINER"

# ---------------------------------------------------------------------------
# If a stale/Hold flow already exists for a given 6-tuple (e.g. from a
# previous test), it must be deleted before a fresh one can be created with
# fr_index=-1. We look it up by matching both SIP:PORT and DIP:PORT lines in
# `flow -l` (queried internally, never printed) - matching on source alone
# is ambiguous once more than one fat flow shares the same wildcarded port.
# ---------------------------------------------------------------------------
delete_existing_flow() {
    local sip="$1" sport="$2" dip="$3" dport="$4"
    local idx
    idx=$(tools_exec flow -l 2>/dev/null | awk -v spat="${sip}:${sport}" -v dpat="${dip}:${dport}" '
        /^[[:space:]]*[0-9]+(<=>[0-9]+)?[[:space:]]/ {
            src_ok = (index($0, spat) > 0) ? 1 : 0;
            if (src_ok) { print }
            next
        }
        src_ok && index($0, dpat) > 0 { print; exit }
    ' | grep -oE '[0-9]+' | head -1 || true)
    if [ -n "${idx:-}" ]; then
        tools_exec flow -i "$idx" >/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Helper: read back a flow's real index + Gen from `flow -l` by SIP:PORT +
# DIP:PORT (internal lookup only, output captured, never printed as a
# table).
# ---------------------------------------------------------------------------
find_flow_index_gen() {
    local sip="$1" sport="$2" dip="$3" dport="$4"
    tools_exec flow -l 2>/dev/null | awk -v spat="${sip}:${sport}" -v dpat="${dip}:${dport}" '
        /^[[:space:]]*[0-9]+(<=>[0-9]+)?[[:space:]]/ {
            line=$0; gsub(/<=>.*/,"",line); gsub(/^[[:space:]]+/,"",line);
            split(line, a, "[[:space:]]+"); idx=a[1];
            src_ok = (index($0, spat) > 0) ? 1 : 0;
            dst_ok = 0;
            next
        }
        src_ok && !dst_ok && index($0, dpat) > 0 { dst_ok = 1 }
        /\(Gen:/ {
            if (src_ok && dst_ok) {
                match($0, /Gen:[[:space:]]*[0-9]+/);
                gen_str=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/,"",gen_str);
                print idx, gen_str; exit
            }
            src_ok=0; dst_ok=0
        }
    '
}

# ---------------------------------------------------------------------------
# fat_vif_req <ifidx> <ip_int> <nh_id> <fat_encoded...> - vif fat-flow
# config. Takes ONE OR MORE fat_encoded (protocol<<16 | port) values so a
# vif can carry several fat-flow rules (e.g. TCP:861 AND UDP:0) at once -
# vif_fat_flow_cfg_build() in vr_interface.c indexes every companion
# prefix/mask/aggregate-plen array in parallel with
# vifr_fat_flow_protocol_port, so all of them must be sent with the SAME
# size as the encoded-value list (unused here, so just N zero elements).
# ---------------------------------------------------------------------------
fat_vif_req() {
    local ifidx="$1" ip_int="$2" nh_id="$3"; shift 3
    local encoded=("$@")
    local n="${#encoded[@]}"
    local zeros=() j
    for (( j = 0; j < n; j++ )); do zeros+=("0"); done
    cat <<XML
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
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
    <vifr_fat_flow_protocol_port type="list" identifier="54">
      $(xml_i32_list "$n" "${encoded[@]}")
    </vifr_fat_flow_protocol_port>
    <vifr_fat_flow_src_prefix_h type="list" identifier="77">
      $(xml_u64_list "$n" "${zeros[@]}")
    </vifr_fat_flow_src_prefix_h>
    <vifr_fat_flow_src_prefix_l type="list" identifier="78">
      $(xml_u64_list "$n" "${zeros[@]}")
    </vifr_fat_flow_src_prefix_l>
    <vifr_fat_flow_src_prefix_mask type="list" identifier="79">
      $(xml_byte_list "$n" "${zeros[@]}")
    </vifr_fat_flow_src_prefix_mask>
    <vifr_fat_flow_src_aggregate_plen type="list" identifier="80">
      $(xml_byte_list "$n" "${zeros[@]}")
    </vifr_fat_flow_src_aggregate_plen>
    <vifr_fat_flow_dst_prefix_h type="list" identifier="81">
      $(xml_u64_list "$n" "${zeros[@]}")
    </vifr_fat_flow_dst_prefix_h>
    <vifr_fat_flow_dst_prefix_l type="list" identifier="82">
      $(xml_u64_list "$n" "${zeros[@]}")
    </vifr_fat_flow_dst_prefix_l>
    <vifr_fat_flow_dst_prefix_mask type="list" identifier="83">
      $(xml_byte_list "$n" "${zeros[@]}")
    </vifr_fat_flow_dst_prefix_mask>
    <vifr_fat_flow_dst_aggregate_plen type="list" identifier="84">
      $(xml_byte_list "$n" "${zeros[@]}")
    </vifr_fat_flow_dst_aggregate_plen>
  </vr_interface_req>
</message></test>
XML
}

# ---------------------------------------------------------------------------
# flow_pair_req <label_prefix> <proto> <ip1_int> <ip2_int> <sip> <fwd_sport>
#               <dip> <fwd_dport> <nh1> <nh2>
#
# Installs one forward+reverse fat-flow pair for protocol <proto> between
# (sip,fwd_sport) -> (dip,fwd_dport), deleting any stale entry first,
# reading back each side's real index/Gen, and linking them via fr_rindex/
# fr_gen_id - same mechanics for every protocol, only the port values and
# fr_flow_proto differ between callers.
# ---------------------------------------------------------------------------
flow_pair_req() {
    local label="$1" proto="$2" ip1_int="$3" ip2_int="$4"
    local sip="$5" fwd_sport="$6" dip="$7" fwd_dport="$8" nh1="$9" nh2="${10}"

    # vRouter Forwarder's OWN flow.c (its "flow -f" perf test path) builds a
    # vr_flow_req with fr_flow_sport/fr_flow_dport = htons(<human port>) -
    # confirmed by reading vrouter_src/utils/flow.c directly. flow -l's print
    # path likewise always does ntohs(fe_key.flow_sport/dport) before
    # printing, for every entry (organic or manually installed) - confirmed
    # in the same file. So: the vr_flow_req XML fields must carry the
    # SWAPPED (network-order) value, or a real packet's own (network-order)
    # flow key never matches our installed entry; and since flow -l then
    # correctly ntohs()'s our (now-correct) stored value back to human form,
    # every flow-table LOOKUP (delete_existing_flow/find_flow_index_gen)
    # must search using the RAW literal port instead. This reverses the
    # previous (wrong) convention. A no-op for 0 either way, so safe for the
    # UDP any-port case too.
    local disp_sport disp_dport
    disp_sport=$(to_net_port "$fwd_sport")
    disp_dport=$(to_net_port "$fwd_dport")

    render_and_run "${label}_fwd" <<XML
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
  <vr_flow_req>
    <fr_op type="i32" identifier="1">0</fr_op>
    <fr_index type="i32" identifier="3">-1</fr_index>
    <fr_action type="i16" identifier="4">2</fr_action>
    <fr_flags type="i16" identifier="5">1</fr_flags>
    <fr_rindex type="i32" identifier="6">-1</fr_rindex>
    <fr_family type="i32" identifier="7">2</fr_family>
    <fr_flow_sip_u type="u64" identifier="8">0</fr_flow_sip_u>
    <fr_flow_sip_l type="u64" identifier="9">${ip1_int}</fr_flow_sip_l>
    <fr_flow_dip_u type="u64" identifier="10">0</fr_flow_dip_u>
    <fr_flow_dip_l type="u64" identifier="11">${ip2_int}</fr_flow_dip_l>
    <fr_flow_sport type="u16" identifier="12">${disp_sport}</fr_flow_sport>
    <fr_flow_dport type="u16" identifier="13">${disp_dport}</fr_flow_dport>
    <fr_flow_proto type="byte" identifier="14">${proto}</fr_flow_proto>
    <fr_flow_vrf type="u16" identifier="15">${VRF_ID}</fr_flow_vrf>
    <fr_ecmp_nh_index type="u32" identifier="23">4294967295</fr_ecmp_nh_index>
    <fr_src_nh_index type="u32" identifier="24">${nh1}</fr_src_nh_index>
    <fr_flow_nh_id type="u32" identifier="25">${nh1}</fr_flow_nh_id>
    <fr_qos_id type="u16" identifier="35">65535</fr_qos_id>
    <fr_underlay_ecmp_index type="byte" identifier="39">-1</fr_underlay_ecmp_index>
  </vr_flow_req>
</message></test>
XML

    local fwd_idx fwd_gen
    read -r fwd_idx fwd_gen <<< "$(find_flow_index_gen "$sip" "$fwd_sport" "$dip" "$fwd_dport")"
    if [ -z "${fwd_idx:-}" ]; then
        echo "ERROR: ${label} - could not locate the forward flow's assigned index." >&2
        exit 1
    fi
    echo "DEBUG ${label}: fwd_idx=${fwd_idx} fwd_gen=${fwd_gen}" >&2

    if [ "$FWD_ONLY" = "1" ]; then
        echo "FWD_ONLY=1: skipping reverse flow + fwd_link for ${label} - forward-only at idx=${fwd_idx} gen=${fwd_gen}." >&2
        return 0
    fi

    render_and_run "${label}_rev" <<XML
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
  <vr_flow_req>
    <fr_op type="i32" identifier="1">0</fr_op>
    <fr_index type="i32" identifier="3">-1</fr_index>
    <fr_action type="i16" identifier="4">2</fr_action>
    <fr_flags type="i16" identifier="5">4097</fr_flags>
    <fr_rindex type="i32" identifier="6">${fwd_idx}</fr_rindex>
    <fr_family type="i32" identifier="7">2</fr_family>
    <fr_flow_sip_u type="u64" identifier="8">0</fr_flow_sip_u>
    <fr_flow_sip_l type="u64" identifier="9">${ip2_int}</fr_flow_sip_l>
    <fr_flow_dip_u type="u64" identifier="10">0</fr_flow_dip_u>
    <fr_flow_dip_l type="u64" identifier="11">${ip1_int}</fr_flow_dip_l>
    <fr_flow_sport type="u16" identifier="12">${disp_dport}</fr_flow_sport>
    <fr_flow_dport type="u16" identifier="13">${disp_sport}</fr_flow_dport>
    <fr_flow_proto type="byte" identifier="14">${proto}</fr_flow_proto>
    <fr_flow_vrf type="u16" identifier="15">${VRF_ID}</fr_flow_vrf>
    <fr_ecmp_nh_index type="u32" identifier="23">4294967295</fr_ecmp_nh_index>
    <fr_src_nh_index type="u32" identifier="24">${nh2}</fr_src_nh_index>
    <fr_flow_nh_id type="u32" identifier="25">${nh2}</fr_flow_nh_id>
    <fr_qos_id type="u16" identifier="35">65535</fr_qos_id>
    <fr_underlay_ecmp_index type="byte" identifier="39">-1</fr_underlay_ecmp_index>
  </vr_flow_req>
</message></test>
XML

    local rev_idx rev_gen
    read -r rev_idx rev_gen <<< "$(find_flow_index_gen "$dip" "$fwd_dport" "$sip" "$fwd_sport")"
    if [ -z "${rev_idx:-}" ]; then
        echo "ERROR: ${label} - could not locate the reverse flow's assigned index." >&2
        exit 1
    fi
    echo "DEBUG ${label}: rev_idx=${rev_idx} rev_gen=${rev_gen}" >&2
    echo "DEBUG ${label}: fwd flow --get right after rev creation:" >&2
    tools_exec flow --get "$fwd_idx" >&2 || true

    # Re-read the forward flow's current Gen right before linking
    read -r fwd_idx fwd_gen <<< "$(find_flow_index_gen "$sip" "$fwd_sport" "$dip" "$fwd_dport")"
    echo "DEBUG ${label}: re-read fwd_idx=${fwd_idx} fwd_gen=${fwd_gen}" >&2

    render_and_run "${label}_fwd_link" <<XML
<?xml version="1.0"?>
<test><test_name> sandesh req</test_name><message>
  <vr_flow_req>
    <fr_op type="i32" identifier="1">0</fr_op>
    <fr_index type="i32" identifier="3">${fwd_idx}</fr_index>
    <fr_action type="i16" identifier="4">2</fr_action>
    <fr_flags type="i16" identifier="5">4097</fr_flags>
    <fr_rindex type="i32" identifier="6">${rev_idx}</fr_rindex>
    <fr_family type="i32" identifier="7">2</fr_family>
    <fr_flow_sip_u type="u64" identifier="8">0</fr_flow_sip_u>
    <fr_flow_sip_l type="u64" identifier="9">${ip1_int}</fr_flow_sip_l>
    <fr_flow_dip_u type="u64" identifier="10">0</fr_flow_dip_u>
    <fr_flow_dip_l type="u64" identifier="11">${ip2_int}</fr_flow_dip_l>
    <fr_flow_sport type="u16" identifier="12">${disp_sport}</fr_flow_sport>
    <fr_flow_dport type="u16" identifier="13">${disp_dport}</fr_flow_dport>
    <fr_gen_id type="byte" identifier="27">${fwd_gen}</fr_gen_id>
    <fr_flow_proto type="byte" identifier="14">${proto}</fr_flow_proto>
    <fr_flow_vrf type="u16" identifier="15">${VRF_ID}</fr_flow_vrf>
    <fr_ecmp_nh_index type="u32" identifier="23">4294967295</fr_ecmp_nh_index>
    <fr_src_nh_index type="u32" identifier="24">${nh1}</fr_src_nh_index>
    <fr_flow_nh_id type="u32" identifier="25">${nh1}</fr_flow_nh_id>
    <fr_qos_id type="u16" identifier="35">65535</fr_qos_id>
    <fr_underlay_ecmp_index type="byte" identifier="39">-1</fr_underlay_ecmp_index>
  </vr_flow_req>
</message></test>
XML

    echo "DEBUG ${label}: fwd flow --get right after fwd_link:" >&2
    tools_exec flow --get "$fwd_idx" >&2 || true
    echo "DEBUG ${label}: rev flow --get right after fwd_link:" >&2
    tools_exec flow --get "$rev_idx" >&2 || true
}

# ---------------------------------------------------------------------------
# install_pair <i> - install the fat-flow pair for pair number <i>: UDP
# (any port, both sides wildcarded) FIRST, then TCP (port
# ${OWAMP_TCP_PORT}) SECOND. set_pair_vars fills in
# CONT1/CONT2/VETH1/VETH2/IP1/IP2/VRF_ID/NH1/NH2 for this pair before the
# body runs.
# ---------------------------------------------------------------------------
install_pair() {
    local i="$1"
    set_pair_vars "$i"
    echo
    echo "===== Pair $i: $CONT1 ($IP1) <-> $CONT2 ($IP2) - UDP:* then TCP:${OWAMP_TCP_PORT} ====="

    local IP1_INT IP2_INT IFIDX1 IFIDX2
    IP1_INT=$(ip_to_int "$IP1")
    IP2_INT=$(ip_to_int "$IP2")
    IFIDX1=$(get_ifindex "$VETH1")
    IFIDX2=$(get_ifindex "$VETH2")
    read -ra VIFMAC_ARR <<< "$(mac_to_dec_array "$VIF_MAC")"

    # -- fat-flow vif config: encoded as (protocol<<16)|port, port stored
    # RAW/unswapped - vif_fat_flow_cfg_build() (vr_interface.c) copies
    # VIF_FAT_FLOW_PORT(protocol_port) straight into cfg.port with no byte
    # swap, and vif_fat_flow_lookup() queries that bitmap with
    # h_dport = ntohs(dport) - i.e. the HOST-order/human port value, not
    # the swapped display value (opposite of the vr_flow_req XML fields
    # below, which DO need the swapped value - see flow_pair_req's
    # comment). Both protocol/port entries are sent together in ONE
    # vr_interface_req per vif (proto_index-separated bitmaps in the
    # kernel, so order within this list doesn't matter) - confirmed
    # earlier via `vif --get` showing both rules coexisting correctly.
    # UDP fat-flow rule is port=0 ("any port") on both sides now - this is
    # the "no specific port configured, fall back to port 0 config" branch
    # in vif_fat_flow_lookup() (vr_interface.c), which sets BOTH
    # VR_FAT_FLOW_SRC_PORT_MASK and VR_FAT_FLOW_DST_PORT_MASK - i.e. every
    # UDP packet on this vif gets both ports wildcarded, regardless of
    # value, unlike TCP's single fixed-dport rule below.
    local UDP_FAT_ENCODED TCP_FAT_ENCODED
    UDP_FAT_ENCODED=$(( 0 + 17 * 65536 ))
    TCP_FAT_ENCODED=$(( OWAMP_TCP_PORT + 6 * 65536 ))

    fat_vif_req "$IFIDX1" "$IP1_INT" "$NH1" "$UDP_FAT_ENCODED" "$TCP_FAT_ENCODED" \
        | render_and_run "fat_set_vif${i}a_ip"
    fat_vif_req "$IFIDX2" "$IP2_INT" "$NH2" "$UDP_FAT_ENCODED" "$TCP_FAT_ENCODED" \
        | render_and_run "fat_set_vif${i}b_ip"

    # UDP data channel, installed FIRST: both sides wildcarded (0/0) - any
    # UDP port between the pair collapses onto this one fat-flow pair.
    flow_pair_req "udp_${i}a_to_${i}b" 17 "$IP1_INT" "$IP2_INT" \
        "$IP1" 0 "$IP2" 0 "$NH1" "$NH2"

    # TCP control channel, installed SECOND: cont<i>a sport wildcarded (0),
    # cont<i>b dport fixed at ${OWAMP_TCP_PORT} (literal, unswapped - see
    # opensdn-lib.sh header note on flow-record vs fat-flow-config port
    # representation).
    flow_pair_req "tcp_${i}a_to_${i}b" 6 "$IP1_INT" "$IP2_INT" \
        "$IP1" 0 "$IP2" "$OWAMP_TCP_PORT" "$NH1" "$NH2"
}

for i in $(seq 1 "$N_PAIRS"); do
    install_pair "$i"
done

cat <<EOF

Fat-flow installation complete for $N_PAIRS pair(s). For pair i, installed
in this order:
  1. UDP (any port, both sides wildcarded) - data channel between
     10.1.<i>.11 and 10.1.<i>.22.
  2. owamp control (TCP:${OWAMP_TCP_PORT}) between the same pair.
  Both collapse onto one fat-flow pair each instead of triggering a new
  Hold flow per connection.
  - Direction: cont<i>a is the client, cont<i>b is the server.
  - TCP has cont<i>a's source port wildcarded and cont<i>b's dest port
    fixed at ${OWAMP_TCP_PORT}. UDP has both sides fully wildcarded.
EOF
