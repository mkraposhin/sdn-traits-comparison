#!/bin/bash
#
# ovs-setup.sh - Create N pairs of Docker containers wired into an OVS
# bridge with NO controller and NO flows installed yet. You add static
# flows afterwards with ovs-flows.sh, so OVS never does reactive lookups.
#
# Naming/addressing matches the OpenSDN pair scripts exactly (see
# ovs-lib.sh:set_pair_vars): containers cont<i>a/cont<i>b, IPs
# 10.1.<i>.11/10.1.<i>.22, all assigned /16 so every pair's address is
# on-link within the shared 10.1.0.0/16 network from each container's
# own routing table.
#
# Usage: ./ovs-setup.sh [N_PAIRS]
#   N_PAIRS = number of container pairs (default 1)
#
# Requires: openvswitch-switch, docker, iproute2. Run as root.
# Requires Dockerfile.ubuntu in the same directory (builds the
# net-test-ubuntu:22.04 image, used --net=none, so tools like
# ping/iperf3 must be baked in ahead of time - no internet once isolated).
# This is the SAME image/tag used by the OpenSDN scripts, so it's only
# built once regardless of which set you run first.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovs-lib.sh"

N_PAIRS="$(parse_pair_count "$@")"
IMAGE_TAG="net-test-ubuntu:22.04"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.ubuntu"
SHARED_DOCKERFILE="${SCRIPT_DIR}/../Dockerfile.ubuntu"

# Refresh the local Dockerfile.ubuntu from the shared copy two directories
# up, if one exists there - this overwrites a symlink (or a stale local
# copy) with a plain, up-to-date file each run, which sidesteps BuildKit's
# ELOOP issue with symlinks on cloud-sync FUSE mounts (Yandex.Disk, etc.).
# If there's no shared copy at that location, this is a no-op and
# DOCKERFILE is used as-is.
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

echo "== Creating OVS bridge $BRIDGE (no controller attached) =="
ovs-vsctl --may-exist add-br "$BRIDGE"
# Explicit: no controller, so there's nothing to send packet-ins to.
ovs-vsctl del-controller "$BRIDGE" 2>/dev/null || true

mkdir -p /var/run/netns

make_container() {
    local cont="$1" veth_host="$2" veth_ct="$3" ip_cidr="$4"

    echo "== Container $cont ($ip_cidr) =="

    docker rm -f "$cont" >/dev/null 2>&1 || true
    docker run -d --name "$cont" --net=none "$IMAGE_TAG" >/dev/null

    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$cont")
    ln -sf "/proc/${pid}/ns/net" "/var/run/netns/${cont}"

    # veth pair: host side -> OVS, container side -> inside netns
    ip link del "$veth_host" 2>/dev/null || true
    ip link add "$veth_host" type veth peer name "$veth_ct"

    ip link set "$veth_ct" netns "$cont"
    ip netns exec "$cont" ip link set "$veth_ct" name eth0
    ip netns exec "$cont" ip addr add "$ip_cidr" dev eth0
    ip netns exec "$cont" ip link set eth0 up
    ip netns exec "$cont" ip link set lo up

    ip link set "$veth_host" up
    ovs-vsctl --may-exist add-port "$BRIDGE" "$veth_host"

    local ofport
    ofport=$(ovs-vsctl get Interface "$veth_host" ofport)
    echo "   $cont -> $veth_host -> ofport $ofport"
}

for i in $(seq 1 "$N_PAIRS"); do
    set_pair_vars "$i"
    echo
    echo "===== Pair $i: $CONT1/$CONT2  IPs $IP1/$IP2 ====="
    make_container "$CONT1" "$VETH_HOST1" "$VETH_CT1" "${IP1}/16"
    make_container "$CONT2" "$VETH_HOST2" "$VETH_CT2" "${IP2}/16"
done

echo
echo "== Table-miss: explicit drop (deterministic, no implicit NORMAL/learning) =="
ovs-ofctl del-flows "$BRIDGE"
ovs-ofctl add-flow "$BRIDGE" "priority=0,actions=drop"

echo
echo "== Port summary =="
ovs-ofctl show "$BRIDGE"

cat <<EOF

Setup done for $N_PAIRS pair(s), all in 10.1.0.0/16. No forwarding flows
installed yet.

Use ovs-flows.sh to install static in_port -> output rules by PAIR
NUMBER (it looks up each pair's real ofport live, so this stays correct
even on a bridge with prior history):
  ./ovs-flows.sh $(seq -s' ' 1 "$N_PAIRS")
EOF
