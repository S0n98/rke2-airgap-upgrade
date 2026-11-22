#!/bin/bash
# Upgrade an RKE2 agent node on RHEL/Rocky/AlmaLinux.
# Includes RHEL-specific checks and SELinux relabeling.
# Cordon/drain must be done from the server before running this script.
#
# Usage: sudo bash upgrade-agent.sh <target-version> <artifacts-dir>
# Example: sudo bash upgrade-agent.sh v1.32.13+rke2r1 /root/rke2-upgrade

set -euo pipefail

TARGET_VERSION="${1:-}"
ARTIFACTS_DIR="${2:-/root/rke2-upgrade}"

if [[ -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 <target-version> [artifacts-dir]"
  exit 1
fi

ARTIFACT_PATH="$ARTIFACTS_DIR/$TARGET_VERSION"

echo "=== RKE2 Agent Upgrade (RHEL) ==="
echo "Target version : $TARGET_VERSION"
echo ""
echo "IMPORTANT: Before running this script, cordon and drain the node from the server:"
echo "  kubectl cordon <node-name>"
echo "  kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data"
echo ""
read -rp "Have you cordoned and drained this node? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborting."
  exit 1
fi

# ── RHEL pre-flight ────────────────────────────────────────────────────────────
echo "[preflight] RHEL checks..."

if ! semodule -l 2>/dev/null | grep -q rke2; then
  echo "  ERROR: rke2-selinux policy not installed — required on agent nodes too" >&2
  echo "    rpm -ivh /root/rke2-upgrade/rke2-selinux-*.rpm" >&2
  exit 1
fi
echo "  rke2-selinux policy: OK"

if systemctl is-active nm-cloud-setup.service &>/dev/null; then
  echo "  ERROR: nm-cloud-setup.service is active — disable before upgrading" >&2
  exit 1
fi
echo "  nm-cloud-setup: disabled (OK)"

if [[ ! -f "$ARTIFACT_PATH/rke2.linux-amd64.tar.gz" ]]; then
  echo "ERROR: Tarball not found at $ARTIFACT_PATH/rke2.linux-amd64.tar.gz" >&2
  exit 1
fi

echo "[1/5] Verifying checksum..."
cd "$ARTIFACT_PATH"
sha256sum -c sha256sum-amd64.txt --ignore-missing 2>&1 | grep -E "OK|FAILED"
cd - > /dev/null

AVAIL_GB=$(df / | awk 'NR==2{printf "%.0f", $4/1024/1024}')
echo "[2/5] Disk: ${AVAIL_GB}G available"
if [[ "$AVAIL_GB" -lt 2 ]]; then
  echo "ERROR: Less than 2 GB free" >&2; exit 1
fi

echo "[3/5] Installing $TARGET_VERSION..."
INSTALL_RKE2_ARTIFACT_PATH="$ARTIFACT_PATH" \
  INSTALL_RKE2_VERSION="$TARGET_VERSION" \
  INSTALL_RKE2_TYPE="agent" \
  bash "$ARTIFACTS_DIR/install.sh"

echo "  Relabeling files for SELinux..."
restorecon -Rv /var/lib/rancher/rke2/ > /dev/null 2>&1 || true

echo "[4/5] Restarting rke2-agent..."
systemctl restart rke2-agent

echo "[5/5] Waiting for rke2-agent to become active..."
TIMEOUT=300
ELAPSED=0
while ! systemctl is-active rke2-agent > /dev/null 2>&1; do
  if systemctl is-failed rke2-agent > /dev/null 2>&1; then
    echo "ERROR: rke2-agent failed to start" >&2
    echo "  journalctl -u rke2-agent --since '5 minutes ago' --no-pager | tail -20" >&2
    echo "  ausearch -m AVC -ts recent 2>/dev/null | grep rke2 | tail -10" >&2
    exit 1
  fi
  printf "."; sleep 5; ELAPSED=$((ELAPSED + 5))
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then echo "ERROR: Timed out" >&2; exit 1; fi
done
echo " UP"

AVC_COUNT=$(ausearch -m AVC -ts recent 2>/dev/null | grep -c rke2 || echo "0")
[[ "$AVC_COUNT" -gt 0 ]] && echo "WARNING: $AVC_COUNT AVC denial(s) — check: ausearch -m AVC -ts recent | grep rke2"

echo ""
echo "=== Agent $TARGET_VERSION upgrade complete ==="
echo "From the server: kubectl get node <this-node> && kubectl uncordon <this-node>"
