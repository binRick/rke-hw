# rke-hw — Offline (air-gapped) RKE2 Kubernetes installer

[![lint](https://github.com/binRick/rke-hw/actions/workflows/lint.yml/badge.svg)](https://github.com/binRick/rke-hw/actions/workflows/lint.yml)

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
├── install-rke2-offline.sh      # the offline installer (run on the air-gapped node)
├── install-registry-offline.sh  # optional private OCI registry for your app images
├── deploy-app-offline.sh        # deploy the bundled hello-db demo app
├── app/                         # Flask + Postgres demo source + Containerfile
├── charts/hello-db/             # Helm chart for the demo app
├── assets/                   # all binaries & images — no network needed
│   ├── install.sh            # official RKE2 installer (artifact mode)
│   ├── rke2.linux-amd64.tar.gz          # RKE2 binaries (~37 MB)
│   ├── rke2-images.linux-amd64.tar.zst.part00..08  # images, split <100 MB
│   ├── rke2-images.parts.sha256         # per-part integrity manifest
│   ├── sha256sum-amd64.txt              # official integrity manifest
│   ├── registry-image.tar               # registry:2 image (for the private registry)
│   ├── app/                             # hello-db image parts + bundled helm
│   └── VERSION
├── config/
│   ├── config.yaml.example      # copy to config/config.yaml to customize
│   └── registries.yaml.example  # private-registry reference
└── scripts/
    ├── fetch-assets.sh       # re-populate assets/ on a CONNECTED host
    └── build-app-assets.sh   # build/bundle the demo app on a CONNECTED host
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

## Private registry for your own application images

RKE2 itself needs **no registry** — its system images are imported straight
into containerd by the installer above. But once the cluster is up, any
workload of *yours* that references `myapp:1.0` (or even `nginx:latest`) will
hit `ImagePullBackOff`, because Docker Hub / quay / ghcr are unreachable in
the air-gap. You need somewhere on-network to **store and serve** app images.

`install-registry-offline.sh` provides that: it loads the bundled
`registry:2` image, runs it as a **podman + systemd** service with
**TLS (no auth)**, and writes `/etc/rancher/rke2/registries.yaml` so every
node pulls from it transparently.

```bash
# On the node that will host the registry (self-signed TLS, auto IP):
sudo ./install-registry-offline.sh --host registry.lan --restart-rke2

# Seed app images at install time (any *.tar from `podman save` / skopeo):
sudo ./install-registry-offline.sh --host registry.lan --seed ./app-images

# On every OTHER cluster node — just trust the CA and point at it:
sudo ./install-registry-offline.sh --client-only \
     --host registry.lan --ca ./registry-ca.crt --restart-rke2
```

Push an image in (from any host that trusts the generated CA), then reference
it from Kubernetes:

```bash
podman tag myapp:1.0 registry.lan:5000/myapp:1.0
podman push    registry.lan:5000/myapp:1.0
# k8s manifest:  image: registry.lan:5000/myapp:1.0
```

**New to this?** A complete copy-paste walkthrough for putting the registry
and RKE2 on **two separate servers** is in
[`docs/two-server-setup.md`](docs/two-server-setup.md).

`--help` lists all options (port, data-dir, supplying your own cert/key,
`--mirror-docker-io`, `--open-firewall`, `--uninstall`). The registries.yaml
shape is documented in [`config/registries.yaml.example`](config/registries.yaml.example).
Requires `podman` (default on RHEL/Rocky) or `docker` on the registry host —
bundle the podman RPMs too for a strict air-gap.

## Demo app: hello-db (Flask + PostgreSQL)

`app/` + `charts/hello-db/` is a complete, runnable sample workload — a tiny
**Flask guestbook with a visit counter, backed by PostgreSQL**, both running
as pods *inside* the air-gapped cluster. It is deliberately small but
structured as a **reference pattern** for hosting real applications on RKE2
with no internet.

### What it does

- A web page (`/`) shows a visit counter and the last 20 guestbook messages.
- Posting the form (`POST /add`) writes a row to PostgreSQL.
- `/healthz` is a cheap **liveness** check (process up); `/readyz` is a
  **readiness** check that actually runs `SELECT 1` against the database, so
  the app only receives traffic once its backend is genuinely reachable.
- `/api/messages` returns the same data as JSON.

The Flask app is served by **gunicorn** (2 workers × 4 threads), runs as a
**non-root** user (UID 10001, works under RKE2's restricted/SELinux
defaults), and creates its schema on startup — retrying for ~60s while
PostgreSQL finishes booting, so pod start ordering doesn't matter.

### How the pieces fit together

```
            NodePort :30080
                  │
        ┌─────────▼──────────┐        ClusterIP :5432
        │  hello-db-app      │  DB_*  ┌──────────────────┐
        │  (Flask+gunicorn)  ├───────▶│ hello-db-postgres │
        │  Deployment + Svc  │  env   │ Deployment + Svc  │
        └────────────────────┘        └──────────────────┘
              image: <registry>/hello-db-app:1.0.0
                      <registry>/postgres:16-alpine
```

- **Config & secrets**: DB name/user are passed as plain env; the password
  lives in a Kubernetes `Secret`. The app reads `DB_HOST/PORT/NAME/USER` from
  env and `DB_PASSWORD` from the Secret via `secretKeyRef` — never baked into
  the image.
- **Service discovery**: the app finds the database purely by Service DNS
  (`<release>-hello-db-postgres`), so nothing is hard-coded to an IP.
- **Images come from *your* registry**: every image reference is
  `{{ .Values.image.registry }}/...`, so the cluster never reaches out to
  Docker Hub. The deploy script rewrites that one value to your private
  registry address.

### What it proves

It exercises the **entire offline supply chain** in one command:

> **build** (connected host) → **bundle** (split, checksummed tarballs in
> `assets/app/`) → **private registry** (`install-registry-offline.sh`) →
> **Helm** (bundled CLI, no system Helm) → **running on RKE2** — with zero
> network access on the cluster.

If `hello-db` comes up green, you've validated that registry trust,
`registries.yaml` wiring, image push/pull, Helm, and scheduling all work
end-to-end on your air-gapped cluster.

### A model for RKE2 app hosting

Use this as the template for your own apps. The pattern it demonstrates:

1. **Build & vendor images on a connected host**, never on the cluster
   (`scripts/build-app-assets.sh`: build/pull → `save` → split <90 MB →
   `sha256` manifest + `.ref` files). This is the same Git-LFS-free scheme
   the RKE2 image bundle uses.
2. **Serve images from the in-cluster private registry**, not by importing
   into each node's containerd — this scales to many nodes and image updates.
3. **Ship a self-contained Helm chart** whose `image.registry` is a single
   overridable value, so the *same* chart works in dev (Docker Hub) and
   air-gap (your registry) by changing one `--set`.
4. **Externalise config**: env + `Secret`, no secrets in images or values
   committed to git (the demo password is a placeholder — override it).
5. **Real probes**: liveness ≠ readiness; readiness gates on dependencies so
   rollouts and Service endpoints behave correctly.
6. **No hidden infra deps**: defaults to `emptyDir` so the chart runs on a
   vanilla RKE2 cluster with **no StorageClass**; persistence is opt-in.
7. **Idempotent, reversible deploys**: `helm upgrade --install` +
   `--uninstall`; `--push-only` / `--deploy-only` so image distribution and
   release management can run on different hosts/roles.

### The Helm chart (`charts/hello-db/`)

```
charts/hello-db/
├── Chart.yaml                     # name/version/appVersion
├── values.yaml                    # the only file you normally edit
└── templates/
    ├── _helpers.tpl               # name/label helpers (fullname, labels)
    ├── postgres-secret.yaml       # DB credentials (Secret)
    ├── postgres-deployment.yaml   # PG Deployment (+ optional PVC)
    ├── postgres-service.yaml      # ClusterIP :5432
    ├── app-deployment.yaml        # Flask Deployment, probes, env-from-secret
    ├── app-service.yaml           # NodePort :30080 (configurable)
    └── NOTES.txt                  # post-install access instructions
```

Key `values.yaml` knobs:

| Value | Default | Purpose |
|---|---|---|
| `image.registry` | `registry.lan:5000` | Your private registry (deploy script overrides) |
| `image.app.tag` / `image.postgres.tag` | `1.0.0` / `16-alpine` | Image tags |
| `app.replicas` | `1` | Flask replica count |
| `app.service.type` / `nodePort` | `NodePort` / `30080` | How the app is exposed |
| `postgres.password` | `hello-pw` | **Demo only — override in production** |
| `postgres.persistence.enabled` | `false` | `false`=emptyDir (no StorageClass needed); `true`=PVC |
| `postgres.persistence.storageClass` / `size` | `""` / `1Gi` | Used only when persistence is enabled |

Override anything the usual Helm way, e.g.
`--set postgres.password=$(openssl rand -hex 16) --set app.replicas=3`.

### Run it

```bash
# 1. ONCE on a connected host: build app + pull postgres + fetch helm CLI
./scripts/build-app-assets.sh        # fills assets/app/, then git-commit it

# 2. On the air-gapped cluster (private registry already up & trusted):
sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000

# 3. Open it on any node IP:
#    http://<node-ip>:30080/
```

`deploy-app-offline.sh` reassembles + checksum-verifies the bundled image
parts, pushes the app and Postgres images into your private registry, then
uses the **bundled Helm CLI** (`assets/app/helm`) to `helm upgrade --install`
the chart — no network, no system Helm required. Flags: `--push-only`,
`--deploy-only`, `--uninstall`, `--namespace`, `--node-port`,
`--registry`, `--kubeconfig`, `--helm` (`--help` for all).

Full newbie walkthrough: [`docs/hello-db-app.md`](docs/hello-db-app.md).
Chart reference: [`charts/hello-db/values.yaml`](charts/hello-db/values.yaml).

> **Persistence note:** with the `emptyDir` default, guestbook data is lost
> if the Postgres pod restarts — fine for a demo. For durable data, install a
> StorageClass and redeploy with `--set postgres.persistence.enabled=true`.

### Updating the app (developer workflow)

The iteration loop has two halves: the **connected side** (rebuild & bundle)
and the **air-gapped side** (push & roll out). Pick the scenario:

#### A. You changed application code (`app/`)

> **Golden rule: never reuse an image tag.** The chart pulls with
> `imagePullPolicy: IfNotPresent`, so re-pushing `:1.0.0` will *not* update
> running nodes. Every code change gets a **new immutable tag**.

**On a connected host:**

1. Edit the code in `app/` (e.g. `app/app.py`).
2. Pick the next version, e.g. `1.1.0`. (Optional but tidy: also bump
   `version`/`appVersion` in `charts/hello-db/Chart.yaml` and the default
   `image.app.tag` in `charts/hello-db/values.yaml` to match.)
3. Rebuild and re-bundle with that tag:
   ```bash
   APP_TAG=1.1.0 ./scripts/build-app-assets.sh
   ```
   This rebuilds the image, re-splits `assets/app/hello-db-app.tar.part*`,
   and refreshes `assets/app/hello-db-app.ref` so it now reads
   `localhost/hello-db-app:1.1.0`.
4. Commit the code, chart, and the regenerated `assets/app/` together:
   ```bash
   git add app charts assets/app
   git commit -m "hello-db 1.1.0: <what changed>"
   ```
5. Move the updated repo to the air-gapped side (USB / mirror), as usual.

**On the air-gapped cluster:**

6. Push the new image and roll out the release in one step:
   ```bash
   sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000
   ```
   `deploy-app-offline.sh` reads the new tag from the `.ref` file
   automatically, pushes `…/hello-db-app:1.1.0`, then
   `helm upgrade --install` performs a **rolling update** (old pods stay up
   until the new ones pass `/readyz`). `--wait` blocks until it's healthy.
7. Verify:
   ```bash
   KUBECONFIG=/etc/rancher/rke2/rke2.yaml \
     kubectl -n hello-db rollout status deploy/hello-db-app
   kubectl -n hello-db get pods -o wide
   ```

#### B. You only changed the chart / config (no code change)

No rebuild needed — the images are unchanged. Just commit the edited
`charts/hello-db/` files, move the repo over, and run the deploy step
without re-pushing images:

```bash
sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000 --deploy-only
```

Or override a single value ad hoc without editing files, e.g. scale up or
rotate the DB password:

```bash
KUBECONFIG=/etc/rancher/rke2/rke2.yaml assets/app/helm \
  upgrade hello-db charts/hello-db -n hello-db --reuse-values \
  --set app.replicas=3
```

#### Roll back a bad release

Helm keeps revision history, so recovery doesn't need the old artifacts:

```bash
KUBECONFIG=/etc/rancher/rke2/rke2.yaml assets/app/helm \
  history hello-db -n hello-db
KUBECONFIG=/etc/rancher/rke2/rke2.yaml assets/app/helm \
  rollback hello-db <REVISION> -n hello-db
```

(The previous image tag is still in the registry from its earlier push, so
the rollback's pods pull cleanly — another reason tags must be immutable.)

#### Splitting the roles

In a stricter setup the developer who builds images and the operator who
releases may be different people/hosts. Decouple them:

- Build host / image custodian: `… --push-only` (loads & pushes images only).
- Release operator on a cluster node: `… --deploy-only` (Helm only).

#### Notes for real apps

- **Database schema changes:** the demo uses `CREATE TABLE IF NOT EXISTS` on
  startup. Real apps should ship versioned migrations (run them as a Helm
  pre-upgrade `Job`/hook, or an init container) rather than mutating schema
  from app code.
- **Postgres upgrades:** bumping `image.postgres.tag` across a major version
  is *not* a drop-in change if persistence is enabled (PG data dir is
  version-specific) — plan a dump/restore. Patch/minor bumps are safe.
- **Config vs. image:** anything that changes per environment belongs in
  `values.yaml`/`Secret`, not the image — so the same tagged image promotes
  unchanged from dev to the air-gapped cluster.

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

### Release bundles (download one file instead of cloning)

The `release` workflow
([`.github/workflows/release.yml`](.github/workflows/release.yml)) builds a
single self-contained `rke-hw-offline-<rke2-version>.tar.gz` (the repo +
freshly regenerated `assets/`, RKE2 + registry + the hello-db app + bundled
Helm) plus a `.sha256`. Push a `vX.Y.Z` tag and it is attached to that GitHub
Release; a manual *Run workflow* (optionally pinning the RKE2 version)
uploads it as a workflow artifact instead. Operators then grab one file:

```bash
curl -fLO https://github.com/binRick/rke-hw/releases/download/<tag>/rke-hw-offline-<ver>.tar.gz
sha256sum -c rke-hw-offline-<ver>.tar.gz.sha256
tar -xzf rke-hw-offline-<ver>.tar.gz && cd rke-hw* && sudo ./install-rke2-offline.sh
```

## SELinux

RHEL/Rocky 9 and 10 ship SELinux **Enforcing**. For a strict air-gap install
with SELinux enforcing, drop the matching `container-selinux-*.rpm` and
`rke2-selinux-*.rpm` into `assets/`. The installer detects the host's EL major
version and automatically prefers the right RPM (e.g. `*.el9.*` on RHEL 9,
`*.el10.*` on RHEL 10), so you can bundle both families side by side.
Otherwise run with `--selinux-permissive`.
