#!/bin/bash
#
# ovs-lib.sh - shared helpers for ovs-{setup,flows,cleanup}.sh
#
# Source this file; it defines functions/variables only, no side effects
# beyond the BRIDGE default.

: "${BRIDGE:=br0}"

# set_pair_vars <i> - compute all per-pair identifiers for pair number <i>
# (1-based), matching the OpenSDN scripts' naming/addressing convention
# exactly (opensdn-lib.sh:set_pair_vars):
#   containers : cont<i>a / cont<i>b
#   host veths : veth-h<i>a / veth-h<i>b   (container-side: veth-c<i>a/veth-c<i>b)
#   IPs        : 10.1.<i>.11 / 10.1.<i>.22   (assigned /16 - see ovs-setup.sh)
set_pair_vars() {
    local i="$1"
    CONT1="cont${i}a"
    CONT2="cont${i}b"
    VETH_HOST1="veth-h${i}a"
    VETH_CT1="veth-c${i}a"
    VETH_HOST2="veth-h${i}b"
    VETH_CT2="veth-c${i}b"
    IP1="10.1.${i}.11"
    IP2="10.1.${i}.22"
}

# parse_pair_count [args...] -> prints validated N (defaults to 1, first
# purely-numeric argument wins). Shared by setup/flows/cleanup so pair
# counts and flags can be mixed on the command line consistently.
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
