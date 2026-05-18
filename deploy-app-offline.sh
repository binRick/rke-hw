#!/usr/bin/env bash
#
# deploy-app-offline.sh
#
# Deploy the offline "hello-db" demo (Flask + PostgreSQL) onto an air-gapped
# RKE2 cluster, using ONLY the artifacts committed in ./assets/app and the
# Helm chart in ./charts/hello-db. No network access is used.
#
# TWO MODES:
#
#  A) --no-registry  (SIMPLEST — recommended for a single RHEL9 box)
#     Imports the app + Postgres images straight into RKE2's containerd,
#     then helm-installs with imagePullPolicy=Never. NO private registry,
#     NO internet, nothing else to set up. Single-node by design (the
#     import is per-node; see the note below for multi-node).
#
#  B) --registry <host:port>  (multi-node)
#     Loads & pushes the images into your private registry
#     (install-registry-offline.sh), then helm-installs pulling from it.
#
# Prerequisites:
#   * RKE2 running (install-rke2-offline.sh)
#   * Mode A: nothing else (uses RKE2's bundled ctr + the bundled helm)
#   * Mode B: private registry up + this host trusts its CA; podman/docker
#
# Usage:
#   sudo ./deploy-app-offline.sh --no-registry
#   sudo ./deploy-app-offline.sh --registry <host:port> [options]
#
# Examples:
#   # Zero-internet, zero-registry, one command (single node):
#   sudo ./deploy-app-offline.sh --no-registry
#
#   # Registry mode, all-in-one (push then helm install):
#   sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000
#
#   # Registry mode, split roles:
#   sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000 --push-only
#   sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000 --deploy-only
#
# Options:
#   --no-registry           Import images into containerd; no registry.
#   --registry <host:port>  Private registry to push to / pull from.
#   --ctr <path>            RKE2 ctr binary.
#                           (default: /var/lib/rancher/rke2/bin/ctr)
#   --containerd-address <s> (default: /run/k3s/containerd/containerd.sock)
#   --namespace <ns>        Kubernetes namespace.        (default: hello-db)
#   --release <name>        Helm release name.           (default: hello-db)
#   --node-port <port>      NodePort for the web app.    (default: 30080)
#   --kubeconfig <path>     (default: /etc/rancher/rke2/rke2.yaml)
#   --helm <path>           Helm binary. (default: bundled ./assets/app/helm)
#   --push-only             (registry mode) Load & push images; no Helm.
#   --deploy-only           (registry mode) Run Helm only; skip image push.
#   --uninstall             helm uninstall the release and exit.
#   -h | --help             Show this help.
#
# Multi-node + --no-registry: run this script's import on EVERY node, or use
# --registry instead (recommended for real multi-node clusters).
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
APP_ASSETS="${SCRIPT_DIR}/assets/app"
CHART_DIR="${SCRIPT_DIR}/charts/hello-db"

REGISTRY=""
NO_REGISTRY=0
CTR_BIN="/var/lib/rancher/rke2/bin/ctr"
CONTAINERD_ADDR="/run/k3s/containerd/containerd.sock"
NAMESPACE="hello-db"
RELEASE="hello-db"
NODE_PORT="30080"
KUBECONFIG_PATH="/etc/rancher/rke2/rke2.yaml"
HELM_BIN="${APP_ASSETS}/helm"
PUSH_ONLY=0
DEPLOY_ONLY=0
DO_UNINSTALL=0

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
usage() { sed -n '2,59p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)   REGISTRY="${2:?}"; shift 2 ;;
    --no-registry) NO_REGISTRY=1; shift ;;
    --ctr)        CTR_BIN="${2:?}"; shift 2 ;;
    --containerd-address) CONTAINERD_ADDR="${2:?}"; shift 2 ;;
    --namespace)  NAMESPACE="${2:?}"; shift 2 ;;
    --release)    RELEASE="${2:?}"; shift 2 ;;
    --node-port)  NODE_PORT="${2:?}"; shift 2 ;;
    --kubeconfig) KUBECONFIG_PATH="${2:?}"; shift 2 ;;
    --helm)       HELM_BIN="${2:?}"; shift 2 ;;
    --push-only)  PUSH_ONLY=1; shift ;;
    --deploy-only) DEPLOY_ONLY=1; shift ;;
    --uninstall)  DO_UNINSTALL=1; shift ;;
    -h|--help)    usage 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."

