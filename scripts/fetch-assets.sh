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

# --------------------------------------------------------------------------- #
# Private OCI registry image (registry:2) — for the air-gapped registry so the
# cluster has somewhere to store/serve YOUR application images.
# Saved as a docker-archive tarball that `podman load` reads offline.
# --------------------------------------------------------------------------- #
REGISTRY_IMAGE="${REGISTRY_IMAGE:-docker.io/library/registry:2.8.3}"
REG_TAR="${ASSETS_DIR}/registry-image.tar"
echo "[+] Bundling private registry image: ${REGISTRY_IMAGE}"
if command -v skopeo >/dev/null 2>&1; then
  skopeo copy --retry-times 3 \
    "docker://${REGISTRY_IMAGE}" "docker-archive:${REG_TAR}:${REGISTRY_IMAGE}"
elif command -v docker >/dev/null 2>&1; then
  docker pull "$REGISTRY_IMAGE"
  docker save "$REGISTRY_IMAGE" -o "$REG_TAR"
elif command -v podman >/dev/null 2>&1; then
  podman pull "$REGISTRY_IMAGE"
  podman save --format docker-archive -o "$REG_TAR" "$REGISTRY_IMAGE"
else
  echo "    !! need skopeo, docker, or podman to fetch the registry image" >&2
  exit 1
fi
printf '%s\n' "$REGISTRY_IMAGE" > "${ASSETS_DIR}/registry-image.ref"
( cd "$ASSETS_DIR" && sha256sum "$(basename "$REG_TAR")" > registry-image.sha256 )
reg_mb=$(( $(stat -c%s "$REG_TAR") / 1024 / 1024 ))
echo "    ok: registry-image.tar (${reg_mb} MB)"
[[ $reg_mb -ge 100 ]] && echo "    !! >100 MB — split before committing (GitHub limit)" >&2

# --------------------------------------------------------------------------- #
# SELinux policy RPMs (EL9 + EL10) so a SELinux-Enforcing RHEL/Rocky host is
# clone-and-go. The installer auto-picks the one matching the host's EL major.
#   rke2-selinux  : from the rancher/rke2-selinux GitHub release
#   container-selinux (its dependency): latest from CentOS Stream AppStream,
#       resolved via repodata so the URL never rots.
# --------------------------------------------------------------------------- #
RKE2_SELINUX_TAG="${RKE2_SELINUX_TAG:-v0.22.latest.1}"
echo "[+] Bundling SELinux RPMs (rke2-selinux ${RKE2_SELINUX_TAG} + container-selinux)"

gh_assets_json="$(curl -fsSL "https://api.github.com/repos/rancher/rke2-selinux/releases/tags/${RKE2_SELINUX_TAG}")"
for el in 9 10; do
  url="$(printf '%s' "$gh_assets_json" | python3 -c "import sys,json
d=json.load(sys.stdin)
for a in d['assets']:
    n=a['name']
    if n.endswith('.el${el}.noarch.rpm') and 'src' not in n:
        print(a['browser_download_url']); break")"
  [[ -n "$url" ]] || { echo "    !! no rke2-selinux el${el} asset in ${RKE2_SELINUX_TAG}" >&2; continue; }
  echo "    rke2-selinux el${el}: $(basename "$url")"
  curl -fL --retry 3 -o "${ASSETS_DIR}/$(basename "$url")" "$url"
done

resolve_container_selinux() {  # $1 = EL major (9|10)
  local el="$1" base="https://mirror.stream.centos.org/${el}-stream/AppStream/x86_64/os"
  local prim; prim="$(curl -fsSL "${base}/repodata/repomd.xml" \
    | grep -oE 'repodata/[a-f0-9]*-primary\.xml\.(gz|zst)' | head -1)"
  [[ -n "$prim" ]] || return 1
  curl -fsSL "${base}/${prim}" -o "/tmp/cs-prim-${el}"
  case "$prim" in
    *.zst) zstd -dc "/tmp/cs-prim-${el}" ;;
    *)     gzip -dc "/tmp/cs-prim-${el}" ;;
  esac > "/tmp/cs-prim-${el}.xml"
  local path
  path="$(grep -oE "Packages/container-selinux-[0-9][^\"]*\.el${el}\.noarch\.rpm" \
          "/tmp/cs-prim-${el}.xml" | sort -V | tail -1)"
  [[ -n "$path" ]] || return 1
  echo "    container-selinux el${el}: $(basename "$path")"
  curl -fL --retry 3 -o "${ASSETS_DIR}/$(basename "$path")" "${base}/${path}"
}
for el in 9 10; do
  resolve_container_selinux "$el" \
    || echo "    !! could not resolve container-selinux el${el} (bundle manually)" >&2
done
( cd "$ASSETS_DIR" && sha256sum ./*selinux*.el*.noarch.rpm > selinux-rpms.sha256 2>/dev/null || true )

echo
echo "[+] assets/ populated. Commit it, move the repo to the air-gapped node,"
echo "    then run: sudo ./install-rke2-offline.sh --type server"
echo "    Optional private registry: sudo ./install-registry-offline.sh"
