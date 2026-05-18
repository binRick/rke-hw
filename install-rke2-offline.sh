#!/usr/bin/env bash
#
# install-rke2-offline.sh
#
# Fully offline (air-gapped) RKE2 Kubernetes installer.
# Uses ONLY the artifacts bundled in this repository's ./assets directory.
# No network access is required or attempted on the target node.
#
# Target platform: RHEL / Rocky / Alma / CentOS Stream 9 and 10, x86_64 (amd64).
#                  (The bundled RKE2 tarball is EL-version independent; only
#                   the optional SELinux policy RPMs are version-specific.)
# Method: official RKE2 "tarball" air-gap install
#         (https://docs.rke2.io/install/airgap).
#
# Usage:
#   sudo ./install-rke2-offline.sh [options]
#
# Common scenarios
#   First / only server (control-plane) node:
#     sudo ./install-rke2-offline.sh --type server --tls-san k8s.example.com
#
#   Additional HA server node (joins existing cluster):
#     sudo ./install-rke2-offline.sh --type server \
#          --server https://<first-server-ip>:9345 --token <node-token>
#
#   Worker / agent node:
#     sudo ./install-rke2-offline.sh --type agent \
#          --server https://<server-ip>:9345 --token <node-token>
#
# Options:
#   --type <server|agent>   Node role.                      (default: server)
#   --server <url>          https://<ip>:9345 of an existing server.
#                           Required for agents and HA server joins.
#   --token <token>         Cluster join token. Required when --server is set.
#   --tls-san <name>        Extra SAN (DNS/IP) for the API cert. Repeatable.
#   --node-ip <ip>          IP this node advertises. Repeatable for dual-stack.
#   --config <file>         Use this file verbatim as the RKE2 config.yaml
#                           (overrides generated config & repo default).
#   --data-dir <path>       RKE2 data dir. (default: /var/lib/rancher/rke2)
#   --selinux-permissive    If SELinux is Enforcing and no policy package is
#                           bundled, set it Permissive instead of aborting.
#   --disable-firewalld     Stop & disable firewalld (recommended for RKE2).
#   --no-start              Install binaries/images only; do not start RKE2.
#   --uninstall             Run the RKE2 uninstall script and exit.
#   -h | --help             Show this help.
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Resolve paths
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ASSETS_DIR="${SCRIPT_DIR}/assets"
CONFIG_DIR="${SCRIPT_DIR}/config"

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
NODE_TYPE="server"
JOIN_SERVER=""
JOIN_TOKEN=""
TLS_SANS=()
NODE_IPS=()
CUSTOM_CONFIG=""
DATA_DIR="/var/lib/rancher/rke2"
SELINUX_PERMISSIVE=0
DISABLE_FIREWALLD=0
NO_START=0
DO_UNINSTALL=0

# --------------------------------------------------------------------------- #
# Logging helpers
# --------------------------------------------------------------------------- #
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,60p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//'; exit "${1:-0}"; }

# --------------------------------------------------------------------------- #
# Parse arguments
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)               NODE_TYPE="${2:?}"; shift 2 ;;
    --server)             JOIN_SERVER="${2:?}"; shift 2 ;;
    --token)              JOIN_TOKEN="${2:?}"; shift 2 ;;
    --tls-san)            TLS_SANS+=("${2:?}"); shift 2 ;;
    --node-ip)            NODE_IPS+=("${2:?}"); shift 2 ;;
    --config)             CUSTOM_CONFIG="${2:?}"; shift 2 ;;
    --data-dir)           DATA_DIR="${2:?}"; shift 2 ;;
    --selinux-permissive) SELINUX_PERMISSIVE=1; shift ;;
    --disable-firewalld)  DISABLE_FIREWALLD=1; shift ;;
    --no-start)           NO_START=1; shift ;;
    --uninstall)          DO_UNINSTALL=1; shift ;;
    -h|--help)            usage 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

case "$NODE_TYPE" in
  server|agent) ;;
  *) die "--type must be 'server' or 'agent' (got '$NODE_TYPE')" ;;
esac

# --------------------------------------------------------------------------- #
# Uninstall path
# --------------------------------------------------------------------------- #
if [[ $DO_UNINSTALL -eq 1 ]]; then
  [[ $EUID -eq 0 ]] || die "Uninstall must run as root."
  for u in /usr/local/bin/rke2-uninstall.sh /usr/bin/rke2-uninstall.sh; do
    if [[ -x "$u" ]]; then
      log "Running $u"; "$u"; log "RKE2 uninstalled."; exit 0
    fi
  done
  die "rke2-uninstall.sh not found; RKE2 does not appear to be installed."
