# Deploying the hello-db demo app (Flask + PostgreSQL, fully offline)

This walks a newbie admin through running the bundled demo application on the
cluster. It assumes you already finished
[`docs/two-server-setup.md`](two-server-setup.md), i.e.:

* RKE2 is running on the **KUBE server** (`10.0.0.20`)
* The private registry is running on the **REGISTRY server** (`10.0.0.10`)
* The KUBE server already trusts the registry (you ran the
  `--client-only` step)

> Swap in your real IPs everywhere. The registry address used below is
> `10.0.0.10:5000`.

## What the app is

A tiny **guestbook**: a Python **Flask** web page with a visit counter and a
message list, storing everything in a **PostgreSQL** database. Both run as
pods in the cluster.

> **The app, Postgres and Helm binaries are committed in `assets/app/`.**
> A plain `git clone` already has everything — you do **not** need internet
> and you do **not** need a private registry.

---

# Simplest path — no internet, no registry (recommended)

For a single RKE2 box (e.g. one RHEL9 server), after
`sudo ./install-rke2-offline.sh --type server`:

```bash
cd /root/rke-hw
sudo ./deploy-app-offline.sh --no-registry
```

That's the whole thing. It:

1. reassembles + checksum-verifies the bundled image parts,
2. imports the app + Postgres images straight into RKE2's **containerd**
   (`ctr -n k8s.io images import`),
3. uses the **bundled Helm** to install the chart with
   `imagePullPolicy: Never` (so Kubernetes never tries to pull anything).

Then open it on the node IP:

```bash
source /etc/profile.d/rke2.sh
kubectl -n hello-db get pods         # both Running
#  http://<node-ip>:30080/
```

Remove it: `sudo ./deploy-app-offline.sh --uninstall`.

> Multi-node clusters: `--no-registry` imports onto **one** node only. For a
> real multi-node cluster use the registry path below (or re-run the import
> on every node).

---

# Multi-node path — via the private registry

Use this when you have several nodes. It assumes you finished
[`docs/two-server-setup.md`](two-server-setup.md) (RKE2 on the KUBE server,
registry on the REGISTRY server, KUBE trusts the registry).

## Step 0 (optional) — rebuild the bundled assets (computer WITH internet)

Only needed if you changed the app or want newer images — the assets are
already committed. To regenerate:

```bash
./scripts/build-app-assets.sh    # refills assets/app/, then commit it
```

---

## Step 1 — Push the images into your registry (on the KUBE server)

```bash
cd /root/rke-hw
sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000 --push-only
```

This reassembles the bundled image parts, loads them, and pushes
`hello-db-app` and `postgres` into your private registry. (The KUBE server
already trusts the registry from the two-server setup, so `podman push`
works.)

---

## Step 2 — Install the app with Helm (on the KUBE server)

```bash
sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000 --deploy-only
```

It uses the **bundled Helm binary** (no internet) to install the
`charts/hello-db` chart, pulling the images from your registry. It waits
until the pods are ready.

> Tip: you can do Step 1 + Step 2 in one go by omitting both
> `--push-only` and `--deploy-only`:
> `sudo ./deploy-app-offline.sh --registry 10.0.0.10:5000`

---

## Step 3 — Open the app

```bash
source /etc/profile.d/rke2.sh
kubectl -n hello-db get pods          # both should be Running
```

Then open a browser (or use curl) to **any cluster node IP on port 30080**:

```
http://10.0.0.20:30080/
```

You'll see the visit counter and guestbook. Type a message, click **Sign**,
refresh — it's stored in PostgreSQL inside the cluster. Refresh a few times
and watch the counter climb.

---

## Removing it

```bash
sudo ./deploy-app-offline.sh --uninstall
```

---

## Notes

* **Data is not persistent by default.** Postgres uses an `emptyDir`, so the
  guestbook resets if the Postgres pod restarts — fine for a demo. For
  durable storage, install a StorageClass and redeploy with
  `--set postgres.persistence.enabled=true` (edit the helm command in
  `deploy-app-offline.sh` or run helm yourself).
* **Change the DB password** for anything real:
  `helm upgrade ... --set postgres.password=<secret>`.
* All Helm options live in
  [`charts/hello-db/values.yaml`](../charts/hello-db/values.yaml).

## If something goes wrong

| Symptom | Fix |
|---|---|
| `ImagePullBackOff` | Registry not trusted/reachable from nodes — re-run the `install-registry-offline.sh --client-only` step, then `kubectl -n hello-db rollout restart deploy` |
| App pod `CrashLoopBackOff` | `kubectl -n hello-db logs deploy/hello-db-app` — usually Postgres still starting; it retries for ~60s |
| `helm: command not found` | Run `scripts/build-app-assets.sh` on a connected host so `assets/app/helm` exists, or pass `--helm /path/to/helm` |
| Can't reach `:30080` | firewalld on the node — open it: `sudo firewall-cmd --permanent --add-port=30080/tcp && sudo firewall-cmd --reload` |
