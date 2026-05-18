#!/usr/bin/env bash
#
# deploy-ha-offline.sh
#
# Install the HIGH-AVAILABILITY infrastructure on an air-gapped RKE2 cluster
# using ONLY the artifacts bundled by scripts/fetch-ha-assets.sh:
#
#   * Longhorn        — multi-node replicated block storage (a "longhorn"
#                        StorageClass that survives a node failure)
#   * CloudNativePG    — operator for HA PostgreSQL with automatic failover
#
# It loads the bundled images, pushes them to your private registry, rewrites
# the upstream manifests to pull from that registry, and applies them. No
# network access is used on the cluster.
#
# Afterwards, deploy the app in HA mode:
#   sudo ./deploy-app-offline.sh --registry <host:port> \
#        --deploy-only --helm assets/app/helm -- \
#        --set postgres.ha.enabled=true
#   (or pass the HA flags via your own helm invocation — see docs/ha-setup.md)
#
# Prerequisites:
#   * RKE2 running, ideally >=3 server nodes (etcd quorum) + worker nodes
#   * Private registry up and THIS host trusts its CA / can resolve it
#   * podman (or docker) for the image push; kubectl reachable
#   * Longhorn node prereqs installed on EVERY node: open-iscsi (iscsi_tcp
#     module loaded) and a filesystem at /var/lib/longhorn. In a strict
#     air-gap these RPMs must already be present.
#
# Usage:
#   sudo ./deploy-ha-offline.sh --registry <host:port> [options]
#
# Options:
#   --registry <host:port>  Private registry (required for push).
#   --kubeconfig <path>     (default: /etc/rancher/rke2/rke2.yaml)
#   --skip-longhorn         Do not install Longhorn.
#   --skip-cnpg             Do not install the CloudNativePG operator.
#   --set-default-sc        Mark the longhorn StorageClass cluster-default.
#   --uninstall             Best-effort remove CNPG; print Longhorn removal.
#   -h | --help             Show this help.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
HA_DIR="${SCRIPT_DIR}/assets/ha"

REGISTRY=""
KUBECONFIG_PATH="/etc/rancher/rke2/rke2.yaml"
SKIP_LONGHORN=0
SKIP_CNPG=0
SET_DEFAULT_SC=0
DO_UNINSTALL=0

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
usage() { sed -n '2,41p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)       REGISTRY="${2:?}"; shift 2 ;;
    --kubeconfig)     KUBECONFIG_PATH="${2:?}"; shift 2 ;;
    --skip-longhorn)  SKIP_LONGHORN=1; shift ;;
    --skip-cnpg)      SKIP_CNPG=1; shift ;;
    --set-default-sc) SET_DEFAULT_SC=1; shift ;;
    --uninstall)      DO_UNINSTALL=1; shift ;;
    -h|--help)        usage 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."

# kubectl: RKE2 ships one under its data dir; fall back to PATH.
KUBECTL=""
for k in /var/lib/rancher/rke2/bin/kubectl "$(command -v kubectl 2>/dev/null || true)"; do
  [[ -n "$k" && -x "$k" ]] && { KUBECTL="$k"; break; }
done
[[ -n "$KUBECTL" ]] || die "kubectl not found (looked in RKE2 data dir and PATH)."
kc() { KUBECONFIG="$KUBECONFIG_PATH" "$KUBECTL" "$@"; }

# --------------------------------------------------------------------------- #
# Uninstall
# --------------------------------------------------------------------------- #
if [[ $DO_UNINSTALL -eq 1 ]]; then
  [[ -s "${HA_DIR}/cnpg-operator.yaml" ]] && {
    log "Deleting CloudNativePG operator"
    kc delete -f "${HA_DIR}/cnpg-operator.yaml" --ignore-not-found || true
  }
  warn "Longhorn will NOT delete while volumes/PVCs exist. To remove it:"
  warn "  kc -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \\"
  warn "     --type=merge -p '{\"value\":\"true\"}'"
  warn "  kc delete -f ${HA_DIR}/longhorn.yaml"
  log "Done (CNPG removed; follow the steps above for Longhorn)."
  exit 0
fi

[[ -n "$REGISTRY" ]] || die "--registry <host:port> is required."
ENGINE=""
if command -v podman >/dev/null 2>&1; then ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then ENGINE="docker"; fi
[[ -n "$ENGINE" ]] || die "podman (or docker) is required to push images."

# --------------------------------------------------------------------------- #
# Reassemble + verify a split multi-image archive: <base>.tar.part* -> .tar
# --------------------------------------------------------------------------- #
reassemble() {
  local base="$1" tar="${HA_DIR}/$1.tar"
  local parts=( "${tar}.part"* )
  [[ -e "${parts[0]}" ]] || die "Missing ${base} parts in ${HA_DIR}.
Run scripts/fetch-ha-assets.sh on a connected host first."
  local want; want="$(awk '{print $1}' "${HA_DIR}/${base}.sha256" 2>/dev/null || true)"
  if [[ -s "$tar" && -n "$want" \
        && "$(sha256sum "$tar" | awk '{print $1}')" == "$want" ]]; then
    log "${base}.tar already assembled and verified."; return 0
  fi
  if [[ -s "${HA_DIR}/${base}.parts.sha256" ]]; then
    log "Verifying ${#parts[@]} part(s) for ${base}"
    ( cd "$HA_DIR" && sha256sum -c --quiet "${base}.parts.sha256" ) \
      || die "${base} part verification failed — re-fetch assets/ha."
  fi
  log "Reassembling ${base}.tar from ${#parts[@]} part(s)"
  cat "${tar}.part"* > "$tar"
  [[ -z "$want" || "$(sha256sum "$tar" | awk '{print $1}')" == "$want" ]] \
    || die "${base}.tar checksum mismatch after reassembly."
}