fi

# --------------------------------------------------------------------------- #
# Pre-flight checks
# --------------------------------------------------------------------------- #
log "Pre-flight checks"

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] || die "Unsupported arch '$ARCH'; bundled assets are amd64 only."

# Detect the Enterprise Linux major version (used for SELinux RPM selection).
EL_MAJOR=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  EL_MAJOR="${VERSION_ID%%.*}"
  OS_PRETTY="${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-?}}"
else
  OS_PRETTY="unknown (no /etc/os-release)"
fi
log "Detected OS: ${OS_PRETTY}"

case "$EL_MAJOR" in
  9|10) log "Enterprise Linux ${EL_MAJOR} — supported." ;;
  *)    warn "EL major version '${EL_MAJOR:-?}' is untested (supported: 9, 10).
The RKE2 tarball is EL-version independent, so the install will proceed." ;;
esac

if [[ -n "$JOIN_SERVER" && -z "$JOIN_TOKEN" ]]; then
  die "--server given without --token; a join token is required."
fi
if [[ "$NODE_TYPE" == "agent" && -z "$JOIN_SERVER" ]]; then
  die "Agent nodes require --server <url> and --token <token>."
fi

# Required bundled artifacts
INSTALL_SH="${ASSETS_DIR}/install.sh"
BIN_TARBALL="${ASSETS_DIR}/rke2.linux-amd64.tar.gz"
IMG_TARBALL="${ASSETS_DIR}/rke2-images.linux-amd64.tar.zst"
IMG_PARTS_PREFIX="${IMG_TARBALL}.part"
IMG_PARTS_MANIFEST="${ASSETS_DIR}/rke2-images.parts.sha256"
SHASUMS="${ASSETS_DIR}/sha256sum-amd64.txt"
VERSION_FILE="${ASSETS_DIR}/VERSION"

# The ~812 MB images tarball is committed split into <100 MB parts so the repo
# needs no Git LFS. Reassemble it here (fully offline) before anything uses it.
expected_sum() {  # echo expected sha256 for a basename from the official manifest
  awk -v n="$1" '$2 ~ ("(^|/)" n "$") {print $1; exit}' "$SHASUMS" 2>/dev/null || true
}

assemble_images_tarball() {
  local parts=( "${IMG_PARTS_PREFIX}"* )
  [[ -e "${parts[0]}" ]] || return 0   # not split — nothing to assemble
  local want; want="$(expected_sum "$(basename "$IMG_TARBALL")")"

  # Already assembled and intact? Skip the ~812 MB rebuild.
  if [[ -s "$IMG_TARBALL" && -n "$want" \
        && "$(sha256sum "$IMG_TARBALL" | awk '{print $1}')" == "$want" ]]; then
    log "Images tarball already assembled and verified."
    return 0
  fi

  # Verify every part before concatenation (catches truncated copies or
  # un-smudged Git LFS pointer stubs early, with a clear message).
  if [[ -s "$IMG_PARTS_MANIFEST" ]]; then
    log "Verifying ${#parts[@]} image parts"
    ( cd "$ASSETS_DIR" && sha256sum -c --quiet "$(basename "$IMG_PARTS_MANIFEST")" ) \
      || die "Image part verification failed — parts are corrupt, incomplete,
or are Git LFS pointer stubs. Re-fetch ./assets on a connected host."
  fi

  log "Reassembling images tarball from ${#parts[@]} parts (~812 MB)"
  cat "${IMG_PARTS_PREFIX}"* > "$IMG_TARBALL"

  if [[ -n "$want" ]]; then
    local got; got="$(sha256sum "$IMG_TARBALL" | awk '{print $1}')"
    [[ "$got" == "$want" ]] || die "Assembled images tarball checksum mismatch
  expected: $want
  actual:   $got"
  fi
  log "  ok: $(basename "$IMG_TARBALL") assembled"
}
assemble_images_tarball

for f in "$INSTALL_SH" "$BIN_TARBALL" "$IMG_TARBALL" "$SHASUMS"; do
  [[ -s "$f" ]] || die "Missing/empty bundled asset: $f
Populate ./assets first (see README / scripts/fetch-assets.sh on a connected host)."
done

RKE2_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
log "Bundled RKE2 version: ${RKE2_VERSION}"

