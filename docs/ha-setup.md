# High availability — surviving a server failure (offline)

This explains how to run hello-db so the application **stays alive when a
node goes down**, fully air-gapped. It builds on
[`docs/two-server-setup.md`](two-server-setup.md) and
[`docs/hello-db-app.md`](hello-db-app.md).

## Why the default isn't HA

The stock chart runs **one** Postgres pod with `emptyDir` (or one RWO PVC)
and one app pod. Lose the wrong node and the site is down (and demo data is
gone). True HA needs three things, each addressed below.

| Layer | Single-node risk | HA fix |
|---|---|---|
| Control plane | 1 RKE2 server = cluster dies with it | **≥3 server nodes** (etcd quorum) |
| App (stateless) | all replicas on one node | `replicas≥2` + topology spread + PDB |
| Database (stateful) | 1 pod, node-local data | **CloudNativePG** cluster (replicated, auto-failover) |
| Storage | node-local volume stranded on node loss | **Longhorn** (replicated block storage) |

## How RKE2/Kubernetes reacts to a node failure

1. **etcd quorum** keeps the API alive as long as a majority of server
   nodes are up (3 servers tolerate 1 loss; 5 tolerate 2).
2. kubelet stops heart-beating → node marked `NotReady` (~40s) → after the
   eviction timeout (~5 min) pods on the dead node are recreated elsewhere
   by their Deployment/ReplicaSet.
3. `Service` + kube-proxy only send traffic to **Ready** endpoints, so
   surviving app replicas keep serving during the gap.
4. A stateful pod only comes back **with its data** if storage can follow it
   — that's why Longhorn (replicated) replaces node-local volumes, and why
   Postgres itself replicates via CloudNativePG (the new primary already has
   the data).

## Prerequisites

- An RKE2 cluster with **≥3 server nodes** and ideally ≥1 worker. Join extra
  servers with `install-rke2-offline.sh --type server --server … --token …`.
- The private registry up, and **every node trusts its CA** and can resolve
  it (`install-registry-offline.sh --client-only …` on each).
- **Longhorn node prereqs on every node** (air-gap: must be pre-installed):
  `open-iscsi` with the `iscsi_tcp` module loaded, and disk space under
  `/var/lib/longhorn`.

---

## Step 0 — Bundle the HA assets (connected host)

```bash
./scripts/fetch-ha-assets.sh        # fills assets/ha/, then git-commit it
```

This downloads the CloudNativePG operator manifest + images and the Longhorn
manifest + its full image set, split into <90 MB parts (no Git LFS). Pin
versions with `CNPG_VERSION` / `LONGHORN_VERSION` env vars if needed. Commit
`assets/ha/` and move the repo to the cluster as usual.

## Step 1 — Install the HA infrastructure (on a cluster node)

```bash
cd /root/rke-hw
sudo ./deploy-ha-offline.sh --registry 10.0.0.10:5000 --set-default-sc
```

It loads the bundled images, pushes them into your private registry,
rewrites the upstream manifests to pull from that registry, applies Longhorn
and the CloudNativePG operator, and waits for both to roll out.
(`--skip-longhorn` / `--skip-cnpg` if you already run one of them.)

Verify:

```bash
KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl \
  get pods -n longhorn-system
KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl \
  get pods -n cnpg-system
```

## Step 2 — Deploy hello-db in HA mode

```bash
KUBECONFIG=/etc/rancher/rke2/rke2.yaml ./assets/app/helm \
  upgrade --install hello-db ./charts/hello-db -n hello-db --create-namespace \
  --set image.registry=10.0.0.10:5000 \
  --set postgres.ha.enabled=true \
  --set postgres.ha.instances=3 \
  --set postgres.ha.storageClass=longhorn \
  --set app.replicas=3 \
  --set app.pdb.enabled=true \
  --set app.topologySpread.whenUnsatisfiable=DoNotSchedule \
  --wait --timeout 10m
```

(The app image must already be in the registry — run
`deploy-app-offline.sh --push-only` first if you haven't.)

What this changes vs. the demo:

- **Postgres** → a 3-instance CloudNativePG `Cluster` with synchronous
  replication (`minSyncReplicas=1`) and automatic failover. The app connects
  to the `…-pgha-rw` service, which always points at the current primary.
- **App** → 3 replicas, hard-spread across nodes
  (`whenUnsatisfiable=DoNotSchedule`), protected by a PodDisruptionBudget so
  drains/upgrades never take them all down at once.
- **Storage** → Longhorn replicates each Postgres volume across nodes, so a
  node loss doesn't strand the data.

## Step 3 — Test the failover

```bash
KC="KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl"
# Find the Postgres primary's node:
eval $KC -n hello-db get pods -l cnpg.io/instanceRole=primary -o wide
# Drain (or power off) that node:
eval $KC drain <node> --ignore-daemonsets --delete-emptydir-data
# Within ~30s CNPG promotes a standby; keep refreshing the web page —
# the counter keeps incrementing. Then uncordon:
eval $KC uncordon <node>
```

The guestbook stays available and committed messages survive, because a
synchronous standby already had the data and became the new primary.

## Rollback / removal

```bash
# App back to single-node demo:
… helm upgrade hello-db ./charts/hello-db -n hello-db --reuse-values \
  --set postgres.ha.enabled=false

# HA infra:
sudo ./deploy-ha-offline.sh --uninstall   # removes CNPG; prints Longhorn steps
```

## Caveats / honest limitations

- **Untested end-to-end here.** The scripts/chart are validated by
  `helm template` + ShellCheck in CI, but a real `fetch-ha-assets.sh` (on a
  connected host) → air-gapped install has not been run by the author.
  Treat the first run as a commissioning exercise; versions are pinned in
  `scripts/fetch-ha-assets.sh` (`CNPG_VERSION`, `LONGHORN_VERSION`).
- **Longhorn is heavy**: many images (~GB) and per-node prerequisites
  (`open-iscsi`). For a true air-gap you must also have those OS packages
  available offline.
- Switching `postgres.ha.enabled` on an **existing** release does not migrate
  data — it's a different backend. Start HA from a fresh release (or
  dump/restore).
- A single external entry IP across nodes (LoadBalancer/Ingress VIP via
  kube-vip/MetalLB) is **out of scope** here; NodePort on every node already
  gives node-failure-tolerant access if clients retry another node IP.
