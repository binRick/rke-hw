#!/usr/bin/env bash
#
# install-registry-offline.sh
#
# Fully offline (air-gapped) private OCI registry for an RKE2 cluster.
#
# RKE2 itself needs NO registry — its system images are imported straight
# into containerd by install-rke2-offline.sh. This script gives the cluster
# somewhere to STORE and SERVE *your own* application images, since Docker
# Hub / quay / ghcr are unreachable in the air-gap.
#
# It uses ONLY the registry image bundled in ./assets (registry-image.tar),
# runs "registry:2" as a podman + systemd service with TLS (no auth), and
# wires every RKE2 node to it via /etc/rancher/rke2/registries.yaml.
#
# Target platform: RHEL / Rocky / Alma / CentOS Stream 9 and 10, x86_64.
#                  Requires podman (shipped by default) or docker.
#
# Usage:
#   sudo ./install-registry-offline.sh [options]
#
# Common scenarios
#   Run the registry on this host (auto-detect IP, self-signed TLS):
#     sudo ./install-registry-offline.sh
#
#   Pick the name nodes will use and seed app images at install time:
#     sudo ./install-registry-offline.sh --host registry.lan --seed ./app-images
#
#   Other cluster nodes (no registry here — just trust + point at it):
#     sudo ./install-registry-offline.sh --client-only \
#          --host registry.lan --ca ./registry-ca.crt
#
# Options:
#   --host <name|ip>     Name/IP nodes use to reach the registry.
#                        (default: this host's primary IP)
#   --port <port>        Registry port.                      (default: 5000)
#   --data-dir <path>    Image blob storage. (default: /var/lib/airgap-registry)
#   --cert <file>        TLS cert (PEM). With --key, used instead of self-signed.
#   --key  <file>        TLS private key (PEM). Requires --cert.
#   --ca <file>          CA clients should trust. (client-only mode: required;
#                        server mode: defaults to the (self-signed) server cert)
#   --image-archive <f>  Bundled registry image tarball.
#                        (default: ./assets/registry-image.tar)
#   --seed <dir>         After start, `podman load` every *.tar in <dir> and
#                        push it into this registry (keeps repo:tag path).
#   --mirror-docker-io   Also mirror docker.io -> this registry in
#                        registries.yaml (only useful if you push docker.io
#                        images in under their original paths).
#   --no-registries-yaml Do not write /etc/rancher/rke2/registries.yaml.
#   --restart-rke2       Restart any active rke2-server/rke2-agent so the new
#                        registries.yaml takes effect now.
#   --open-firewall      If firewalld is active, open the registry port.
#   --client-only        Don't run a registry; only install the CA +
#                        registries.yaml on this node. Needs --host and --ca.
#   --uninstall          Stop & remove the registry service/container/data.
#   -h | --help          Show this help.
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Resolve paths
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ASSETS_DIR="${SCRIPT_DIR}/assets"

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
REG_HOST=""
REG_PORT="5000"
DATA_DIR="/var/lib/airgap-registry"
CERT_IN=""
KEY_IN=""
CA_IN=""
IMAGE_ARCHIVE="${ASSETS_DIR}/registry-image.tar"
SEED_DIR=""
MIRROR_DOCKER_IO=0
WRITE_REGISTRIES_YAML=1
RESTART_RKE2=0
OPEN_FIREWALL=0
CLIENT_ONLY=0
DO_UNINSTALL=0

SVC_NAME="airgap-registry"
CTR_NAME="airgap-registry"
LOCAL_IMG="localhost/airgap-registry:2"
CERT_DIR="/etc/airgap-registry/certs"
UNIT_FILE="/etc/systemd/system/${SVC_NAME}.service"
RKE2_CONF_DIR="/etc/rancher/rke2"
REGISTRIES_YAML="${RKE2_CONF_DIR}/registries.yaml"
NODE_CA="${RKE2_CONF_DIR}/registry-ca.crt"

# --------------------------------------------------------------------------- #
# Logging helpers
# --------------------------------------------------------------------------- #
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,57p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//'; exit "${1:-0}"; }

