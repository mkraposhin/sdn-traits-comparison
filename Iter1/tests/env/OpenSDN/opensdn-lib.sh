#!/bin/bash
#
# opensdn-lib.sh - shared helpers for opensdn-flows-{setup,install,cleanup}.sh
#
# Source this file; it defines functions only, no side effects.
# Implements the exact request formats documented in the
# "OpenSDN vRouter Forwarder flows" tutorial (and the basic tutorial it
# builds on): vr_vrf_req, vr_interface_req, vr_nexthop_req, vr_mpls_req,
# vr_route_req, vr_flow_req, vr_hugepage_config.

# ---- configuration (override via environment before sourcing) ----------
: "${TOOLS_CONTAINER:=opensdn-tools}"
: "${CONT1:=cont1}"
: "${CONT2:=cont2}"
: "${VETH1:=veth1}"
: "${VETH1C:=veth1c}"
: "${VETH2:=veth2}"
: "${VETH2C:=veth2c}"
: "${IP1:=10.1.1.11}"
: "${IP2:=10.1.1.22}"
: "${VRF_ID:=1}"
: "${NH1:=1}"
: "${NH2:=2}"
: "${MCAST_NH:=100000}"
: "${MPLS1:=1}"
: "${MPLS2:=2}"
: "${UDP_PORT:=100}"
: "${OWAMP_TCP_PORT:=861}"                # owamp control channel (TCP)
: "${VIF_MAC:=00:00:5e:00:01:00}"        # synthetic source MAC used in encap headers
: "${WORKDIR:=/tmp/opensdn-run}"          # host-side scratch dir for generated XML
: "${CONT_XML_DIR:=/gen_reqs}"            # where generated XML lands inside opensdn-tools

mkdir -p "$WORKDIR"

# ---- multi-pair support ---------------------------------------------------

# set_pair_vars <i> - (re)compute every per-pair identifier for pair number
# <i> (1-based) and assign them into CONT1/CONT2/VETH1/VETH1C/VETH2/VETH2C/
# IP1/IP2/NH1/NH2/MPLS1/MPLS2. Call this once per loop iteration in
# setup/install/cleanup before using those variables - it overrides
# whatever opensdn-lib.sh's defaults set them to.
#
# VRF_ID and MCAST_NH are deliberately NOT touched here: every pair shares
# ONE VRF (1) and ONE multicast/broadcast nexthop, so that all pairs'
# containers see the same 10.1.0.0/16 network (see opensdn-flows-setup.sh's
# /16 container address assignment) rather than N separate isolated VRFs.
#
# Naming/numbering scheme (per-pair pieces only - no id collisions):
#   containers : cont<i>a / cont<i>b
#   host veths : veth<i>a / veth<i>b     (container-side: veth<i>ac/veth<i>bc)
#   IPs        : 10.1.<i>.11 / 10.1.<i>.22   (all within the shared /16)
#   nexthops   : 2*i-1 / 2*i
#   MPLS labels: 2*i-1 / 2*i               (separate namespace from nexthops)
set_pair_vars() {
    local i="$1"
    CONT1="cont${i}a"
    CONT2="cont${i}b"
    VETH1="veth${i}a"
    VETH1C="veth${i}ac"
    VETH2="veth${i}b"
    VETH2C="veth${i}bc"
    IP1="10.1.${i}.11"
    IP2="10.1.${i}.22"
    NH1=$(( i * 2 - 1 ))
    NH2=$(( i * 2 ))
    MPLS1=$(( i * 2 - 1 ))
    MPLS2=$(( i * 2 ))
}

# parse_pair_count [args...] -> prints validated N (defaults to 1, first
# purely-numeric argument wins). Shared by setup/install/cleanup so "./foo.sh
# 5" and "./foo.sh 5 --full" behave the same way for the pair count.
parse_pair_count() {
    local n=1
    for arg in "$@"; do
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
            n="$arg"
            break
        fi
    done
    if [ "$n" -lt 1 ]; then
        echo "ERROR: pair count must be >= 1" >&2
        exit 1
    fi
    echo "$n"
}

# ---- conversions ---------------------------------------------------------

# ip_to_int 10.1.1.11 -> 184615178
# NOTE: vr_interface_req / vr_flow_req encode the address with the LAST
# octet as most significant (d*256^3 + c*256^2 + b*256 + a), matching the
# tutorial's own worked example (10.1.1.11 -> 184615178,
# 10.1.1.22 -> 369164554) - this is NOT standard big-endian network order.
ip_to_int() {
    local ip="$1" a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (d * 256 * 256 * 256) + (c * 256 * 256) + (b * 256) + a ))
}

