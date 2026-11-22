#!/bin/bash
# Switch RKE2 cluster CNI from Canal (default) to pure Calico — RHEL variant.
# Includes SELinux relabeling, AVC denial check, and firewalld VXLAN port verify.
# Run AFTER a successful Kubernetes upgrade — do not mix with a k8s version bump.
#
# Usage: sudo bash RHEL/scripts/switch-cni-to-calico.sh

set -euo pipefail

KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
CTR="/var/lib/rancher/rke2/bin/ctr --address /run/k3s/containerd/containerd.sock -n k8s.io"

echo "=== RKE2 CNI Switch: Canal → Calico (RHEL) ==="
echo "Date: $(date -u)"
echo ""

# ── RHEL pre-flight checks ─────────────────────────────────────────────────────
echo "[preflight] Running RHEL-specific checks..."

# 1. SELinux rke2 policy
if ! semodule -l 2>/dev/null | grep -q rke2; then
  echo "ERROR: rke2-selinux policy not installed" >&2
  exit 1
fi
echo "  rke2-selinux policy: OK"

# 2. nm-cloud-setup guard
if systemctl is-active nm-cloud-setup.service &>/dev/null; then
  echo "ERROR: nm-cloud-setup.service is active — it will break pod networking" >&2
  exit 1
fi
echo "  nm-cloud-setup: disabled (OK)"

# 3. firewalld VXLAN port (Calico VXLAN uses UDP 4789, same as Flannel)
if systemctl is-active firewalld &>/dev/null; then
  if ! firewall-cmd --list-ports 2>/dev/null | grep -q "4789/udp"; then
    echo "  WARNING: UDP 4789 (VXLAN) not in firewalld — adding now..."
    firewall-cmd --add-port=4789/udp --permanent
    firewall-cmd --reload
    echo "  UDP 4789 added"
  else
    echo "  firewalld UDP 4789 (VXLAN): open (OK)"
  fi
fi

# ── Generic cluster pre-flights ───────────────────────────────────────────────
echo "[preflight] Checking cluster health..."

if ! $KUBECTL get nodes >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to cluster — ensure rke2-server is running" >&2
  exit 1
fi

NODE_STATUS=$($KUBECTL get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$NODE_STATUS" != "True" ]]; then
  echo "ERROR: Node is not Ready — do not switch CNI until cluster is healthy" >&2
  exit 1
fi
echo "  Cluster: OK (node is Ready)"

CURRENT_CNI=$(grep '^cni:' /etc/rancher/rke2/config.yaml 2>/dev/null | awk '{print $2}' || echo "")
if [[ "$CURRENT_CNI" == "calico" ]]; then
  echo "  CNI already set to 'calico' — nothing to do."
  exit 0
fi

if ! $CTR images ls 2>/dev/null | grep -q "hardened-calico"; then
  echo "ERROR: Calico images not found in containerd." >&2
  echo "  Install RKE2 v1.30+ tarball first to get Calico images." >&2
  exit 1
fi
CALICO_VER=$($CTR images ls 2>/dev/null | grep "hardened-calico" | grep -v '@' | awk '{print $1}' | head -1)
echo "  Calico image: $CALICO_VER"

echo ""
echo "Actions: write config → restart rke2-server → SELinux relabel → wait Calico → restart pods"
echo "Expected pod networking interruption: ~2 minutes."
read -rp "Proceed? [y/N] " CONFIRM
[[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "Aborted."; exit 0; }

# ── Write config ───────────────────────────────────────────────────────────────
echo "[1/6] Writing /etc/rancher/rke2/config.yaml (cni: calico)..."
if [[ ! -f /etc/rancher/rke2/config.yaml ]]; then
  echo "cni: calico" > /etc/rancher/rke2/config.yaml
elif grep -q '^cni:' /etc/rancher/rke2/config.yaml; then
  sed -i 's/^cni:.*/cni: calico/' /etc/rancher/rke2/config.yaml
else
  echo "cni: calico" >> /etc/rancher/rke2/config.yaml
fi
echo "  Done"

# ── Restart rke2-server ───────────────────────────────────────────────────────
echo "[2/6] Restarting rke2-server..."
systemctl restart rke2-server
sleep 5

TIMEOUT=180; ELAPSED=0
while ! systemctl is-active rke2-server >/dev/null 2>&1; do
  if systemctl is-failed rke2-server >/dev/null 2>&1; then
    echo "ERROR: rke2-server failed" >&2
    echo "  journalctl -u rke2-server -n 50 --no-pager" >&2
    echo "  ausearch -m AVC -ts recent 2>/dev/null | grep rke2 | tail -10" >&2
    exit 1
  fi
  printf "."; sleep 5; ELAPSED=$((ELAPSED+5))
  [[ $ELAPSED -ge $TIMEOUT ]] && { echo "ERROR: Timed out"; exit 1; }
done
echo " UP"

# ── SELinux relabel ───────────────────────────────────────────────────────────
echo "[3/6] Relabeling new Calico files for SELinux..."
restorecon -Rv /var/lib/rancher/rke2/ > /dev/null 2>&1 || true
echo "  restorecon: done"

AVC_COUNT=$(ausearch -m AVC -ts recent 2>/dev/null | grep -c rke2 || echo "0")
[[ "$AVC_COUNT" -gt 0 ]] && echo "  WARNING: $AVC_COUNT AVC denial(s) for rke2 — check: ausearch -m AVC -ts recent | grep rke2"

# ── Wait for Calico ───────────────────────────────────────────────────────────
echo "[4/6] Waiting for Calico node pod to be Running..."
TIMEOUT=180; ELAPSED=0
until $KUBECTL get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -q "Running"; do
  printf "."; sleep 5; ELAPSED=$((ELAPSED+5))
  [[ $ELAPSED -ge $TIMEOUT ]] && { echo "ERROR: Calico pods not Running after ${TIMEOUT}s"; exit 1; }
done
echo " Ready"

# ── Verify interface ──────────────────────────────────────────────────────────
echo "[5/6] Verifying network interfaces..."
ip link show vxlan.calico >/dev/null 2>&1 && echo "  vxlan.calico: UP" || echo "  WARNING: vxlan.calico not yet visible (transient)"
ip link show flannel.1 >/dev/null 2>&1 && echo "  flannel.1: still present (draining)" || echo "  flannel.1: gone (Canal fully removed)"

# ── Restart application pods ─────────────────────────────────────────────────
echo "[6/6] Restarting application pods to acquire Calico-managed interfaces..."
for NS in default logging ranger monitoring spark-operator nfs-provisioner; do
  $KUBECTL rollout restart deployment -n "$NS" 2>/dev/null && echo "  Deployments restarted in $NS" || true
  $KUBECTL rollout restart statefulset -n "$NS" 2>/dev/null && echo "  StatefulSets restarted in $NS" || true
done

echo ""
echo "=== CNI switch complete ==="
echo "Verify: kubectl get pods -A  (all should return to Running within ~5 min)"
echo ""
echo "Post-switch AVC check:"
echo "  ausearch -m AVC -ts today 2>/dev/null | grep calico"