# --------------------------------------------------------------------------- #
# Parse arguments
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)               REG_HOST="${2:?}"; shift 2 ;;
    --port)               REG_PORT="${2:?}"; shift 2 ;;
    --data-dir)           DATA_DIR="${2:?}"; shift 2 ;;
    --cert)               CERT_IN="${2:?}"; shift 2 ;;
    --key)                KEY_IN="${2:?}"; shift 2 ;;
    --ca)                 CA_IN="${2:?}"; shift 2 ;;
    --image-archive)      IMAGE_ARCHIVE="${2:?}"; shift 2 ;;
    --seed)               SEED_DIR="${2:?}"; shift 2 ;;
    --mirror-docker-io)   MIRROR_DOCKER_IO=1; shift ;;
    --no-registries-yaml) WRITE_REGISTRIES_YAML=0; shift ;;
    --restart-rke2)       RESTART_RKE2=1; shift ;;
    --open-firewall)      OPEN_FIREWALL=1; shift ;;
    --client-only)        CLIENT_ONLY=1; shift ;;
    --uninstall)          DO_UNINSTALL=1; shift ;;
    -h|--help)            usage 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."

# --------------------------------------------------------------------------- #
# Container engine (podman preferred; docker accepted)
# --------------------------------------------------------------------------- #
ENGINE=""
if command -v podman >/dev/null 2>&1; then ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then ENGINE="docker"
fi

# --------------------------------------------------------------------------- #
# Uninstall path
# --------------------------------------------------------------------------- #
if [[ $DO_UNINSTALL -eq 1 ]]; then
  log "Stopping & disabling ${SVC_NAME}.service"
  systemctl disable --now "${SVC_NAME}.service" 2>/dev/null || true
  rm -f "$UNIT_FILE"; systemctl daemon-reload 2>/dev/null || true
  [[ -n "$ENGINE" ]] && "$ENGINE" rm -f "$CTR_NAME" 2>/dev/null || true
  rm -rf "$CERT_DIR"
  rm -f "$NODE_CA"
  [[ -f "${REGISTRIES_YAML}.airgap-registry.bak" ]] \
    && mv -f "${REGISTRIES_YAML}.airgap-registry.bak" "$REGISTRIES_YAML" \
    && log "Restored previous registries.yaml" \
    || rm -f "$REGISTRIES_YAML"
  warn "Image data left at ${DATA_DIR} (remove manually if no longer needed)."
  log "Registry uninstalled. Restart rke2 to drop the registries.yaml change."
  exit 0
fi

# --------------------------------------------------------------------------- #
# Resolve registry host
# --------------------------------------------------------------------------- #
if [[ -z "$REG_HOST" ]]; then
  REG_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$REG_HOST" ]] || die "Could not auto-detect an IP; pass --host <name|ip>."
  warn "No --host given; using detected IP: ${REG_HOST}"
fi
REG_ADDR="${REG_HOST}:${REG_PORT}"
is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

write_registries_yaml() {
  local ca_path="$1"
  [[ $WRITE_REGISTRIES_YAML -eq 1 ]] || { log "Skipping registries.yaml (--no-registries-yaml)"; return 0; }
  mkdir -p "$RKE2_CONF_DIR"
  install -m 0644 "$ca_path" "$NODE_CA"
  if [[ -s "$REGISTRIES_YAML" && ! -f "${REGISTRIES_YAML}.airgap-registry.bak" ]]; then
    cp -a "$REGISTRIES_YAML" "${REGISTRIES_YAML}.airgap-registry.bak"
    warn "Existing registries.yaml backed up to ${REGISTRIES_YAML}.airgap-registry.bak (review/merge if you had custom entries)."
  fi
  {
    echo "# Generated by install-registry-offline.sh on $(date -u +%FT%TZ)"
    echo "mirrors:"
    echo "  \"${REG_ADDR}\":"
    echo "    endpoint:"
    echo "      - \"https://${REG_ADDR}\""
    if [[ $MIRROR_DOCKER_IO -eq 1 ]]; then
      echo "  docker.io:"
      echo "    endpoint:"
      echo "      - \"https://${REG_ADDR}\""
    fi
    echo "configs:"
    echo "  \"${REG_ADDR}\":"
    echo "    tls:"
    echo "      ca_file: ${NODE_CA}"
  } > "$REGISTRIES_YAML"
  chmod 0600 "$REGISTRIES_YAML"
  log "Wrote ${REGISTRIES_YAML} (CA: ${NODE_CA})"
}

maybe_restart_rke2() {
  [[ $RESTART_RKE2 -eq 1 ]] || { warn "Restart rke2-server/rke2-agent for registries.yaml to take effect (or re-run with --restart-rke2)."; return 0; }
  for s in rke2-server rke2-agent; do
    if systemctl is-active --quiet "${s}.service" 2>/dev/null; then
      log "Restarting ${s}.service"
      systemctl restart "${s}.service" || warn "Restart of ${s} failed; restart manually."
    fi
  done
}

