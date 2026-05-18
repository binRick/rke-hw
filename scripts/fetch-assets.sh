#!/usr/bin/env bash
#
# fetch-assets.sh — run this ONCE on an internet-CONNECTED host to (re)populate
# ./assets so the offline installer has everything it needs.
#
# The air-gapped target node never runs this script and never touches a network.
#
#   ./scripts/fetch-assets.sh [VERSION]
#
# VERSION defaults to the value in ./assets/VERSION, else the latest stable.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
ASSETS_DIR="${SCRIPT_DIR}/assets"
mkdir -p "$ASSETS_DIR"

VERSION="${1:-}"
if [[ -z "$VERSION" && -s "${ASSETS_DIR}/VERSION" ]]; then
  VERSION="$(cat "${ASSETS_DIR}/VERSION")"
fi
if [[ -z "$VERSION" ]]; then
  echo "[+] Resolving latest stable RKE2 version..."
  VERSION="$(curl -fsSL https://update.rke2.io/v1-release/channels \
    | python3 -c 'import sys,json;print([c["latest"] for c in json.load(sys.stdin)["data"] if c["id"]=="stable"][0])')"
fi
echo "[+] RKE2 version: ${VERSION}"

ENC="${VERSION/+/%2B}"
BASE="https://github.com/rancher/rke2/releases/download/${ENC}"

dl() { echo "[+] Downloading $1"; curl -fL --retry 3 --retry-delay 2 -o "${ASSETS_DIR}/$1" "${BASE}/$1"; }

dl "rke2.linux-amd64.tar.gz"
dl "rke2-images.linux-amd64.tar.zst"
dl "sha256sum-amd64.txt"

echo "[+] Downloading install.sh"
curl -fsSL -o "${ASSETS_DIR}/install.sh" https://get.rke2.io
chmod +x "${ASSETS_DIR}/install.sh"

echo "$VERSION" > "${ASSETS_DIR}/VERSION"

echo "[+] Verifying checksums"
cd "$ASSETS_DIR"
for f in rke2.linux-amd64.tar.gz rke2-images.linux-amd64.tar.zst; do
  exp="$(awk -v n="$f" '$2 ~ ("(^|/)" n "$"){print $1; exit}' sha256sum-amd64.txt)"
  act="$(sha256sum "$f" | awk '{print $1}')"
  [[ "$exp" == "$act" ]] && echo "    ok: $f" || { echo "    MISMATCH: $f"; exit 1; }
done

# Split the big images tarball into <100 MB parts so the repo needs no Git LFS.
# The offline installer reassembles & re-verifies these on the air-gapped node.
PART_SIZE="${PART_SIZE:-90M}"
IMG="rke2-images.linux-amd64.tar.zst"
echo "[+] Splitting ${IMG} into ${PART_SIZE} parts"
rm -f "${IMG}.part"*
split -b "$PART_SIZE" -d -a 2 "$IMG" "${IMG}.part"
sha256sum "${IMG}.part"* > rke2-images.parts.sha256
rm -f "$IMG"
echo "    $(ls "${IMG}.part"* | wc -l) parts written; ${IMG} removed (rebuilt at install time)"

echo
echo "[+] assets/ populated. Commit it, move the repo to the air-gapped node,"
echo "    then run: sudo ./install-rke2-offline.sh --type server"
