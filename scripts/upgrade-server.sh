#!/bin/bash
# Upgrade the RKE2 server node to a specific version using local airgap artifacts.
# Must be run directly on the SERVER NODE as root.
#
# Usage: ./upgrade-server.sh <target-version> <artifacts-dir>
# Example: ./upgrade-server.sh v1.28.9+rke2r1 /root/rke2-upgrade

set -euo pipefail

TARGET_VERSION="${1:-}"
ARTIFACTS_DIR="${2:-/root/rke2-upgrade}"

if [[ -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 <target-version> [artifacts-dir]"
  echo "Example: $0 v1.28.9+rke2r1 /root/rke2-upgrade"
  exit 1
fi

ARTIFACT_PATH="$ARTIFACTS_DIR/$TARGET_VERSION"

echo "=== RKE2 Server Upgrade ==="
echo "Target version : $TARGET_VERSION"
echo "Artifacts path : $ARTIFACT_PATH"
echo ""

# Verify artifacts exist
if [[ ! -f "$ARTIFACT_PATH/rke2.linux-amd64.tar.gz" ]]; then
  echo "ERROR: Tarball not found at $ARTIFACT_PATH/rke2.linux-amd64.tar.gz" >&2
  exit 1
fi

# Verify checksum
echo "[1/6] Verifying tarball checksum..."
cd "$ARTIFACT_PATH"
sha256sum -c sha256sum-amd64.txt --ignore-missing 2>&1 | grep -E "OK|FAILED"
cd - > /dev/null

# Pre-upgrade snapshot
echo "[2/6] Taking etcd snapshot..."
SNAPSHOT_NAME="pre-upgrade-$(echo "$TARGET_VERSION" | tr '+.' '-')-$(date +%Y%m%d%H%M)"
rke2 etcd-snapshot save --name "$SNAPSHOT_NAME"
echo "  Snapshot: $SNAPSHOT_NAME"

# Check disk space
AVAIL_GB=$(df / | awk 'NR==2{printf "%.0f", $4/1024/1024}')
echo "[3/6] Disk check: ${AVAIL_GB}G available"
if [[ "$AVAIL_GB" -lt 2 ]]; then
  echo "ERROR: Less than 2 GB free — clean up before upgrading" >&2
  exit 1
fi

# Install new binary from local artifact
echo "[4/6] Installing $TARGET_VERSION from local artifact..."
INSTALL_RKE2_ARTIFACT_PATH="$ARTIFACT_PATH" \
  INSTALL_RKE2_VERSION="$TARGET_VERSION" \
  bash "$ARTIFACTS_DIR/install.sh"

# Verify binary version
INSTALLED_VERSION=$(rke2 --version 2>/dev/null | awk 'NR==1{print $3}')
echo "  Installed binary: $INSTALLED_VERSION"
if [[ "$INSTALLED_VERSION" != "$TARGET_VERSION" ]]; then
  echo "ERROR: Binary version mismatch — expected $TARGET_VERSION, got $INSTALLED_VERSION" >&2
  exit 1
fi

# Restart service
echo "[5/6] Restarting rke2-server..."
systemctl restart rke2-server

# Wait for active
echo "[6/6] Waiting for rke2-server to become active..."
TIMEOUT=300
ELAPSED=0
while ! systemctl is-active rke2-server > /dev/null 2>&1; do
  if systemctl is-failed rke2-server > /dev/null 2>&1; then
    echo "ERROR: rke2-server entered failed state" >&2
    echo "Check logs: journalctl -u rke2-server --since '5 minutes ago' --no-pager | grep -E 'fatal|Error'" >&2
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timed out waiting for rke2-server to start" >&2
    exit 1
  fi
done

echo ""
echo "=== Upgrade to $TARGET_VERSION complete ==="
kubectl get nodes 2>/dev/null || echo "(kubectl not yet available — wait a few seconds and retry)"

echo ""
echo "Waiting for system pods to roll out..."
kubectl rollout status -n kube-system daemonset/rke2-canal --timeout=120s 2>/dev/null || true
kubectl rollout status -n kube-system deployment/rke2-coredns-rke2-coredns --timeout=120s 2>/dev/null || true
kubectl rollout status -n kube-system deployment/rke2-metrics-server --timeout=60s 2>/dev/null || true

echo ""
echo "Node status:"
kubectl get nodes 2>/dev/null
