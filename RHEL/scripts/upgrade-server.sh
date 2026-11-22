#!/bin/bash
# Upgrade the RKE2 server node on RHEL/Rocky/AlmaLinux.
# Includes RHEL-specific checks: SELinux policy, AVC denial detection,
# firewalld verification, and nm-cloud-setup guard.
#
# Usage: sudo bash upgrade-server.sh <target-version> <artifacts-dir>
# Example: sudo bash upgrade-server.sh v1.28.9+rke2r1 /root/rke2-upgrade

set -euo pipefail

TARGET_VERSION="${1:-}"
ARTIFACTS_DIR="${2:-/root/rke2-upgrade}"

if [[ -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 <target-version> [artifacts-dir]"
  echo "Example: $0 v1.28.9+rke2r1 /root/rke2-upgrade"
  exit 1
fi

ARTIFACT_PATH="$ARTIFACTS_DIR/$TARGET_VERSION"

echo "=== RKE2 Server Upgrade (RHEL) ==="
echo "Target version : $TARGET_VERSION"
echo "Artifacts path : $ARTIFACT_PATH"
echo "Date           : $(date -u)"
echo ""

# ── RHEL pre-flight checks ─────────────────────────────────────────────────────
echo "[preflight] Running RHEL-specific checks..."

# 1. SELinux must be Enforcing
SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Unknown")
if [[ "$SELINUX_STATUS" != "Enforcing" ]]; then
  echo "  WARNING: SELinux is $SELINUX_STATUS — should be Enforcing in production"
fi

# 2. rke2-selinux policy must be installed
if ! semodule -l 2>/dev/null | grep -q rke2; then
  echo "  ERROR: rke2-selinux policy not found — install it before upgrading:" >&2
  echo "    rpm -ivh /root/rke2-upgrade/rke2-selinux-*.rpm" >&2
  exit 1
fi
echo "  SELinux: $SELINUX_STATUS | rke2 policy: OK"

# 3. nm-cloud-setup must not be running
if systemctl is-active nm-cloud-setup.service &>/dev/null; then
  echo "  ERROR: nm-cloud-setup.service is active — it will break pod networking." >&2
  echo "    Run: systemctl disable --now nm-cloud-setup.service nm-cloud-setup.timer" >&2
  exit 1
fi
echo "  nm-cloud-setup: disabled (OK)"

# 4. firewalld must have port 9345 open (supervisor API)
if systemctl is-active firewalld &>/dev/null; then
  if ! firewall-cmd --list-ports 2>/dev/null | grep -q "9345/tcp"; then
    echo "  WARNING: firewalld may not have port 9345/tcp open (supervisor API)"
    echo "    Run: bash RHEL/scripts/open-firewall.sh server"
  else
    echo "  firewalld: 9345/tcp open (OK)"
  fi
fi

echo ""

# ── Artifact verification ─────────────────────────────────────────────────────
if [[ ! -f "$ARTIFACT_PATH/rke2.linux-amd64.tar.gz" ]]; then
  echo "ERROR: Tarball not found at $ARTIFACT_PATH/rke2.linux-amd64.tar.gz" >&2
  exit 1
fi

echo "[1/7] Verifying tarball checksum..."
cd "$ARTIFACT_PATH"
sha256sum -c sha256sum-amd64.txt --ignore-missing 2>&1 | grep -E "OK|FAILED"
cd - > /dev/null

# ── etcd snapshot ─────────────────────────────────────────────────────────────
echo "[2/7] Taking etcd snapshot..."
SNAPSHOT_NAME="pre-upgrade-$(echo "$TARGET_VERSION" | tr '+.' '-')-$(date +%Y%m%d%H%M)"
rke2 etcd-snapshot save --name "$SNAPSHOT_NAME"
echo "  Snapshot: $SNAPSHOT_NAME"

# ── Disk check ────────────────────────────────────────────────────────────────
AVAIL_GB=$(df / | awk 'NR==2{printf "%.0f", $4/1024/1024}')
echo "[3/7] Disk check: ${AVAIL_GB}G available on /"
if [[ "$AVAIL_GB" -lt 2 ]]; then
  echo "ERROR: Less than 2 GB free — clean up before upgrading" >&2
  exit 1
fi

# ── Install ───────────────────────────────────────────────────────────────────
echo "[4/7] Installing $TARGET_VERSION from local artifact..."
INSTALL_RKE2_ARTIFACT_PATH="$ARTIFACT_PATH" \
  INSTALL_RKE2_VERSION="$TARGET_VERSION" \
  bash "$ARTIFACTS_DIR/install.sh"

INSTALLED_VERSION=$(rke2 --version 2>/dev/null | awk 'NR==1{print $3}')
echo "  Installed binary: $INSTALLED_VERSION"
if [[ "$INSTALLED_VERSION" != "$TARGET_VERSION" ]]; then
  echo "ERROR: Binary version mismatch — expected $TARGET_VERSION, got $INSTALLED_VERSION" >&2
  exit 1
fi

# Relabel new RKE2 files with correct SELinux context
echo "[5/7] Relabeling RKE2 files for SELinux..."
restorecon -Rv /var/lib/rancher/rke2/ > /dev/null 2>&1 || true
restorecon -Rv /usr/local/lib/systemd/ > /dev/null 2>&1 || true
echo "  restorecon: done"

# ── Restart ───────────────────────────────────────────────────────────────────
echo "[6/7] Restarting rke2-server..."
systemctl restart rke2-server

echo "[7/7] Waiting for rke2-server to become active..."
TIMEOUT=300
ELAPSED=0
while ! systemctl is-active rke2-server > /dev/null 2>&1; do
  if systemctl is-failed rke2-server > /dev/null 2>&1; then
    echo "" >&2
    echo "ERROR: rke2-server entered failed state" >&2
    echo "Check: journalctl -u rke2-server --since '5 minutes ago' --no-pager | grep -E 'fatal|Error'" >&2
    echo "SELinux: ausearch -m AVC -ts recent 2>/dev/null | grep rke2 | tail -10" >&2
    exit 1
  fi
  printf "."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "" >&2
    echo "ERROR: Timed out waiting for rke2-server" >&2
    exit 1
  fi
done
echo " UP"

# ── Post-restart SELinux AVC check ────────────────────────────────────────────
echo ""
AVC_COUNT=$(ausearch -m AVC -ts recent 2>/dev/null | grep -c rke2 || echo "0")
if [[ "$AVC_COUNT" -gt 0 ]]; then
  echo "WARNING: $AVC_COUNT AVC denial(s) for rke2 found after restart."
  echo "  Review: ausearch -m AVC -ts recent | grep rke2"
  echo "  These may be transient. If pods fail to start, run:"
  echo "    restorecon -Rv /var/lib/rancher/rke2/"
else
  echo "SELinux AVC check: 0 denials (OK)"
fi

echo ""
echo "=== Upgrade to $TARGET_VERSION complete ==="
kubectl get nodes 2>/dev/null || echo "(wait a few seconds and retry kubectl get nodes)"

echo ""
echo "Waiting for system pods..."
kubectl rollout status -n kube-system daemonset/rke2-canal --timeout=120s 2>/dev/null || true
kubectl rollout status -n kube-system deployment/rke2-coredns-rke2-coredns --timeout=120s 2>/dev/null || true
kubectl rollout status -n kube-system deployment/rke2-metrics-server --timeout=60s 2>/dev/null || true

echo ""
echo "Node status:"
kubectl get nodes 2>/dev/null
