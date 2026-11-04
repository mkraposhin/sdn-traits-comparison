#!/bin/bash
#
# cilium-setup.sh - Single-node Kubernetes (k3s) + Cilium, plus N pairs of
# test pods cont<i>a / cont<i>b built from the SAME custom Ubuntu image
# (Dockerfile.ubuntu) as the OVS and OpenSDN tests.
#
# Counterpart of ovs-setup.sh. Unlike OVS / OpenSDN there is NO forwarding
# table to install by hand: Cilium's eBPF programs on the pods' veths look
# the destination up in BPF maps (endpoint map / ipcache) that the Cilium
# agent fills when a pod appears. Run the tests afterwards with
#   ./iperf-owamp-multi-pair-bench.sh --kube <N_PAIRS> <M_TRIALS> ...
#
# Usage:  sudo ./cilium-setup.sh [N] [image:tag]
#   N         = number of pod pairs (default 2) -> pods cont1a,cont1b ...
#   image:tag = docker image to run in the pods. Default: $IMAGE_TAG if set,
#               else the first existing of ovs-test-ubuntu:22.04.5 /
#               net-test-ubuntu:22.04 (the tags used by ovs-setup.sh and
#               the OpenSDN setup), else a fresh build as net-test-ubuntu:22.04.
#               To see what you have: docker images
#
# Environment overrides:
#   CILIUM_VERSION   default 1.20.4  (the version the Cilium k3s guide used
#                    when this script was written; check it is still valid)
#   POD_CIDR         default 10.42.0.0/16 (k3s default pod CIDR)
#   KUBE_NAMESPACE   default sdn-bench
#   IMAGE_TAG        same as the 2nd argument (the argument wins)
#   INSTALL_K3S_VERSION   optional, pins the k3s version (reproducibility)
#
# What it does (each step is skipped if already done):
#   1. picks the test image (see above); builds it only if none exists
#   2. installs k3s WITHOUT flannel and WITHOUT kube network policy,
#      without traefik/servicelb/metrics-server/local-storage (fewer
#      background processes competing for the laptop's 4 logical CPUs)
#   3. installs the cilium CLI and Cilium in native-routing mode, eBPF host
#      routing on (legacy host routing off), masquerading off, Hubble off
#   4. imports the image from docker into k3s' containerd
#   5. creates namespace, deletes old test pods, creates 2N pods, waits
#   6. prints the settings that matter for the comparison
#
# CAVEATS - I could not run k3s/Cilium in the environment where this script
# was written (no docker, no root, no kernel access). It was only
# syntax-checked. Helm value names below follow the Cilium chart as I know it
# (routingMode, ipv4NativeRoutingCIDR, bpf.hostLegacyRouting,
# enableIPv4Masquerade, operator.replicas); step 6 prints what the agent
# really ended up with, so compare it to the expectations printed there.
#
# Requires: root, docker, curl, internet access for steps 1-3. k3s and Cilium
# change iptables / services on the host: run cilium-cleanup.sh --uninstall
# before going back to the OVS / OpenSDN experiments.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root: sudo $0 $*" >&2
    exit 1
fi

N="${1:-2}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || [ "$N" -lt 1 ]; then
    echo "ERROR: N must be a positive integer" >&2
    exit 1
fi

CILIUM_VERSION="${CILIUM_VERSION:-1.20.4}"
POD_CIDR="${POD_CIDR:-10.42.0.0/16}"
NS="${KUBE_NAMESPACE:-sdn-bench}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Dockerfile.ubuntu is only needed if the image has to be built. Same
# convention as ovs-setup.sh / opensdn-flows-setup.sh: build from a LOCAL copy
# next to this script, refreshed from the shared copy two directories up
# (tests/env/Cilium -> tests/Dockerfile.ubuntu) when that exists - a real
# file instead of a symlink sidesteps BuildKit's ELOOP issue on cloud-sync
# mounts.
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.ubuntu"
SHARED_DOCKERFILE="${SHARED_DOCKERFILE:-${SCRIPT_DIR}/../../Dockerfile.ubuntu}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Image name: 2nd argument > $IMAGE_TAG > first of the tags used by
# ovs-setup.sh / opensdn-flows-setup.sh that already exists in docker >
# otherwise build under the OpenSDN tag.
IMAGE_TAG="${2:-${IMAGE_TAG:-}}"
if [ -z "$IMAGE_TAG" ]; then
    for cand in ovs-test-ubuntu:22.04.5 net-test-ubuntu:22.04; do
        if docker image inspect "$cand" >/dev/null 2>&1; then IMAGE_TAG="$cand"; break; fi
    done
    IMAGE_TAG="${IMAGE_TAG:-net-test-ubuntu:22.04}"
fi

