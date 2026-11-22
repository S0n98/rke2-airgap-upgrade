#!/bin/bash
# Download all RKE2 artifacts needed for a 1.27 → 1.32 airgap upgrade.
# Run this on an INTERNET-CONNECTED machine, then transfer the output directory
# to the airgap environment via SCP, USB, or your organization's data diode.
#
# Usage: ./download-artifacts.sh [output-dir]
# Default output: ./rke2-airgap-artifacts

set -euo pipefail

OUTPUT_DIR="${1:-./rke2-airgap-artifacts}"

# Upgrade path: all intermediate versions + final target
RKE2_VERSIONS=(
  "v1.28.9+rke2r1"
  "v1.29.9+rke2r1"
  "v1.30.9+rke2r1"
  "v1.31.9+rke2r1"
  "v1.32.13+rke2r1"
)

GITHUB_BASE="https://github.com/rancher/rke2/releases/download"

echo "=== RKE2 Airgap Artifact Downloader ==="
echo "Output directory: $OUTPUT_DIR"
echo "Versions: ${#RKE2_VERSIONS[@]}"
echo ""

mkdir -p "$OUTPUT_DIR"

# Download the install script once
echo "[install.sh] Downloading..."
curl -fsSL https://get.rke2.io -o "$OUTPUT_DIR/install.sh"
chmod +x "$OUTPUT_DIR/install.sh"
echo "[install.sh] Done"
echo ""

FAILED=0
for VERSION in "${RKE2_VERSIONS[@]}"; do
  ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$VERSION', safe=''))" 2>/dev/null || \
            echo "$VERSION" | sed 's/+/%2B/g')
  DIR="$OUTPUT_DIR/$VERSION"
  mkdir -p "$DIR"

  echo "--- $VERSION ---"

  # Tarball
  TARBALL_URL="${GITHUB_BASE}/${ENCODED}/rke2.linux-amd64.tar.gz"
  echo "  Downloading tarball..."
  if curl -fL --progress-bar "$TARBALL_URL" -o "$DIR/rke2.linux-amd64.tar.gz"; then
    echo "  Tarball: OK ($(du -h "$DIR/rke2.linux-amd64.tar.gz" | cut -f1))"
  else
    echo "  ERROR: Failed to download tarball for $VERSION" >&2
    FAILED=$((FAILED + 1))
    continue
  fi

  # Checksum file
  CHECKSUM_URL="${GITHUB_BASE}/${ENCODED}/sha256sum-amd64.txt"
  echo "  Downloading checksum..."
  curl -fsSL "$CHECKSUM_URL" -o "$DIR/sha256sum-amd64.txt"

  # Verify integrity
  echo "  Verifying checksum..."
  cd "$DIR"
  if sha256sum -c sha256sum-amd64.txt --ignore-missing 2>&1 | grep -q "OK"; then
    echo "  Checksum: PASSED"
  else
    echo "  ERROR: Checksum verification FAILED for $VERSION" >&2
    FAILED=$((FAILED + 1))
  fi
  cd - > /dev/null

  echo ""
done

echo "=== Summary ==="
echo "Total size: $(du -sh "$OUTPUT_DIR" | cut -f1)"
if [ "$FAILED" -eq 0 ]; then
  echo "Status: All downloads verified successfully"
  echo ""
  echo "Transfer to airgap server:"
  echo "  scp -r $OUTPUT_DIR admin@<server-ip>:/root/rke2-upgrade/"
else
  echo "Status: $FAILED version(s) FAILED — do not proceed until resolved"
  exit 1
fi
