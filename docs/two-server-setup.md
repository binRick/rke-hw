# Two-server air-gapped setup (registry + RKE2 on separate servers)

A step-by-step guide for an admin who has **never done this before**.
No internet on the two servers. Just follow the steps in order.

## What you are building

| Name in this guide | What it does                | Example IP   |
|--------------------|-----------------------------|--------------|
| **REGISTRY server**| Stores your container images| `10.0.0.10`  |
| **KUBE server**    | Runs RKE2 / Kubernetes      | `10.0.0.20`  |

> Replace `10.0.0.10` and `10.0.0.20` with your real IPs **everywhere** below.
> Type the commands exactly; lines starting with `sudo` need admin rights.

---

## Step 0 — One-time prep (on ANY computer WITH internet)

You only do this once, to fill the `assets/` folder.

1. On an internet-connected machine, get this project folder.
2. Open a terminal in the project folder and run:
   ```bash
   ./scripts/fetch-assets.sh
   ```
   Wait for it to finish (`assets/ populated`).
3. Copy the **whole project folder** (with the now-full `assets/`) onto a
   USB stick or share it to **both** servers — e.g. into `/root/rke-hw`
   on each. Both servers must have an identical copy.

You are now done with the internet. Everything below is offline.

---

## Step 1 — Install Kubernetes (on the KUBE server, `10.0.0.20`)

Log in to the KUBE server. Go into the project folder and run:

```bash
cd /root/rke-hw
sudo ./install-rke2-offline.sh --type server --disable-firewalld
```

Wait until you see **`Kubernetes API is ready.`** and a node listed.
Kubernetes is now running. (It does **not** need the registry to start.)

Check it works:
```bash
source /etc/profile.d/rke2.sh
kubectl get nodes
```
You should see one node with status `Ready`.

---

## Step 2 — Install the registry (on the REGISTRY server, `10.0.0.10`)

Log in to the REGISTRY server.

1. Make sure `podman` is installed:
   ```bash
   podman --version
   ```
   If that prints a version, good. If it says "command not found", you must
   install podman (do this on a connected machine / from your OS DVD — RHEL
   and Rocky normally include it by default).

2. Go into the project folder and start the registry:
   ```bash
   cd /root/rke-hw
   sudo ./install-registry-offline.sh \
        --host 10.0.0.10 \
        --no-registries-yaml \
        --open-firewall
   ```
   (`--no-registries-yaml` is used here because this server is **not** a
   Kubernetes node — it only hosts images.)

3. When it finishes, it prints a line like
   **`CA for other nodes: /etc/airgap-registry/certs/registry.crt`**.
   That file is the "trust certificate" the KUBE server needs next.

---

## Step 3 — Give the KUBE server the trust certificate

Copy the file `/etc/airgap-registry/certs/registry.crt` **from the REGISTRY
server to the KUBE server**. Easiest way, run this **on the KUBE server**:

```bash
scp root@10.0.0.10:/etc/airgap-registry/certs/registry.crt /root/registry.crt
```

(If `scp` is blocked, copy it with a USB stick — any method is fine, the file
is small and not secret.)

---

## Step 4 — Point Kubernetes at the registry (on the KUBE server)

Still on the KUBE server:

```bash
cd /root/rke-hw
sudo ./install-registry-offline.sh --client-only \
     --host 10.0.0.10 \
     --ca /root/registry.crt \
     --restart-rke2
```

This tells Kubernetes "trust the registry at `10.0.0.10:5000` and pull
images from it". Done — the two servers are now connected.

---

## Step 5 — Test it end to end

You need one application image as a `.tar` file (made earlier with
`podman save myapp:1.0 -o myapp.tar` on a build machine).

**On the REGISTRY server**, put the image into the registry:
```bash
podman load -i myapp.tar
podman tag  myapp:1.0 10.0.0.10:5000/myapp:1.0
podman push 10.0.0.10:5000/myapp:1.0
```

**On the KUBE server**, run it:
```bash
source /etc/profile.d/rke2.sh
kubectl create deployment myapp --image=10.0.0.10:5000/myapp:1.0
kubectl get pods -w
```
When the pod reaches `Running`, the whole air-gapped setup works. 🎉

---

## If something goes wrong

| Symptom | Where | Fix |
|---|---|---|
| `ImagePullBackOff` on a pod | KUBE | Re-check Step 4 ran with the right `--host` IP, then `sudo systemctl restart rke2-server` |
| `connection refused` to `:5000` | REGISTRY | Firewall: `sudo firewall-cmd --permanent --add-port=5000/tcp && sudo firewall-cmd --reload` |
| Registry won't start | REGISTRY | `journalctl -u airgap-registry -f` and check `podman --version` exists |
| Want to start over (registry) | REGISTRY | `sudo ./install-registry-offline.sh --uninstall` |
| Want to start over (Kubernetes) | KUBE | `sudo ./install-rke2-offline.sh --uninstall` |

Full option lists: `./install-rke2-offline.sh --help` and
`./install-registry-offline.sh --help`.
