#!/usr/bin/env bash
#
# build-app-assets.sh — run this ONCE on an internet-CONNECTED host to build &
# bundle everything the hello-db app needs to run on the air-gapped cluster:
#
#   * the Flask app image  (built from ./app)
#   * the PostgreSQL image (pulled)
#   * the Helm CLI binary
#
# Images are saved as docker-archive tarballs and split into <90 MB parts so
# the repo needs no Git LFS (same scheme as the RKE2 image bundle). The
# air-gapped deploy script reassembles, verifies and pushes them.
#
#   ./scripts/build-app-assets.sh
#
# Env overrides:
#   APP_TAG         (default 1.0.0)
#   POSTGRES_IMAGE  (default docker.io/library/postgres:16-alpine)
#   HELM_VERSION    (default v3.16.2)
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
APP_DIR="${SCRIPT_DIR}/app"
OUT_DIR="${SCRIPT_DIR}/assets/app"
mkdir -p "$OUT_DIR"

APP_TAG="${APP_TAG:-1.0.0}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-docker.io/library/postgres:16-alpine}"
HELM_VERSION="${HELM_VERSION:-v3.16.2}"
PART_SIZE="${PART_SIZE:-90M}"
APP_IMAGE="localhost/hello-db-app:${APP_TAG}"

ENGINE=""
if command -v podman >/dev/null 2>&1; then ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then ENGINE="docker"
else echo "[x] need podman or docker to build/pull images" >&2; exit 1; fi
echo "[+] Using container engine: ${ENGINE}"

# --------------------------------------------------------------------------- #
# Save an image to <name>.tar then split into <name>.tar.partNN (+ checksums).
# Always splits (even to one part) so the offline path is uniform.
# --------------------------------------------------------------------------- #
save_split() {
  local image="$1" base="$2" tar="${OUT_DIR}/$2.tar"
  echo "[+] Saving ${image} -> $(basename "$tar")"
  if [[ "$ENGINE" == "podman" ]]; then
    podman save --format docker-archive -o "$tar" "$image"
  else
    docker save "$image" -o "$tar"
  fi
  printf '%s\n' "$image" > "${OUT_DIR}/${base}.ref"
  ( cd "$OUT_DIR" && sha256sum "${base}.tar" > "${base}.sha256" )
  echo "[+] Splitting ${base}.tar into ${PART_SIZE} parts"
  rm -f "${tar}.part"*
  split -b "$PART_SIZE" -d -a 2 "$tar" "${tar}.part"
  ( cd "$OUT_DIR" && sha256sum "${base}.tar.part"* > "${base}.parts.sha256" )
  rm -f "$tar"
  echo "    $(ls "${tar}.part"* | wc -l) part(s) written; ${base}.tar removed"
}

# --------------------------------------------------------------------------- #
# 1. Build the Flask app image
# --------------------------------------------------------------------------- #
echo "[+] Building app image ${APP_IMAGE} from ${APP_DIR}"
# -f is explicit: Docker (unlike podman) does not auto-detect "Containerfile".
"$ENGINE" build -f "${APP_DIR}/Containerfile" -t "$APP_IMAGE" "$APP_DIR"
save_split "$APP_IMAGE" "hello-db-app"

# --------------------------------------------------------------------------- #
# 2. Pull & bundle PostgreSQL
# --------------------------------------------------------------------------- #
echo "[+] Pulling ${POSTGRES_IMAGE}"
"$ENGINE" pull "$POSTGRES_IMAGE"
save_split "$POSTGRES_IMAGE" "postgres"

# --------------------------------------------------------------------------- #
# 3. Helm CLI binary
# --------------------------------------------------------------------------- #
echo "[+] Downloading Helm ${HELM_VERSION}"
tmp="$(mktemp -d)"
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  -o "${tmp}/helm.tgz"
tar -xzf "${tmp}/helm.tgz" -C "$tmp"
install -m 0755 "${tmp}/linux-amd64/helm" "${OUT_DIR}/helm"
rm -rf "$tmp"
printf '%s\n' "$HELM_VERSION" > "${OUT_DIR}/helm.version"
( cd "$OUT_DIR" && sha256sum helm > helm.sha256 )
echo "    helm $("${OUT_DIR}/helm" version --short 2>/dev/null || echo "$HELM_VERSION") bundled"

echo
echo "[+] assets/app/ populated:"
ls -1 "$OUT_DIR"
echo
echo "[+] Commit assets/app + the chart, move the repo to the air-gapped"
echo "    cluster, then run:  sudo ./deploy-app-offline.sh --registry <host:port>"
