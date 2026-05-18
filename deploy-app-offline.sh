#!/usr/bin/env bash
#
# deploy-app-offline.sh
#
# Deploy the offline "hello-db" demo (Flask + PostgreSQL) onto an air-gapped
# RKE2 cluster, using ONLY the artifacts bundled in ./assets/app and the Helm
# chart in ./charts/hello-db. No network access is used.
#
# What it does:
#   1. Reassembles & verifies the bundled app + postgres image tarballs.
#   2. Loads them and pushes them into your private registry
#      (the one from install-registry-offline.sh).
#   3. Runs the bundled Helm CLI to install the chart, pointed at that
#      registry.
#
# Prerequisites:
#   * RKE2 running          (install-rke2-offline.sh)
#   * Private registry up   (install-registry-offline.sh) and THIS host
#     trusts its CA + can resolve it (install-registry-offline.sh --client-only)
#   * podman (for the push step)
#
# Usage:
#   sudo ./deploy-app-offline.sh --registry <host:port> [options]
#
# Examples:
#   # All-in-one (push images, then helm install):
#   sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000
#
#   # Just push images (run on a host that can reach the registry):
#   sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000 --push-only
#
#   # Just install the chart (images already in the registry):
#   sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000 --deploy-only
#
# Options:
#   --registry <host:port>  Private registry to push to / pull from. Required
#                           unless --deploy-only with a values override.
#   --namespace <ns>        Kubernetes namespace.        (default: hello-db)
#   --release <name>        Helm release name.           (default: hello-db)
#   --node-port <port>      NodePort for the web app.    (default: 30080)
#   --kubeconfig <path>     (default: /etc/rancher/rke2/rke2.yaml)
#   --helm <path>           Helm binary. (default: bundled ./assets/app/helm)
#   --push-only             Load & push images; do not run Helm.
#   --deploy-only           Run Helm only; skip image push.
#   --uninstall             helm uninstall the release and exit.
#   -h | --help             Show this help.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
APP_ASSETS="${SCRIPT_DIR}/assets/app"
CHART_DIR="${SCRIPT_DIR}/charts/hello-db"

REGISTRY=""
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
usage() { sed -n '2,47p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)   REGISTRY="${2:?}"; shift 2 ;;
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

# --------------------------------------------------------------------------- #
# Push phase
# --------------------------------------------------------------------------- #
if [[ $DEPLOY_ONLY -eq 0 ]]; then
  [[ -n "$REGISTRY" ]] || die "--registry <host:port> is required to push images."
  [[ -n "$ENGINE" ]] || die "podman (or docker) is required for the push step.
Use --deploy-only on the cluster node if you pushed images elsewhere."
  push_image "hello-db-app" "${REGISTRY}/hello-db-app:${APP_TAG}"
  push_image "postgres"     "${REGISTRY}/postgres:${PG_TAG}"
  log "Images pushed to ${REGISTRY}."
  if [[ $PUSH_ONLY -eq 1 ]]; then log "Push-only: done."; exit 0; fi
fi

# --------------------------------------------------------------------------- #
# Deploy phase (Helm)
# --------------------------------------------------------------------------- #
[[ -n "$REGISTRY" ]] || die "--registry <host:port> is required (chart image source)."
[[ -d "$CHART_DIR" ]] || die "Chart not found at ${CHART_DIR}"
[[ -s "$KUBECONFIG_PATH" ]] || die "kubeconfig not found: ${KUBECONFIG_PATH}
Is RKE2 installed/running on this node? Pass --kubeconfig if it lives elsewhere."
resolve_helm

log "Installing chart '${RELEASE}' into namespace '${NAMESPACE}' (Helm)"
KUBECONFIG="$KUBECONFIG_PATH" "$HELM_BIN" upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  --set image.registry="$REGISTRY" \
  --set image.app.tag="$APP_TAG" \
  --set image.postgres.tag="$PG_TAG" \
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
