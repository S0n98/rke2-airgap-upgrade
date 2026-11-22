#!/bin/bash
# Open required firewalld ports for an RKE2 server or agent node.
# Must be run as root on the target node after firewalld is installed.
#
# Usage: sudo bash open-firewall.sh [server|agent]
# Default: server

set -euo pipefail

ROLE="${1:-server}"

if [[ "$ROLE" != "server" && "$ROLE" != "agent" ]]; then
  echo "Usage: $0 [server|agent]"
  exit 1
fi

# Check firewalld is running
if ! systemctl is-active firewalld &>/dev/null; then
  echo "firewalld is not running — starting and enabling it"
  systemctl enable --now firewalld
fi

echo "=== Opening RKE2 firewall ports ($ROLE node) ==="

# Ports needed on BOTH server and agent nodes
common_ports=(
  "10250/tcp"      # kubelet API
  "8472/udp"       # Canal VXLAN
  "51820/udp"      # Canal WireGuard (optional but harmless to open)
  "30000-32767/tcp" # NodePort range
  "30000-32767/udp" # NodePort range
)

# Ports needed only on server nodes
server_ports=(
  "6443/tcp"   # Kubernetes API server
  "9345/tcp"   # RKE2 supervisor API (agent registration)
  "2379/tcp"   # etcd client
  "2380/tcp"   # etcd peer
  "4240/tcp"   # Canal health check
  "10257/tcp"  # kube-controller-manager
  "10259/tcp"  # kube-scheduler
)

echo ""
echo "--- Common ports (all nodes) ---"
for port in "${common_ports[@]}"; do
  firewall-cmd --permanent --add-port="${port}" &>/dev/null
  echo "  Opened: ${port}"
done

if [[ "$ROLE" == "server" ]]; then
  echo ""
  echo "--- Server-only ports ---"
  for port in "${server_ports[@]}"; do
    firewall-cmd --permanent --add-port="${port}" &>/dev/null
    echo "  Opened: ${port}"
  done
fi

firewall-cmd --reload

echo ""
echo "=== Current open ports ==="
firewall-cmd --list-ports

echo ""
echo "Active zones:"
firewall-cmd --get-active-zones