# --------------------------------------------------------------------------- #
# client-only: trust the CA + point this node at the registry, then stop
# --------------------------------------------------------------------------- #
if [[ $CLIENT_ONLY -eq 1 ]]; then
  log "client-only mode for ${REG_ADDR}"
  [[ -s "$CA_IN" ]] || die "--client-only requires --ca <file> (the registry's CA/cert)."
  cp "$CA_IN" "/etc/pki/ca-trust/source/anchors/${SVC_NAME}.crt"
  command -v update-ca-trust >/dev/null 2>&1 && update-ca-trust extract || true
  write_registries_yaml "$CA_IN"
  maybe_restart_rke2
  log "Done. This node now trusts and pulls from ${REG_ADDR}."
  exit 0
fi

# --------------------------------------------------------------------------- #
# Server mode pre-flight
# --------------------------------------------------------------------------- #
[[ -n "$ENGINE" ]] || die "Need podman (preferred) or docker to run the registry.
On RHEL/Rocky: 'dnf install -y podman' (do this while still connected, or
bundle the podman RPMs for a true air-gap)."
[[ -s "$IMAGE_ARCHIVE" ]] || die "Missing registry image archive: $IMAGE_ARCHIVE
Run scripts/fetch-assets.sh on a connected host to bundle it."

# Verify the archive against its bundled checksum (offline) if present.
SUMFILE="${ASSETS_DIR}/registry-image.sha256"
if [[ -s "$SUMFILE" ]]; then
  log "Verifying registry image archive checksum"
  ( cd "$ASSETS_DIR" && sha256sum -c --quiet "$(basename "$SUMFILE")" ) \
    || die "registry-image.tar checksum mismatch — re-fetch ./assets."
fi

# --------------------------------------------------------------------------- #
# TLS material (provided cert/key, else self-signed leaf used as its own CA)
# --------------------------------------------------------------------------- #
mkdir -p "$CERT_DIR"
CRT="${CERT_DIR}/registry.crt"
KEY="${CERT_DIR}/registry.key"

if [[ -n "$CERT_IN" || -n "$KEY_IN" ]]; then
  [[ -s "$CERT_IN" && -s "$KEY_IN" ]] || die "--cert and --key must both be given and non-empty."
  install -m 0644 "$CERT_IN" "$CRT"
  install -m 0600 "$KEY_IN"  "$KEY"
  CA_FILE="${CA_IN:-$CRT}"
  log "Using provided TLS cert/key"
else
  command -v openssl >/dev/null 2>&1 || die "openssl not found (needed to self-sign). Provide --cert/--key instead."
  if is_ip "$REG_HOST"; then SAN="IP:${REG_HOST},IP:127.0.0.1,DNS:localhost"
  else                       SAN="DNS:${REG_HOST},DNS:localhost,IP:127.0.0.1"; fi
  log "Generating self-signed TLS cert for ${REG_HOST} (SAN: ${SAN})"
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout "$KEY" -out "$CRT" \
    -subj "/CN=${REG_HOST}" -addext "subjectAltName=${SAN}" >/dev/null 2>&1 \
    || die "openssl self-sign failed."
  chmod 0644 "$CRT"; chmod 0600 "$KEY"
  CA_FILE="$CRT"   # a self-signed leaf is its own trust anchor
fi

# Trust the CA on THIS host so 'podman push' / crictl work without --tls-verify=false.
cp "$CA_FILE" "/etc/pki/ca-trust/source/anchors/${SVC_NAME}.crt"
command -v update-ca-trust >/dev/null 2>&1 && update-ca-trust extract || true

# --------------------------------------------------------------------------- #
# Load & tag the bundled registry image (offline)
# --------------------------------------------------------------------------- #
log "Loading bundled registry image ($ENGINE)"
"$ENGINE" load -i "$IMAGE_ARCHIVE" >/dev/null
SRC_REF=""
[[ -s "${ASSETS_DIR}/registry-image.ref" ]] && SRC_REF="$(cat "${ASSETS_DIR}/registry-image.ref")"
[[ -n "$SRC_REF" ]] || SRC_REF="docker.io/library/registry:2"
"$ENGINE" tag "$SRC_REF" "$LOCAL_IMG" 2>/dev/null \
  || "$ENGINE" tag "${SRC_REF##*/}" "$LOCAL_IMG"
