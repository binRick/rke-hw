# rke-hw — Offline (air-gapped) RKE2 Kubernetes installer

Everything required to stand up an [RKE2](https://docs.rke2.io) Kubernetes
cluster on a **network-disconnected** RHEL / Rocky / Alma / CentOS Stream
**9 or 10** (x86_64) host is contained in this repository. The target node
makes **no network calls**. The bundled RKE2 tarball is EL-version
independent; only the optional SELinux policy RPMs are version-specific.

Bundled version: see [`assets/VERSION`](assets/VERSION) — **v1.35.4+rke2r1**
(current RKE2 stable channel).

## Repository layout

```
.
├── install-rke2-offline.sh   # the offline installer (run on the air-gapped node)
├── assets/                   # all binaries & images — no network needed
│   ├── install.sh            # official RKE2 installer (artifact mode)
│   ├── rke2.linux-amd64.tar.gz          # RKE2 binaries (~37 MB)
│   ├── rke2-images.linux-amd64.tar.zst.part00..08  # images, split <100 MB
│   ├── rke2-images.parts.sha256         # per-part integrity manifest
│   ├── sha256sum-amd64.txt              # official integrity manifest
│   └── VERSION
├── config/
│   └── config.yaml.example   # copy to config/config.yaml to customize
└── scripts/
    └── fetch-assets.sh       # re-populate assets/ on a CONNECTED host
```

## Quick start (on the air-gapped node)

Copy this whole repo to the target, then:

```bash
# First / only control-plane node
sudo ./install-rke2-offline.sh --type server --tls-san k8s.example.com

# Worker node (token printed by the first server install)
sudo ./install-rke2-offline.sh --type agent \
     --server https://<server-ip>:9345 --token <node-token>

# Additional HA server
sudo ./install-rke2-offline.sh --type server \
     --server https://<server-ip>:9345 --token <node-token>
```

After the server install completes, in a new shell:

```bash
kubectl get nodes -o wide        # kubeconfig & PATH set via /etc/profile.d/rke2.sh
```

The installer verifies every artifact against `sha256sum-amd64.txt` before
touching the system, handles SELinux/firewalld/swap pre-flight, renders
`/etc/rancher/rke2/config.yaml`, and runs the official installer in
`INSTALL_RKE2_ARTIFACT_PATH` air-gap mode. Run with `--help` for all options;
`--uninstall` removes RKE2.

## Refreshing / changing version (connected host only)

```bash
./scripts/fetch-assets.sh                 # latest stable into assets/
./scripts/fetch-assets.sh v1.36.0+rke2r1  # a specific version
git add assets && git commit -m "Bump RKE2 assets"
```

## Note on large binaries

`assets/` contains ~850 MB of binary artifacts committed by request so the
install is fully self-contained. **No Git LFS is required:** GitHub rejects
single files >100 MB on a normal push, so the ~812 MB images tarball is
committed split into nine `<90 MB` parts
(`rke2-images.linux-amd64.tar.zst.part00`..`part08`). A plain `git clone`
gets everything.

The offline installer verifies each part against `rke2-images.parts.sha256`,
concatenates them back into `rke2-images.linux-amd64.tar.zst` (re-checked
against the official `sha256sum-amd64.txt`), and proceeds — all on the
air-gapped node with no network. The reassembled file is git-ignored so it is
never accidentally committed. To re-split after a version bump, just re-run
`scripts/fetch-assets.sh` on a connected host.

## SELinux

RHEL/Rocky 9 and 10 ship SELinux **Enforcing**. For a strict air-gap install
with SELinux enforcing, drop the matching `container-selinux-*.rpm` and
`rke2-selinux-*.rpm` into `assets/`. The installer detects the host's EL major
version and automatically prefers the right RPM (e.g. `*.el9.*` on RHEL 9,
`*.el10.*` on RHEL 10), so you can bundle both families side by side.
Otherwise run with `--selinux-permissive`.
