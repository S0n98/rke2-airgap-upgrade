#!/bin/bash
# Switch RKE2 cluster CNI from Canal (default) to pure Calico.
# Run AFTER a successful Kubernetes upgrade — do not mix with a k8s version bump.
#
# Usage: sudo bash switch-cni-to-calico.sh

set -euo pipefail

KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
CTR="/var/lib/rancher/rke2/bin/ctr --address /run/k3s/containerd/containerd.sock -n k8s.io"

echo "=== RKE2 CNI Switch: Canal → Calico ==="
echo "Date: $(date -u)"
echo ""

# ── Pre-flight checks ──────────────────────────────────────────────────────────
echo "[preflight] Checking cluster health..."

if ! $KUBECTL get nodes >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to cluster — ensure rke2-server is running" >&2
  exit 1
fi

NODE_STATUS=$($KUBECTL get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$NODE_STATUS" != "True" ]]; then
  echo "ERROR: Node is not Ready — do not switch CNI until cluster is fully healthy" >&2
  exit 1
fi
echo "  Cluster: OK (node is Ready)"

CURRENT_CNI=$(grep '^cni:' /etc/rancher/rke2/config.yaml 2>/dev/null | awk '{print $2}' || echo "")
if [[ "$CURRENT_CNI" == "calico" ]]; then
  echo "  CNI already set to 'calico' in config — nothing to do."
  exit 0
fi
echo "  Current CNI: ${CURRENT_CNI:-canal (RKE2 default)}"

if ! $CTR images ls 2>/dev/null | grep -q "hardened-calico"; then
  echo "ERROR: Calico images not found in containerd." >&2
  echo "  Ensure the RKE2 v1.30+ airgap tarball has been installed." >&2
  exit 1
fi
CALICO_VER=$($CTR images ls 2>/dev/null | grep "hardened-calico" | grep -v '@' | awk '{print $1}' | head -1)
echo "  Calico image: $CALICO_VER"

echo ""
echo "Actions that will be taken:"
echo "  1. Write 'cni: calico' to /etc/rancher/rke2/config.yaml"
echo "  2. systemctl restart rke2-server  (~30 s outage)"
echo "  3. Wait for calico-node DaemonSet to become Ready"
echo "  4. Verify vxlan.calico interface is up (replaces flannel.1)"
echo "  5. kubectl rollout restart all application Deployments + StatefulSets"
echo ""
echo "Expected pod networking interruption: ~2 minutes."
read -rp "Proceed? [y/N] " CONFIRM
[[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "Aborted."; exit 0; }

# ── Write config ───────────────────────────────────────────────────────────────
echo "[1/5] Writing /etc/rancher/rke2/config.yaml (cni: calico)..."
if [[ ! -f /etc/rancher/rke2/config.yaml ]]; then
  echo "cni: calico" > /etc/rancher/rke2/config.yaml
elif grep -q '^cni:' /etc/rancher/rke2/config.yaml; then
  sed -i 's/^cni:.*/cni: calico/' /etc/rancher/rke2/config.yaml
else
  echo "cni: calico" >> /etc/rancher/rke2/config.yaml
fi
grep 'cni:' /etc/rancher/rke2/config.yaml
echo "  Done"

# ── Restart rke2-server ───────────────────────────────────────────────────────
echo "[2/5] Restarting rke2-server (Canal will be removed, Calico will be installed)..."
systemctl restart rke2-server
sleep 5

TIMEOUT=180; ELAPSED=0
while ! systemctl is-active rke2-server >/dev/null 2>&1; do
  if systemctl is-failed rke2-server >/dev/null 2>&1; then
    echo "ERROR: rke2-server entered failed state" >&2
    echo "  journalctl -u rke2-server -n 50 --no-pager" >&2
    exit 1
  fi
  printf "."; sleep 5; ELAPSED=$((ELAPSED+5))
  [[ $ELAPSED -ge $TIMEOUT ]] && { echo "ERROR: Timed out waiting for rke2-server"; exit 1; }
done
echo " UP"

# ── Wait for Calico ───────────────────────────────────────────────────────────
echo "[3/5] Waiting for Calico node pod to be Running..."
TIMEOUT=180; ELAPSED=0
until $KUBECTL get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -q "Running"; do
  if $KUBECTL get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -q "Error\|CrashLoop"; then
    echo "ERROR: calico-node pod is in error state" >&2
    $KUBECTL describe pod -n kube-system -l k8s-app=calico-node >&2
    exit 1
  fi
  printf "."; sleep 5; ELAPSED=$((ELAPSED+5))
  [[ $ELAPSED -ge $TIMEOUT ]] && { echo "ERROR: Calico pods not Running after ${TIMEOUT}s"; exit 1; }
done
echo " Ready"

# ── Verify interface ──────────────────────────────────────────────────────────
echo "[4/5] Verifying network interfaces..."
if ip link show vxlan.calico >/dev/null 2>&1; then
  echo "  vxlan.calico: UP  (Calico VXLAN overlay active)"
else
  echo "  WARNING: vxlan.calico not yet visible — this is transient, CNI is still starting"
fi
if ip link show flannel.1 >/dev/null 2>&1; then
  echo "  flannel.1: still present (will disappear after all Canal pods terminate)"
else
  echo "  flannel.1: gone  (Canal fully removed)"
fi

# ── Restart application pods ─────────────────────────────────────────────────
echo "[5/5] Restarting application pods to acquire Calico-managed interfaces..."
for NS in default logging ranger monitoring spark-operator nfs-provisioner; do
  $KUBECTL rollout restart deployment -n "$NS" 2>/dev/null && echo "  Deployments restarted in $NS" || true
  $KUBECTL rollout restart statefulset -n "$NS" 2>/dev/null && echo "  StatefulSets restarted in $NS" || true
done

echo ""
echo "=== CNI switch complete ==="
echo ""
echo "Verify:"
echo "  ip link show vxlan.calico"
echo "  kubectl get pods -n kube-system | grep calico"
echo "  kubectl get pods -A   # all should return to Running within ~5 minutes"
echo ""
echo "If a pod is stuck, restart it manually:"
echo "  kubectl rollout restart deployment/<name> -n <namespace>"
