#!/bin/bash
# Post-upgrade cleanup: removes old RKE2 data directories from intermediate
# upgrade steps and reports disk reclaimed. Safe to run after verifying the
# cluster is healthy on the target version.
#
# Usage: ./post-upgrade-cleanup.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "(DRY RUN — no files will be deleted)"
fi

DATA_DIR="/var/lib/rancher/rke2/data"
CURRENT_VERSION=$(rke2 --version 2>/dev/null | awk 'NR==1{print $3}' | sed 's/v//; s/+/-/')

echo "=== Post-Upgrade Cleanup ==="
echo "Current RKE2 version : $(rke2 --version 2>/dev/null | awk 'NR==1{print $3}')"
echo "Current data dir     : ${DATA_DIR}/${CURRENT_VERSION}-*"
echo ""

TOTAL_FREED=0
for dir in "$DATA_DIR"/*/; do
  basename=$(basename "$dir")
  size_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
  size_mb=$((size_kb / 1024))

  if echo "$basename" | grep -q "$CURRENT_VERSION"; then
    echo "  KEEP  $basename (${size_mb} MB) — current version"
  else
    echo "  REMOVE $basename (${size_mb} MB)"
    TOTAL_FREED=$((TOTAL_FREED + size_mb))
    if [[ "$DRY_RUN" == "false" ]]; then
      rm -rf "$dir"
    fi
  fi
done

echo ""
echo "Disk to reclaim: ${TOTAL_FREED} MB"
echo ""
echo "Disk after cleanup:"
df -h /