log "Registry image ready: ${LOCAL_IMG}"

mkdir -p "$DATA_DIR"

# --------------------------------------------------------------------------- #
# systemd unit (podman keeps the container in the foreground via sdnotify)
# --------------------------------------------------------------------------- #
log "Installing ${UNIT_FILE}"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Air-gapped OCI registry (registry:2) for RKE2
Documentation=https://distribution.github.io/distribution/
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
NotifyAccess=all
Restart=always
RestartSec=5
TimeoutStartSec=120
ExecStartPre=-/usr/bin/${ENGINE} rm -f ${CTR_NAME}
ExecStart=/usr/bin/${ENGINE} run --replace --name ${CTR_NAME} \\
  --sdnotify=conmon \\
  -p ${REG_PORT}:5000 \\
  -v ${DATA_DIR}:/var/lib/registry:Z \\
  -v ${CERT_DIR}:/certs:ro,Z \\
  -e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \\
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \\
  -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \\
  ${LOCAL_IMG}
ExecStop=/usr/bin/${ENGINE} stop -t 10 ${CTR_NAME}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
log "Enabling & starting ${SVC_NAME}.service"
systemctl enable --now "${SVC_NAME}.service"

# Wait for the registry API to answer (offline, local).
log "Waiting for the registry to become ready..."
ready=0
for _ in $(seq 1 30); do
  if curl -fsS --cacert "$CA_FILE" "https://${REG_ADDR}/v2/" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 2
done
[[ $ready -eq 1 ]] && log "Registry is up at https://${REG_ADDR}/v2/" \
  || warn "Registry not answering yet. Check: journalctl -u ${SVC_NAME} -f"

# --------------------------------------------------------------------------- #
# Firewall
# --------------------------------------------------------------------------- #
if systemctl is-active --quiet firewalld 2>/dev/null; then
  if [[ $OPEN_FIREWALL -eq 1 ]]; then
    log "Opening ${REG_PORT}/tcp in firewalld"
    firewall-cmd --permanent --add-port="${REG_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  else
    warn "firewalld is active. Other nodes can't reach the registry until you run:"
    warn "  firewall-cmd --permanent --add-port=${REG_PORT}/tcp && firewall-cmd --reload"
    warn "(or re-run with --open-firewall)"
  fi
fi

# --------------------------------------------------------------------------- #
# Optionally seed application images into the registry
# --------------------------------------------------------------------------- #
if [[ -n "$SEED_DIR" ]]; then
  [[ -d "$SEED_DIR" ]] || die "--seed dir not found: $SEED_DIR"
  shopt -s nullglob
  archives=( "$SEED_DIR"/*.tar )
  shopt -u nullglob
  [[ ${#archives[@]} -gt 0 ]] || warn "No *.tar archives in ${SEED_DIR}; nothing to seed."
  for a in "${archives[@]}"; do
    log "Seeding $(basename "$a")"
    ref="$("$ENGINE" load -i "$a" 2>/dev/null | sed -n 's/^Loaded image: *//p; s/^Loaded image(s): *//p' | head -1)"
    [[ -n "$ref" ]] || { warn "  could not determine image ref from $a; skipping."; continue; }
    # Strip any registry host, keep repo:tag path so refs stay predictable.
    path="${ref#*/}"; [[ "$path" == "$ref" ]] && path="$ref"
    dest="${REG_ADDR}/${path}"
    "$ENGINE" tag "$ref" "$dest"
    "$ENGINE" push "$dest" \
      && log "  pushed ${dest}" \
      || warn "  push failed for ${dest}"
  done
fi

# --------------------------------------------------------------------------- #
# Wire RKE2 nodes to the registry
# --------------------------------------------------------------------------- #
write_registries_yaml "$CA_FILE"
maybe_restart_rke2

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo
log "Private registry ready: https://${REG_ADDR}"
log "CA for other nodes: ${CA_FILE}"
echo
log "Push an app image into it (from a host that trusts the CA):"
log "  ${ENGINE} tag myapp:1.0 ${REG_ADDR}/myapp:1.0"
log "  ${ENGINE} push ${REG_ADDR}/myapp:1.0"
log "Then in Kubernetes use image: ${REG_ADDR}/myapp:1.0"
echo
log "On every OTHER cluster node, copy ${CA_FILE} over and run:"
log "  sudo ./install-registry-offline.sh --client-only \\"
log "       --host ${REG_HOST} --port ${REG_PORT} --ca <copied-ca.crt> --restart-rke2"
log "Done."
