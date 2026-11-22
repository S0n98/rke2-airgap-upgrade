#!/bin/bash
# Download all RKE2 artifacts for an airgap upgrade on RHEL-family systems.
# Run on an INTERNET-CONNECTED machine, then transfer the output directory
# to the airgap environment.
#
# In addition to the standard tarballs, this script also downloads the
# rke2-selinux policy RPM required on all RHEL/Rocky/Alma nodes.
#
# Usage: bash download-artifacts.sh [output-dir] [rhel-major-version]
# Default output-dir : ./rke2-airgap-artifacts
# Default rhel-major : 9

set -euo pipefail

OUTPUT_DIR="${1:-./rke2-airgap-artifacts}"
RHEL_MAJOR="${2:-9}"

RKE2_VERSIONS=(
  "v1.28.9+rke2r1"
  "v1.29.9+rke2r1"
  "v1.30.9+rke2r1"
  "v1.31.9+rke2r1"
  "v1.32.13+rke2r1"
)

GITHUB_BASE="https://github.com/rancher/rke2/releases/download"
SELINUX_VERSION="v0.19.stable.1"
SELINUX_RPM_VERSION="0.19-1"

echo "=== RKE2 RHEL Airgap Artifact Downloader ==="
echo "Output directory : $OUTPUT_DIR"
echo "RHEL major ver   : $RHEL_MAJOR"
echo "Versions         : ${#RKE2_VERSIONS[@]}"
echo ""

mkdir -p "$OUTPUT_DIR"

# ── install script ─────────────────────────────────────────────────────────────
echo "[install.sh] Downloading..."
curl -fsSL https://get.rke2.io -o "$OUTPUT_DIR/install.sh"
chmod +x "$OUTPUT_DIR/install.sh"
echo "[install.sh] Done"
echo ""

# ── rke2-selinux RPM ──────────────────────────────────────────────────────────
echo "[rke2-selinux] Downloading for RHEL ${RHEL_MAJOR}..."
SELINUX_RPM_FILE="rke2-selinux-${SELINUX_RPM_VERSION}.el${RHEL_MAJOR}.noarch.rpm"
SELINUX_URL="https://github.com/rancher/rke2-selinux/releases/download/${SELINUX_VERSION}/${SELINUX_RPM_FILE}"

if curl -fsSL "$SELINUX_URL" -o "$OUTPUT_DIR/$SELINUX_RPM_FILE"; then
  echo "[rke2-selinux] Downloaded: $SELINUX_RPM_FILE"
else
  echo "[rke2-selinux] WARNING: Failed to download $SELINUX_RPM_FILE"
  echo "  Try: https://github.com/rancher/rke2-selinux/releases"
fi
echo ""

# ── version tarballs ──────────────────────────────────────────────────────────
FAILED=0
for VERSION in "${RKE2_VERSIONS[@]}"; do
  ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$VERSION', safe=''))" 2>/dev/null || \
            echo "$VERSION" | sed 's/+/%2B/g')
  DIR="$OUTPUT_DIR/$VERSION"
  mkdir -p "$DIR"

  echo "--- $VERSION ---"

  TARBALL_URL="${GITHUB_BASE}/${ENCODED}/rke2.linux-amd64.tar.gz"
  CHECKSUM_URL="${GITHUB_BASE}/${ENCODED}/sha256sum-amd64.txt"

  echo "  Downloading tarball..."
  if curl -fL --progress-bar "$TARBALL_URL" -o "$DIR/rke2.linux-amd64.tar.gz"; then
    echo "  Tarball: OK ($(du -h "$DIR/rke2.linux-amd64.tar.gz" | cut -f1))"
  else
    echo "  ERROR: Failed to download tarball for $VERSION" >&2
    FAILED=$((FAILED + 1))
    continue
  fi

  echo "  Downloading checksum..."
  curl -fsSL "$CHECKSUM_URL" -o "$DIR/sha256sum-amd64.txt"

  echo "  Verifying checksum..."
  cd "$DIR"
  if sha256sum -c sha256sum-amd64.txt --ignore-missing 2>&1 | grep -q "OK"; then
    echo "  Checksum: PASSED"
  else
    echo "  ERROR: Checksum FAILED for $VERSION" >&2
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
  echo "Transfer to the airgap server:"
  echo "  scp -r $OUTPUT_DIR admin@<server-ip>:/root/rke2-upgrade/"
  echo ""
  echo "On the airgap node, install SELinux policy FIRST:"
  echo "  sudo rpm -ivh /root/rke2-upgrade/${SELINUX_RPM_FILE}"
else
  echo "Status: $FAILED version(s) FAILED — do not proceed"
  exit 1
fi
