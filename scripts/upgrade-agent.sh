#!/bin/bash
# Upgrade an RKE2 agent (worker) node to a specific version.
# Must be run directly on the AGENT NODE as root.
# Cordon/drain the node from the SERVER before running this script.
#
# Usage: ./upgrade-agent.sh <target-version> <artifacts-dir>
# Example: ./upgrade-agent.sh v1.32.13+rke2r1 /root/rke2-upgrade

set -euo pipefail

TARGET_VERSION="${1:-}"
ARTIFACTS_DIR="${2:-/root/rke2-upgrade}"

if [[ -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 <target-version> [artifacts-dir]"
  echo "Example: $0 v1.32.13+rke2r1 /root/rke2-upgrade"
  exit 1
fi

ARTIFACT_PATH="$ARTIFACTS_DIR/$TARGET_VERSION"

echo "=== RKE2 Agent Upgrade ==="
echo "Target version : $TARGET_VERSION"
echo "Artifacts path : $ARTIFACT_PATH"
echo ""
echo "IMPORTANT: Cordon and drain this node from the server before proceeding:"
echo "  kubectl cordon <node-name>"
echo "  kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data"
echo ""
read -rp "Have you cordoned and drained this node? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborting. Cordon and drain first."
  exit 1
fi

# Verify artifacts
if [[ ! -f "$ARTIFACT_PATH/rke2.linux-amd64.tar.gz" ]]; then
  echo "ERROR: Tarball not found at $ARTIFACT_PATH/rke2.linux-amd64.tar.gz" >&2
  exit 1
fi

# Verify checksum
echo "[1/5] Verifying checksum..."
cd "$ARTIFACT_PATH"
sha256sum -c sha256sum-amd64.txt --ignore-missing 2>&1 | grep -E "OK|FAILED"
cd - > /dev/null

# Disk check
AVAIL_GB=$(df / | awk 'NR==2{printf "%.0f", $4/1024/1024}')
echo "[2/5] Disk check: ${AVAIL_GB}G available"
if [[ "$AVAIL_GB" -lt 2 ]]; then
  echo "ERROR: Less than 2 GB free on agent node" >&2
  exit 1
fi

# Install
echo "[3/5] Installing $TARGET_VERSION..."
INSTALL_RKE2_ARTIFACT_PATH="$ARTIFACT_PATH" \
  INSTALL_RKE2_VERSION="$TARGET_VERSION" \
  INSTALL_RKE2_TYPE="agent" \
  bash "$ARTIFACTS_DIR/install.sh"

INSTALLED_VERSION=$(rke2 --version 2>/dev/null | awk 'NR==1{print $3}')
echo "  Installed: $INSTALLED_VERSION"

# Restart
echo "[4/5] Restarting rke2-agent..."
systemctl restart rke2-agent

# Wait
echo "[5/5] Waiting for rke2-agent to become active..."
TIMEOUT=300
ELAPSED=0
while ! systemctl is-active rke2-agent > /dev/null 2>&1; do
  if systemctl is-failed rke2-agent > /dev/null 2>&1; then
    echo "ERROR: rke2-agent entered failed state" >&2
    echo "Check logs: journalctl -u rke2-agent --since '5 minutes ago' --no-pager" >&2
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timed out" >&2; exit 1
  fi
done

echo ""
echo "=== Agent upgrade to $TARGET_VERSION complete ==="
echo ""
echo "Now, from the SERVER node, verify and uncordon:"
echo "  kubectl get node <this-node-name>"
echo "  kubectl uncordon <this-node-name>"