resolve_helm() {
  [[ -x "$HELM_BIN" ]] && return 0
  command -v helm >/dev/null 2>&1 && { HELM_BIN="$(command -v helm)"; return 0; }
  die "Helm not found. Expected bundled ${APP_ASSETS}/helm
(run scripts/build-app-assets.sh on a connected host) or pass --helm <path>."
}

# --------------------------------------------------------------------------- #
# Uninstall
# --------------------------------------------------------------------------- #
if [[ $DO_UNINSTALL -eq 1 ]]; then
  resolve_helm
  log "Uninstalling release '${RELEASE}' from namespace '${NAMESPACE}'"
  KUBECONFIG="$KUBECONFIG_PATH" "$HELM_BIN" uninstall "$RELEASE" -n "$NAMESPACE" \
    || warn "helm uninstall reported an error (release may already be gone)."
  log "Done. (Namespace '${NAMESPACE}' left in place; delete it manually if unused.)"
  exit 0
fi

# --------------------------------------------------------------------------- #
# Reassemble + verify a split image tarball:  <base>.tar.part* -> <base>.tar
# --------------------------------------------------------------------------- #
reassemble() {
  local base="$1" tar="${APP_ASSETS}/$1.tar"
  local parts=( "${tar}.part"* )
  [[ -e "${parts[0]}" ]] || die "Missing image parts for ${base} in ${APP_ASSETS}
Run scripts/build-app-assets.sh on a connected host first."
  local want; want="$(awk '{print $1}' "${APP_ASSETS}/${base}.sha256" 2>/dev/null || true)"

  if [[ -s "$tar" && -n "$want" \
        && "$(sha256sum "$tar" | awk '{print $1}')" == "$want" ]]; then
    log "${base}.tar already assembled and verified."
    return 0
  fi
  if [[ -s "${APP_ASSETS}/${base}.parts.sha256" ]]; then
    log "Verifying ${#parts[@]} part(s) for ${base}"
    ( cd "$APP_ASSETS" && sha256sum -c --quiet "${base}.parts.sha256" ) \
      || die "${base} part verification failed — re-fetch assets/app."
  fi
  log "Reassembling ${base}.tar from ${#parts[@]} part(s)"
  cat "${tar}.part"* > "$tar"
  if [[ -n "$want" ]]; then
    [[ "$(sha256sum "$tar" | awk '{print $1}')" == "$want" ]] \
      || die "${base}.tar checksum mismatch after reassembly."
  fi
}

ENGINE=""
if command -v podman >/dev/null 2>&1; then ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then ENGINE="docker"; fi

# Tags come from the bundled .ref files (fall back to chart defaults).
ref_tag() { sed -n '1p' "${APP_ASSETS}/$1.ref" 2>/dev/null | sed 's/.*://'; }
APP_TAG="$(ref_tag hello-db-app)"; APP_TAG="${APP_TAG:-1.0.0}"
PG_TAG="$(ref_tag postgres)";       PG_TAG="${PG_TAG:-16-alpine}"

push_image() {
  local base="$1" dest="$2"
  reassemble "$base"
  log "Loading ${base} image ($ENGINE)"
  local loaded
  loaded="$("$ENGINE" load -i "${APP_ASSETS}/${base}.tar" 2>/dev/null \
            | sed -n 's/^Loaded image: *//p; s/^Loaded image(s): *//p' | head -1)"
  [[ -n "$loaded" ]] || loaded="$(cat "${APP_ASSETS}/${base}.ref")"
  "$ENGINE" tag "$loaded" "$dest"
  log "Pushing ${dest}"
  "$ENGINE" push "$dest" \
    || die "Push failed. Does this host trust the registry CA and resolve
'${REGISTRY%%:*}'?  Run: sudo ./install-registry-offline.sh --client-only
--host ${REGISTRY%%:*} --ca <registry-ca.crt>"
}

