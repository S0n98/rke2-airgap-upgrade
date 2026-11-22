#!/bin/bash
# Post-upgrade cleanup for RHEL: removes old RKE2 data directories,
# verifies SELinux labels are correct, and reports disk reclaimed.
#
# Usage: sudo bash post-upgrade-cleanup.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true && echo "(DRY RUN — no files deleted)"

CURRENT=$(rke2 --version 2>/dev/null | awk 'NR==1{print $3}' | sed 's/v//; s/+/-/')

echo "=== Post-Upgrade Cleanup (RHEL) ==="
echo "Current version : $(rke2 --version 2>/dev/null | awk 'NR==1{print $3}')"
echo "Date            : $(date -u)"
echo ""

# ── Old data directories ───────────────────────────────────────────────────────
echo "--- Removing old RKE2 data directories ---"
TOTAL_FREED=0
for dir in /var/lib/rancher/rke2/data/*/; do
  bname=$(basename "$dir")
  size_mb=$(( $(du -sk "$dir" 2>/dev/null | cut -f1) / 1024 ))
  if echo "$bname" | grep -q "$CURRENT"; then
    echo "  KEEP  $bname (${size_mb} MB)"
  else
    echo "  REMOVE $bname (${size_mb} MB)"
    TOTAL_FREED=$((TOTAL_FREED + size_mb))
    [[ "$DRY_RUN" == "false" ]] && rm -rf "$dir"
  fi
done
echo "  Reclaimed: ${TOTAL_FREED} MB"

# ── SELinux context verification ──────────────────────────────────────────────
echo ""
echo "--- Verifying SELinux contexts ---"
MISLABELED=$(find /var/lib/rancher/rke2/ -maxdepth 3 2>/dev/null | \
  restorecon -n -v 2>&1 | grep -c "relabeled" || echo "0")

if [[ "$MISLABELED" -gt 0 ]]; then
  echo "  $MISLABELED file(s) have incorrect SELinux context — relabeling now..."
  [[ "$DRY_RUN" == "false" ]] && restorecon -Rv /var/lib/rancher/rke2/ > /dev/null 2>&1
  echo "  Relabeling complete"
else
  echo "  All SELinux contexts correct"
fi

# ── AVC denial check ──────────────────────────────────────────────────────────
echo ""
echo "--- Recent SELinux AVC denials for rke2 ---"
AVC_COUNT=$(ausearch -m AVC -ts today 2>/dev/null | grep -c rke2 || echo "0")
if [[ "$AVC_COUNT" -gt 0 ]]; then
  echo "  WARNING: $AVC_COUNT AVC denial(s) today involving rke2"
  echo "  Review: ausearch -m AVC -ts today | grep rke2"
else
  echo "  No AVC denials today (OK)"
fi

echo ""
echo "--- Disk after cleanup ---"
df -h /
echo ""
echo "=== Cleanup complete ==="
