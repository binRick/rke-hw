#!/usr/bin/env bash
#
# fetch-ha-assets.sh — run ONCE on an internet-CONNECTED host to bundle the
# extra artifacts needed for the HIGH-AVAILABILITY path:
#
#   * CloudNativePG operator manifest + images   (HA PostgreSQL)
#   * Longhorn deploy manifest + image set       (multi-node replicated storage)
#
# Everything lands in ./assets/ha as multi-image docker-archive tarballs,
# split into <90 MB parts (same Git-LFS-free scheme as the rest of the repo).
# The air-gapped side reassembles, pushes to your private registry, and
# installs both — see deploy-ha-offline.sh.
#
#   ./scripts/fetch-ha-assets.sh
#
# Version overrides (env):
#   CNPG_VERSION       (default 1.24.1)   CloudNativePG operator
#   CNPG_PG_IMAGE      (default ghcr.io/cloudnative-pg/postgresql:16.4)
#   LONGHORN_VERSION   (default v1.7.2)
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
OUT_DIR="${SCRIPT_DIR}/assets/ha"
mkdir -p "$OUT_DIR"

CNPG_VERSION="${CNPG_VERSION:-1.24.1}"
CNPG_PG_IMAGE="${CNPG_PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:16.4}"
LONGHORN_VERSION="${LONGHORN_VERSION:-v1.7.2}"
PART_SIZE="${PART_SIZE:-90M}"

ENGINE=""
if command -v podman >/dev/null 2>&1; then ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then ENGINE="docker"
else echo "[x] need podman or docker" >&2; exit 1; fi
echo "[+] Engine: ${ENGINE}"

dl() { echo "[+] Downloading $2"; curl -fsSL --retry 3 -o "$1" "$2"; }

# Save one or more images into a single multi-image archive, then split.
save_split() {
  local base="$1"; shift
  local tar="${OUT_DIR}/${base}.tar"
  echo "[+] Pulling $# image(s) for ${base}"
  local img
  for img in "$@"; do "$ENGINE" pull "$img"; done
  echo "[+] Saving -> ${base}.tar"
  if [[ "$ENGINE" == "podman" ]]; then
    podman save --multi-image-archive -o "$tar" "$@"
  else
    docker save -o "$tar" "$@"
  fi
  printf '%s\n' "$@" > "${OUT_DIR}/${base}.images"
  ( cd "$OUT_DIR" && sha256sum "${base}.tar" > "${base}.sha256" )
  echo "[+] Splitting ${base}.tar into ${PART_SIZE} parts"
  rm -f "${tar}.part"*
  split -b "$PART_SIZE" -d -a 3 "$tar" "${tar}.part"
  ( cd "$OUT_DIR" && sha256sum "${base}.tar.part"* > "${base}.parts.sha256" )
  rm -f "$tar"
  echo "    $(ls "${tar}.part"* | wc -l) part(s)"
}

# --------------------------------------------------------------------------- #
# 1. CloudNativePG
# --------------------------------------------------------------------------- #
CNPG_BRANCH="release-${CNPG_VERSION%.*}"
dl "${OUT_DIR}/cnpg-operator.yaml" \
  "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"
CNPG_OP_IMAGE="ghcr.io/cloudnative-pg/cloudnative-pg:${CNPG_VERSION}"
save_split "cnpg-images" "$CNPG_OP_IMAGE" "$CNPG_PG_IMAGE"
printf '%s\n' "$CNPG_VERSION" > "${OUT_DIR}/cnpg.version"

# --------------------------------------------------------------------------- #
# 2. Longhorn (manifest + the official per-release image list)
# --------------------------------------------------------------------------- #
LH_BASE="https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}"
dl "${OUT_DIR}/longhorn.yaml"        "${LH_BASE}/deploy/longhorn.yaml"
dl "${OUT_DIR}/longhorn-images.txt"  "${LH_BASE}/deploy/longhorn-images.txt"
printf '%s\n' "$LONGHORN_VERSION" > "${OUT_DIR}/longhorn.version"

mapfile -t LH_IMAGES < <(grep -vE '^\s*(#|$)' "${OUT_DIR}/longhorn-images.txt")
[[ ${#LH_IMAGES[@]} -gt 0 ]] || { echo "[x] longhorn-images.txt empty" >&2; exit 1; }
save_split "longhorn-images" "${LH_IMAGES[@]}"

echo
echo "[+] assets/ha populated:"
ls -1 "$OUT_DIR"
echo
echo "[+] Commit assets/ha, move the repo to the air-gapped cluster, then:"
echo "    sudo ./deploy-ha-offline.sh --registry <host:port>"