# Verify artifact integrity against the bundled checksum manifest (offline).
log "Verifying artifact checksums (offline, no network)"
verify_sum() {
  local file="$1" name; name="$(basename "$file")"
  local expected actual
  expected="$(awk -v n="$name" '$2 ~ ("(^|/)" n "$") {print $1; exit}' "$SHASUMS" || true)"
  [[ -n "$expected" ]] || { warn "No checksum entry for $name; skipping."; return 0; }
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] \
    || die "Checksum MISMATCH for $name
  expected: $expected
  actual:   $actual"
  log "  ok: $name"
}
verify_sum "$BIN_TARBALL"
verify_sum "$IMG_TARBALL"

# SELinux handling (RHEL/Rocky 10 ships SELinux Enforcing by default).
if command -v getenforce >/dev/null 2>&1; then
  SELINUX_STATE="$(getenforce 2>/dev/null || echo Disabled)"
else
  SELINUX_STATE="Disabled"
fi
log "SELinux state: ${SELINUX_STATE}"
# Pick the SELinux RPM matching this EL major (e.g. *.el9.* vs *.el10.*),
# falling back to any RPM with the given name prefix.
select_rpm() {
  local prefix="$1" m
  for m in "${ASSETS_DIR}/${prefix}"*".el${EL_MAJOR}."*.rpm; do
    [[ -e "$m" ]] && { printf '%s\n' "$m"; return 0; }
  done
  for m in "${ASSETS_DIR}/${prefix}"*.rpm; do
    [[ -e "$m" ]] && { printf '%s\n' "$m"; return 0; }
  done
  return 1
}
RPM_CONTAINER_SELINUX="$(select_rpm container-selinux- || true)"
RPM_RKE2_SELINUX="$(select_rpm rke2-selinux- || true)"
HAVE_SELINUX_RPMS=0
[[ -n "$RPM_RKE2_SELINUX" ]] && HAVE_SELINUX_RPMS=1

if [[ "$SELINUX_STATE" == "Enforcing" ]]; then
  if [[ $HAVE_SELINUX_RPMS -eq 1 ]]; then
    log "Installing bundled SELinux policy packages (el${EL_MAJOR})"
    [[ -n "$RPM_CONTAINER_SELINUX" ]] \
      && rpm -Uvh --replacepkgs "$RPM_CONTAINER_SELINUX" 2>/dev/null || true
    rpm -Uvh --replacepkgs "$RPM_RKE2_SELINUX"
  elif [[ $SELINUX_PERMISSIVE -eq 1 ]]; then
    warn "No SELinux policy RPM bundled; setting SELinux to Permissive (requested)."
    setenforce 0 || true
    if [[ -f /etc/selinux/config ]]; then
      sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    fi
  else
    die "SELinux is Enforcing but no rke2-selinux policy RPM is bundled in ./assets.
Either bundle container-selinux + rke2-selinux RPMs, or re-run with
--selinux-permissive to set SELinux to Permissive."
  fi
fi

# Firewalld is known to interfere with RKE2 cluster networking.
if systemctl is-active --quiet firewalld 2>/dev/null; then
  if [[ $DISABLE_FIREWALLD -eq 1 ]]; then
    log "Disabling firewalld"
    systemctl disable --now firewalld || true
  else
    warn "firewalld is active. RKE2 recommends disabling it or opening the"
    warn "required ports. Re-run with --disable-firewalld to disable it."
  fi
fi

# nm-cloud-setup (cloud images) breaks RKE2 routing if present/enabled.
if systemctl list-unit-files 2>/dev/null | grep -q '^nm-cloud-setup\.service'; then
  log "Disabling nm-cloud-setup (interferes with RKE2 networking)"
  systemctl disable --now nm-cloud-setup.service nm-cloud-setup.timer 2>/dev/null || true
fi

# Swap should be off for kubelet.
if [[ "$(swapon --noheadings --show 2>/dev/null | wc -l)" -gt 0 ]]; then
  warn "Swap is enabled; disabling for this boot (edit /etc/fstab to persist)."
  swapoff -a || true
fi

# --------------------------------------------------------------------------- #
# Render RKE2 config.yaml
# --------------------------------------------------------------------------- #
RKE2_CONF_DIR="/etc/rancher/rke2"
RKE2_CONF="${RKE2_CONF_DIR}/config.yaml"
mkdir -p "$RKE2_CONF_DIR"

if [[ -n "$CUSTOM_CONFIG" ]]; then
  [[ -s "$CUSTOM_CONFIG" ]] || die "--config file not found: $CUSTOM_CONFIG"
  log "Installing custom config: $CUSTOM_CONFIG -> $RKE2_CONF"
  install -m 0600 "$CUSTOM_CONFIG" "$RKE2_CONF"