# Import a bundled image tarball straight into RKE2's containerd (k8s.io
# namespace) so kubelet can run it with imagePullPolicy=Never — no registry.
import_image() {
  local base="$1"
  reassemble "$base"
  log "Importing ${base} into containerd (k8s.io)"
  "$CTR_BIN" --address "$CONTAINERD_ADDR" -n k8s.io images import \
    "${APP_ASSETS}/${base}.tar" \
    || die "containerd import failed for ${base}.
Is RKE2 running on this node? Check ${CTR_BIN} and ${CONTAINERD_ADDR}
(override with --ctr / --containerd-address)."
}

# Mode validation: exactly one of --no-registry / --registry.
if [[ $NO_REGISTRY -eq 1 && -n "$REGISTRY" ]]; then
  die "Use either --no-registry OR --registry, not both."
elif [[ $NO_REGISTRY -eq 0 && -z "$REGISTRY" ]]; then
  die "Choose a mode: --no-registry (simplest, single node) or --registry <host:port>."
fi

# repo name without tag and without an implicit docker.io[/library] prefix
local_repo() { local r="${1%:*}"; r="${r#docker.io/}"; r="${r#library/}"; printf '%s\n' "$r"; }

# --------------------------------------------------------------------------- #
# Image acquisition phase
# --------------------------------------------------------------------------- #
if [[ $DEPLOY_ONLY -eq 0 ]]; then
  if [[ $NO_REGISTRY -eq 1 ]]; then
    [[ -x "$CTR_BIN" ]] || die "RKE2 ctr not found at ${CTR_BIN} (pass --ctr).
--no-registry must run ON an RKE2 node."
    import_image "hello-db-app"
    import_image "postgres"
    log "Images imported into this node's containerd."
  else
    [[ -n "$ENGINE" ]] || die "podman (or docker) is required for the push step.
Use --deploy-only on the cluster node if you pushed images elsewhere."
    push_image "hello-db-app" "${REGISTRY}/hello-db-app:${APP_TAG}"
    push_image "postgres"     "${REGISTRY}/postgres:${PG_TAG}"
    log "Images pushed to ${REGISTRY}."
  fi
  if [[ $PUSH_ONLY -eq 1 ]]; then log "--push-only: done."; exit 0; fi
fi

# --------------------------------------------------------------------------- #
# Deploy phase (Helm)
# --------------------------------------------------------------------------- #
[[ -d "$CHART_DIR" ]] || die "Chart not found at ${CHART_DIR}"
[[ -s "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: ${KUBECONFIG_PATH}
Is RKE2 installed/running on this node? Pass --kubeconfig if it lives elsewhere."
resolve_helm

IMG_ARGS=()
if [[ $NO_REGISTRY -eq 1 ]]; then
  # Local containerd images, no registry prefix, never pull.
  IMG_ARGS=(
    --set image.registry=""
    --set "image.app.repository=$(local_repo "$(cat "${APP_ASSETS}/hello-db-app.ref")")"
    --set image.app.tag="$APP_TAG"
    --set "image.postgres.repository=$(local_repo "$(cat "${APP_ASSETS}/postgres.ref")")"
    --set image.postgres.tag="$PG_TAG"
    --set image.pullPolicy=Never
  )
else
  IMG_ARGS=(
    --set image.registry="$REGISTRY"
    --set image.app.tag="$APP_TAG"
    --set image.postgres.tag="$PG_TAG"
  )
fi

log "Installing chart '${RELEASE}' into namespace '${NAMESPACE}' (Helm)"
KUBECONFIG="$KUBECONFIG_PATH" "$HELM_BIN" upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  "${IMG_ARGS[@]}" \
  --set app.service.nodePort="$NODE_PORT" \
  --wait --timeout 5m \
  || die "helm install failed. Inspect: KUBECONFIG=${KUBECONFIG_PATH} \
${HELM_BIN} status ${RELEASE} -n ${NAMESPACE}; kubectl -n ${NAMESPACE} get pods"

echo
log "Deployed. Check it:"
log "  KUBECONFIG=${KUBECONFIG_PATH} kubectl -n ${NAMESPACE} get pods"
NODE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "Open the app:  http://${NODE_IP:-<node-ip>}:${NODE_PORT}/"
log "Done."