# ---------------------------------------------------------------------------
echo "== 1. Test image ($IMAGE_TAG) =="
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    if [ -f "$SHARED_DOCKERFILE" ]; then
        echo "   refreshing local Dockerfile.ubuntu from $SHARED_DOCKERFILE"
        rm -f "$DOCKERFILE"
        cp -f "$SHARED_DOCKERFILE" "$DOCKERFILE"
    fi
    [ -f "$DOCKERFILE" ] || { echo "ERROR: $DOCKERFILE not found (and no shared copy at $SHARED_DOCKERFILE)." >&2; exit 1; }
    echo "   not present, building from $DOCKERFILE"
    echo "   NOTE: packages in the Dockerfile are not version-pinned, so a fresh build may"
    echo "   differ from the image used for OVS / OpenSDN. Prefer an existing image:"
    echo "   sudo $0 $N <existing-image:tag>   (see: docker images)"
    docker build -t "$IMAGE_TAG" -f "$DOCKERFILE" "$SCRIPT_DIR"
else
    echo "   $IMAGE_TAG found in docker, using it."
fi

# ---------------------------------------------------------------------------
echo "== 2. k3s (no flannel, no kube network policy, minimal add-ons) =="
if ! command -v k3s >/dev/null 2>&1; then
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_EXEC='--flannel-backend=none --disable-network-policy --write-kubeconfig-mode 644 --disable=traefik --disable=servicelb --disable=metrics-server --disable=local-storage' \
        sh -
else
    echo "   k3s already installed, skipping."
fi
echo -n "   waiting for the API server "
for _ in $(seq 1 60); do
    if k3s kubectl get nodes >/dev/null 2>&1; then break; fi
    echo -n "."; sleep 2
done
echo
k3s kubectl get nodes
# 'kubectl' on PATH is a symlink to k3s when installed by the k3s script
KUBECTL="k3s kubectl"

# ---------------------------------------------------------------------------
echo "== 3. Cilium CLI + Cilium $CILIUM_VERSION =="
if ! command -v cilium >/dev/null 2>&1; then
    CLI_VERSION="$(curl -sfL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
    case "$(uname -m)" in aarch64) CLI_ARCH=arm64 ;; *) CLI_ARCH=amd64 ;; esac
    TMP="$(mktemp -d)"
    ( cd "$TMP" &&
      curl -sfL --remote-name-all \
          "https://github.com/cilium/cilium-cli/releases/download/${CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum} &&
      sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum" &&
      tar xzf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin cilium )
    rm -rf "$TMP"
else
    echo "   cilium CLI already installed, skipping."
fi

if ! $KUBECTL -n kube-system get ds cilium >/dev/null 2>&1; then
    cilium install --version "$CILIUM_VERSION" \
        --set ipam.operator.clusterPoolIPv4PodCIDRList="$POD_CIDR" \
        --set routingMode=native \
        --set ipv4NativeRoutingCIDR="$POD_CIDR" \
        --set enableIPv4Masquerade=false \
        --set bpf.hostLegacyRouting=false \
        --set operator.replicas=1 \
        --set hubble.enabled=false
else
    echo "   Cilium already installed, skipping."
fi
cilium status --wait

# ---------------------------------------------------------------------------
echo "== 4. Import $IMAGE_TAG into k3s' containerd =="
if k3s ctr images ls -q 2>/dev/null | grep -qE "(^|/)${IMAGE_TAG//./\\.}\$"; then
    echo "   already imported, skipping."
else
    docker save "$IMAGE_TAG" | k3s ctr images import -
fi

# ---------------------------------------------------------------------------
echo "== 5. Namespace $NS and $((2 * N)) pods =="
$KUBECTL get ns "$NS" >/dev/null 2>&1 || $KUBECTL create ns "$NS"
$KUBECTL -n "$NS" delete pod --all --wait=true >/dev/null 2>&1 || true

{
    for i in $(seq 1 "$N"); do
        for side in a b; do
            cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: cont${i}${side}
  namespace: ${NS}
  labels: {app: sdn-bench, pair: "${i}", role: "${side}"}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  enableServiceLinks: false
  automountServiceAccountToken: false
  containers:
  - name: main
    image: ${IMAGE_TAG}
    imagePullPolicy: Never
    command: ["sleep", "infinity"]
EOF
        done
    done
} | $KUBECTL apply -f -

$KUBECTL -n "$NS" wait --for=condition=Ready pod --all --timeout=180s
$KUBECTL -n "$NS" get pods -o wide

# ---------------------------------------------------------------------------
echo
echo "== 6. Settings that matter for the comparison =="
echo "   expected: Routing native, Host Routing BPF, Masquerading Disabled"
$KUBECTL -n kube-system exec ds/cilium -- cilium-dbg status --verbose 2>/dev/null \
    | grep -E "KubeProxyReplacement|Routing|Masquerading|Hubble|Encryption" || \
    echo "   (could not read cilium-dbg status; run: cilium status --verbose)"
echo
echo "   endpoints known to the datapath (BPF endpoint map):"
$KUBECTL -n kube-system exec ds/cilium -- cilium-dbg bpf endpoint list 2>/dev/null || true

echo
echo "Setup done. No forwarding rules to install: Cilium filled its BPF maps itself."
echo "Run a test, e.g.:"
echo "  ./iperf-owamp-multi-pair-bench.sh --kube $N 5 10 1"
