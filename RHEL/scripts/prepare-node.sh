#!/bin/bash
# One-time RHEL/Rocky/Alma node preparation for RKE2.
# Run on EVERY node (server and agent) before the first RKE2 install
# and before any upgrade that changes the RHEL major version.
#
# Covers: kernel modules, sysctl, swap, NetworkManager CNI isolation,
#         nm-cloud-setup disable, SELinux policy install.
#
# Usage: sudo bash prepare-node.sh [--selinux-rpm /path/to/rke2-selinux.rpm]

set -euo pipefail

SELINUX_RPM="${2:-}"   # optional: path to rke2-selinux RPM

RHEL_MAJOR=$(rpm -q --qf '%{VERSION}\n' redhat-release 2>/dev/null | cut -d. -f1 || \
             cat /etc/os-release 2>/dev/null | grep VERSION_ID | cut -d'"' -f2 | cut -d. -f1 || \
             echo "unknown")

echo "=== RKE2 RHEL Node Preparation ==="
echo "OS major version : RHEL/Rocky/Alma ${RHEL_MAJOR}"
echo "Date             : $(date -u)"
echo ""

# ── 1. Disable swap ───────────────────────────────────────────────────────────
echo "[1/8] Disabling swap..."
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab
echo "  Swap: disabled"

# ── 2. Install required packages ──────────────────────────────────────────────
echo "[2/8] Installing required packages..."
dnf install -y \
  container-selinux \
  iptables \
  libnetfilter_conntrack \
  libnfnetlink \
  libnftnl \
  nfs-utils \
  cryptsetup 2>&1 | tail -3

# RHEL 8: switch to iptables-legacy backend
if [[ "$RHEL_MAJOR" == "8" ]]; then
  if rpm -q iptables-legacy &>/dev/null 2>&1; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
    echo "  RHEL 8: switched to iptables-legacy backend"
  else
    echo "  RHEL 8: iptables-legacy not installed — install from base repo if network policy issues appear"
  fi
fi

# ── 3. Kernel modules ─────────────────────────────────────────────────────────
echo "[3/8] Loading and persisting kernel modules..."
modprobe overlay
modprobe br_netfilter

cat > /etc/modules-load.d/rke2.conf <<'EOF'
overlay
br_netfilter
EOF
echo "  Modules loaded: overlay, br_netfilter"

# ── 4. sysctl parameters ──────────────────────────────────────────────────────
echo "[4/8] Setting sysctl parameters..."
cat > /etc/sysctl.d/99-rke2.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null 2>&1
echo "  sysctl: net.bridge.bridge-nf-call-iptables=$(sysctl -n net.bridge.bridge-nf-call-iptables)"
echo "  sysctl: net.ipv4.ip_forward=$(sysctl -n net.ipv4.ip_forward)"

# ── 5. Disable nm-cloud-setup ─────────────────────────────────────────────────
echo "[5/8] Disabling nm-cloud-setup..."
systemctl disable --now nm-cloud-setup.service 2>/dev/null || true
systemctl disable --now nm-cloud-setup.timer   2>/dev/null || true
echo "  nm-cloud-setup: disabled"

# ── 6. NetworkManager — ignore CNI interfaces ─────────────────────────────────
echo "[6/8] Configuring NetworkManager to ignore CNI interfaces..."
cat > /etc/NetworkManager/conf.d/rke2-cni.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:cni0;interface-name:flannel.1;interface-name:veth*;interface-name:canal*
EOF
systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager
echo "  NetworkManager: CNI interfaces set to unmanaged"

# ── 7. SELinux verification and policy install ────────────────────────────────
echo "[7/8] Verifying SELinux..."
SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Unknown")
echo "  SELinux mode: $SELINUX_STATUS"

if [[ "$SELINUX_STATUS" == "Disabled" ]]; then
  echo "  WARNING: SELinux is Disabled — set SELINUX=enforcing in /etc/selinux/config and reboot"
elif [[ "$SELINUX_STATUS" == "Permissive" ]]; then
  echo "  WARNING: SELinux is Permissive — setting to Enforcing now"
  setenforce 1
  sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
fi

if [[ -n "$SELINUX_RPM" ]] && [[ -f "$SELINUX_RPM" ]]; then
  echo "  Installing rke2-selinux policy from: $SELINUX_RPM"
  rpm -ivh --replacepkgs "$SELINUX_RPM"
  echo "  Installed: $(semodule -l | grep rke2 || echo 'not found — check RPM name')"
elif semodule -l 2>/dev/null | grep -q rke2; then
  echo "  rke2-selinux policy already installed: OK"
else
  echo ""
  echo "  WARNING: rke2-selinux policy NOT found."
  echo "  Download the appropriate RPM and pass it as an argument:"
  echo "    RHEL 8: https://github.com/rancher/rke2-selinux/releases/download/v0.19.stable.1/rke2-selinux-0.19-1.el8.noarch.rpm"
  echo "    RHEL 9: https://github.com/rancher/rke2-selinux/releases/download/v0.19.stable.1/rke2-selinux-0.19-1.el9.noarch.rpm"
  echo "  Then re-run: sudo bash prepare-node.sh --selinux-rpm /path/to/rke2-selinux.rpm"
fi

# ── 8. System limits ──────────────────────────────────────────────────────────
echo "[8/8] Setting system limits..."
cat >> /etc/security/limits.conf <<'LIMEOF'
* soft nofile 1048576
* hard nofile 1048576
LIMEOF
echo "  ulimits: nofile set to 1048576"

echo ""
echo "=== Node preparation complete ==="
echo "Reboot recommended before the first RKE2 install to ensure all kernel"
echo "parameters and SELinux contexts are applied from a clean state."
echo ""
echo "Next: sudo bash RHEL/scripts/open-firewall.sh [server|agent]"
