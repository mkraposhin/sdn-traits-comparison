#!/bin/bash
#
# cilium-cleanup.sh - Counterpart of ovs-cleanup.sh for the Cilium setup.
#
# Usage:  sudo ./cilium-cleanup.sh [--uninstall]
#   (no option)  delete the test pods and the namespace, keep k3s + Cilium
#   --uninstall  additionally remove Cilium and k3s from the host
#                (k3s-uninstall.sh also removes its iptables rules, CNI
#                state and network interfaces). Do this before going back to
#                the OVS / OpenSDN experiments so that nothing from k3s and
#                Cilium stays on the host and loads the CPUs.
#
# Environment: KUBE_NAMESPACE (default sdn-bench)

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root: sudo $0 $*" >&2
    exit 1
fi

NS="${KUBE_NAMESPACE:-sdn-bench}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if command -v k3s >/dev/null 2>&1; then
    echo "== Deleting namespace $NS (test pods) =="
    k3s kubectl delete ns "$NS" --ignore-not-found --wait=true
fi

if [ "${1:-}" = "--uninstall" ]; then
    if command -v cilium >/dev/null 2>&1 && command -v k3s >/dev/null 2>&1; then
        echo "== Uninstalling Cilium =="
        cilium uninstall || true
    fi
    if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
        echo "== Uninstalling k3s =="
        /usr/local/bin/k3s-uninstall.sh
    else
        echo "k3s-uninstall.sh not found, k3s is not installed (or was installed differently)."
    fi
    echo "Optionally remove the CLI: rm -f /usr/local/bin/cilium"
fi
echo "Done."