# docker.io/foo, ghcr.io/foo, longhornio/bar -> path without a registry domain
strip_domain() {
  local ref="$1" first="${1%%/*}"
  if [[ "$ref" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == "localhost" ) ]]; then
    printf '%s\n' "${ref#*/}"
  else
    printf '%s\n' "$ref"
  fi
}

# Load a multi-image archive and push every listed image into the registry,
# preserving the path (minus any source registry domain).
load_and_push() {
  local base="$1"
  reassemble "$base"
  log "Loading ${base} images ($ENGINE)"
  "$ENGINE" load -i "${HA_DIR}/${base}.tar" >/dev/null
  local ref dest
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    dest="${REGISTRY}/$(strip_domain "$ref")"
    "$ENGINE" tag "$ref" "$dest"
    "$ENGINE" push "$dest" >/dev/null \
      && log "  pushed ${dest}" \
      || die "push failed for ${dest} — does this host trust the registry CA?"
  done < "${HA_DIR}/${base}.images"
}

# Rewrite an upstream manifest's image registry prefixes to the private one.
rewrite_manifest() {
  local src="$1" out="$2"; shift 2
  cp "$src" "$out"
  local pfx
  for pfx in "$@"; do
    sed -i "s#\([\"' ]\)${pfx}#\1${REGISTRY}/${pfx}#g; s#^${pfx}#${REGISTRY}/${pfx}#g; s#image: ${pfx}#image: ${REGISTRY}/${pfx}#g" "$out"
  done
}

# --------------------------------------------------------------------------- #
# Longhorn node pre-flight (warn only — can't dnf in an air-gap)
# --------------------------------------------------------------------------- #
if [[ $SKIP_LONGHORN -eq 0 ]]; then
  command -v iscsiadm >/dev/null 2>&1 \
    || warn "iscsiadm not found — Longhorn needs open-iscsi on EVERY node."
  lsmod 2>/dev/null | grep -q iscsi_tcp \
    || warn "kernel module iscsi_tcp not loaded — run 'modprobe iscsi_tcp' on all nodes."
fi

# --------------------------------------------------------------------------- #
# Longhorn
# --------------------------------------------------------------------------- #
if [[ $SKIP_LONGHORN -eq 0 ]]; then
  { [[ -s "${HA_DIR}/longhorn.yaml" && -s "${HA_DIR}/longhorn-images.images" ]]; } \
    || die "Longhorn assets missing in ${HA_DIR} (run fetch-ha-assets.sh)."
  load_and_push "longhorn-images"
  LH_OUT="$(mktemp)"
  rewrite_manifest "${HA_DIR}/longhorn.yaml" "$LH_OUT" "longhornio/"
  log "Applying Longhorn manifest"
  kc apply -f "$LH_OUT"
  rm -f "$LH_OUT"
  log "Waiting for Longhorn manager to roll out (up to 10 min)..."
  kc -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s \
    || warn "longhorn-manager not ready yet — check: kc -n longhorn-system get pods"
  if [[ $SET_DEFAULT_SC -eq 1 ]]; then
    log "Marking 'longhorn' the default StorageClass"
    kc annotate storageclass longhorn \
      storageclass.kubernetes.io/is-default-class=true --overwrite || true
  fi
fi

# --------------------------------------------------------------------------- #
# CloudNativePG operator
# --------------------------------------------------------------------------- #
if [[ $SKIP_CNPG -eq 0 ]]; then
  [[ -s "${HA_DIR}/cnpg-operator.yaml" ]] \
    || die "cnpg-operator.yaml missing in ${HA_DIR} (run fetch-ha-assets.sh)."
  load_and_push "cnpg-images"
  CNPG_OUT="$(mktemp)"
  rewrite_manifest "${HA_DIR}/cnpg-operator.yaml" "$CNPG_OUT" "ghcr.io/cloudnative-pg/"
  log "Applying CloudNativePG operator manifest"
  kc apply --server-side -f "$CNPG_OUT"
  rm -f "$CNPG_OUT"
  log "Waiting for the CNPG operator to roll out..."
  kc -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s \
    || warn "CNPG operator not ready yet — check: kc -n cnpg-system get pods"
fi

echo
log "HA infrastructure installed."
log "Now deploy the app in HA mode, e.g.:"
log "  KUBECONFIG=${KUBECONFIG_PATH} ${SCRIPT_DIR}/assets/app/helm \\"
log "    upgrade --install hello-db ${SCRIPT_DIR}/charts/hello-db -n hello-db \\"
log "    --create-namespace --set image.registry=${REGISTRY} \\"
log "    --set postgres.ha.enabled=true --set app.replicas=3 --set app.pdb.enabled=true"
log "See docs/ha-setup.md for the full walkthrough."
log "Done."