to_net_port() {
    local port="$1"
    echo $(( ((port & 0xFF) << 8) | ((port >> 8) & 0xFF) ))
}

# mac_to_dec_array "aa:bb:cc:dd:ee:ff" -> "170 187 204 221 238 255"
mac_to_dec_array() {
    local mac="$1" out=()
    IFS=':' read -ra parts <<< "$mac"
    for p in "${parts[@]}"; do
        out+=( "$((16#$p))" )
    done
    echo "${out[@]}"
}

# xml_byte_list  6 "aa bb cc dd ee ff" -> <list type="byte" size="6">...</list> block
xml_byte_list() {
    local size="$1"; shift
    local vals=("$@")
    echo "<list type=\"byte\" size=\"${size}\">"
    for v in "${vals[@]}"; do
        echo "  <element>${v}</element>"
    done
    echo "</list>"
}

# xml_i32_list  2 "1 2" -> <list type="i32" size="2">...</list> block
xml_i32_list() {
    local size="$1"; shift
    local vals=("$@")
    echo "<list type=\"i32\" size=\"${size}\">"
    for v in "${vals[@]}"; do
        echo "  <element>${v}</element>"
    done
    echo "</list>"
}

xml_u64_list() {
    local size="$1"; shift
    local vals=("$@")
    echo "<list type=\"u64\" size=\"${size}\">"
    for v in "${vals[@]}"; do
        echo "  <element>${v}</element>"
    done
    echo "</list>"
}

# get_ifindex veth1  -> host OS kernel ifindex, e.g. 14
# (the number before ':' in `ip -o link show`, same value the tutorial
#  reads by eye from `ip a`, used for both vifr_idx and nhr_encap_oif_id)
get_ifindex() {
    local iface="$1"
    ip -o link show "$iface" 2>/dev/null | cut -d: -f1 | tr -d ' '
}

# get_container_mac cont1 veth1c -> container-side interface MAC
get_container_mac() {
    local cont="$1" iface="$2"
    docker exec "$cont" ip -o link show "$iface" 2>/dev/null \
        | grep -oE 'link/ether [0-9a-f:]+' | awk '{print $2}'
}

# ---- vrcli execution ------------------------------------------------------

# render_and_run <label> <xml content on stdin>
# Writes the XML to $WORKDIR/<label>.xml, copies it into the tools
# container under $CONT_XML_DIR, and runs vrcli against it.
render_and_run() {
    local label="$1"
    local host_file="${WORKDIR}/${label}.xml"
    cat > "$host_file"
    docker exec "$TOOLS_CONTAINER" mkdir -p "$CONT_XML_DIR"
    docker cp "$host_file" "${TOOLS_CONTAINER}:${CONT_XML_DIR}/${label}.xml"
    echo "== vrcli: ${label}.xml =="
    docker exec "$TOOLS_CONTAINER" vrcli --vr_kmode --send_sandesh_req "${CONT_XML_DIR}/${label}.xml"
}

# tools_exec <cmd...> - run a plain OpenSDN CLI utility (vif, nh, rt, mpls,
# flow, vrftable, dropstats) inside the tools container.
tools_exec() {
    docker exec "$TOOLS_CONTAINER" "$@"
}

# ---- pre-flight checks -----------------------------------------------------

container_is_running() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -qx "$name"
    local rcode=$?
    if [ $rcode -ne 0 ]; then
        echo "0"
    else
        echo "1"
    fi
}

interface_is_present() {
    local name="$1"
    if ip link show "$name" >/dev/null 2>&1; then
        echo "1"
    else
        echo "0"
    fi
}

require_running_container() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -qx "$name"
    local rcode=$?
    echo "rcode=$rcode"
    if [ $rcode -ne 0 ] ; then
        echo "ERROR: container '$name' is not running." >&2
        echo "This script assumes vRouter Forwarder (kernel module), and the" >&2
        echo "'$TOOLS_CONTAINER', '$CONT1', '$CONT2' containers already exist," >&2
        echo "per steps A/B/C of the OpenSDN basic vRouter Forwarder tutorial." >&2
        exit 1
    fi
}

require_vrouter_module() {
    lsmod | grep 'vrouter'
    local rcode=$?
    echo "rcode=$rcode"
    if [ $rcode -ne 0 ]; then
        echo "ERROR: the 'vrouter' kernel module is not loaded (lsmod | grep vrouter)." >&2
        echo "Build/load it per section B of the basic tutorial before running this script." >&2
        exit 1
    fi
}