elif [[ -s "${CONFIG_DIR}/config.yaml" ]]; then
  log "Using repo config: ${CONFIG_DIR}/config.yaml -> $RKE2_CONF"
  install -m 0600 "${CONFIG_DIR}/config.yaml" "$RKE2_CONF"
else
  log "Generating $RKE2_CONF from arguments"
  {
    echo "# Generated by install-rke2-offline.sh on $(date -u +%FT%TZ)"
    [[ -n "$JOIN_SERVER" ]] && echo "server: ${JOIN_SERVER}"
    [[ -n "$JOIN_TOKEN"  ]] && echo "token: ${JOIN_TOKEN}"
    if [[ ${#TLS_SANS[@]} -gt 0 && "$NODE_TYPE" == "server" ]]; then
      echo "tls-san:"
      for s in "${TLS_SANS[@]}"; do echo "  - ${s}"; done
    fi
    if [[ ${#NODE_IPS[@]} -gt 0 ]]; then
      echo "node-ip:"
      for ip in "${NODE_IPS[@]}"; do echo "  - ${ip}"; done
    fi
  } > "$RKE2_CONF"
  chmod 0600 "$RKE2_CONF"
fi

# --------------------------------------------------------------------------- #
# Run the official RKE2 installer in air-gap (artifact) mode
# --------------------------------------------------------------------------- #
log "Installing RKE2 (${NODE_TYPE}) from local artifacts — no network used"

INSTALL_RKE2_ARTIFACT_PATH="$ASSETS_DIR" \
INSTALL_RKE2_TYPE="$NODE_TYPE" \
INSTALL_RKE2_SKIP_DOWNLOAD="true" \
  sh "$INSTALL_SH"

SERVICE="rke2-${NODE_TYPE}"

if [[ $NO_START -eq 1 ]]; then
  log "--no-start set: RKE2 installed but not started."
  log "Start later with: systemctl enable --now ${SERVICE}.service"
  exit 0
fi

# --------------------------------------------------------------------------- #
# Start RKE2
# --------------------------------------------------------------------------- #
log "Enabling and starting ${SERVICE}.service"
systemctl daemon-reload
systemctl enable --now "${SERVICE}.service"

# --------------------------------------------------------------------------- #
# Post-install: kubectl convenience + readiness wait (server only)
# --------------------------------------------------------------------------- #
if [[ "$NODE_TYPE" == "server" ]]; then
  KUBECTL="${DATA_DIR}/bin/kubectl"
  KUBECONFIG_PATH="${RKE2_CONF_DIR}/rke2.yaml"

  # Expose kubectl + kubeconfig system-wide.
  PROFILE_D="/etc/profile.d/rke2.sh"
  {
    echo "export PATH=\$PATH:${DATA_DIR}/bin"
    echo "export KUBECONFIG=${KUBECONFIG_PATH}"
  } > "$PROFILE_D"
  chmod 0644 "$PROFILE_D"
  [[ -x "$KUBECTL" ]] && ln -sf "$KUBECTL" /usr/local/bin/kubectl 2>/dev/null || true

  log "Waiting for the Kubernetes API to become ready (up to 5 min)..."
  ready=0
  for _ in $(seq 1 60); do
    if [[ -x "$KUBECTL" ]] && \
       KUBECONFIG="$KUBECONFIG_PATH" "$KUBECTL" get --raw='/readyz' >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 5
  done

  if [[ $ready -eq 1 ]]; then
    log "Kubernetes API is ready."
    KUBECONFIG="$KUBECONFIG_PATH" "$KUBECTL" get nodes -o wide || true
  else
    warn "API not ready yet. Check: journalctl -u ${SERVICE} -f"
  fi

  if [[ -z "$JOIN_SERVER" ]]; then
    echo
    log "This is the primary server. Join other nodes with:"
    log "  --server https://$(hostname -I | awk '{print $1}'):9345"
    log "  --token  $(cat ${DATA_DIR}/server/node-token 2>/dev/null || echo '<see '"${DATA_DIR}"'/server/node-token>')"
  fi

  echo
  log "kubeconfig: ${KUBECONFIG_PATH}"
  log "Open a new shell (or 'source ${PROFILE_D}') then: kubectl get nodes"
else
  log "Agent installed and started. Verify from a server with: kubectl get nodes"
  log "Logs: journalctl -u ${SERVICE} -f"
fi

log "Done."
