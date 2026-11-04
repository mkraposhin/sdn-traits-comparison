#!/bin/bash
#
# ovs-flows.sh - Install static, non-learning forwarding flows on br0
# for one or more container pairs created by ovs-setup.sh.
#
# Each flow matches ONLY on in_port and outputs to a fixed port number
# (the simplest possible nexthop rule - no MAC/IP lookup, no learning,
# no controller consultation).
#
# Takes PAIR NUMBERS, not raw ofport numbers: each pair's actual ofport
# is looked up live via ovs-vsctl right before installing its flow. This
# is deliberate - ofport numbers are NOT guaranteed to equal pair/
# container index (OVS never reuses ofports within a bridge's lifetime,
# so a bridge with any prior history drifts the numbering), and passing
# stale/guessed ofport numbers silently installs flows for the wrong, or
# nonexistent, ports.
#
# Usage: ./ovs-flows.sh <pair> [pair ...]
#   Example: ./ovs-flows.sh 1 2 3 4
#   Installs bidirectional flows for pairs 1-4: cont1a<->cont1b,
#   cont2a<->cont2b, cont3a<->cont3b, cont4a<->cont4b.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovs-lib.sh"

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <pair> [pair ...]"
    echo "Example: $0 1 2 3 4"
    exit 1
fi

for i in "$@"; do
    if ! [[ "$i" =~ ^[0-9]+$ ]]; then
        echo "ERROR: '$i' is not a pair number (expected e.g. 1 2 3)." >&2
        exit 1
    fi
    set_pair_vars "$i"

    A=$(ovs-vsctl get Interface "$VETH_HOST1" ofport 2>/dev/null) || {
        echo "ERROR: interface $VETH_HOST1 (pair $i) not found on $BRIDGE - run ovs-setup.sh first." >&2
        exit 1
    }
    B=$(ovs-vsctl get Interface "$VETH_HOST2" ofport 2>/dev/null) || {
        echo "ERROR: interface $VETH_HOST2 (pair $i) not found on $BRIDGE - run ovs-setup.sh first." >&2
        exit 1
    }

    echo "Pair $i: $VETH_HOST1 (ofport $A) <-> $VETH_HOST2 (ofport $B)"
    ovs-ofctl add-flow "$BRIDGE" "priority=100,in_port=${A},actions=output:${B}"
    ovs-ofctl add-flow "$BRIDGE" "priority=100,in_port=${B},actions=output:${A}"
done

echo
echo "== Current flow table (static only, nothing reactive) =="
ovs-ofctl dump-flows "$BRIDGE"
