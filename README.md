# RKE2 Airgap Upgrade — v1.27 → v1.32

Operational runbook and scripts for upgrading an RKE2 Kubernetes cluster in an **airgap (internet-isolated) environment**, verified on a production single-node cluster running Ubuntu 24.04.

## Completed upgrade

| | |
|---|---|
| **From** | `v1.27.13+rke2r1` (EOL) |
| **To** | `v1.32.13+rke2r1` (stable LTS) |
| **Path** | 1.27 → 1.28 → 1.29 → 1.30 → 1.31 → 1.32 |
| **Date** | 2026-11-22 |
| **OS** | Ubuntu 24.04.4 LTS |
| **Node** | Single-node: control-plane + etcd + master |

## Repository contents

| File | Description |
|---|---|
| `rke2-airgap-upgrade-guide.html` | Full interactive guide with step-by-step procedures for server and agent nodes |
| `scripts/download-artifacts.sh` | Downloads all required RKE2 tarballs on an internet-connected machine |
| `scripts/upgrade-server.sh` | Performs one upgrade step on a server node using local airgap artifacts |
| `scripts/upgrade-agent.sh` | Upgrades an agent (worker) node to the target version |
| `scripts/post-upgrade-cleanup.sh` | Removes old RKE2 data directories and reports disk reclaimed |
| `scripts/verify-services.sh` | Checks all service pods are Running post-upgrade |
| `pre-upgrade-state.txt` | Snapshot of pod state taken before the upgrade |

## Quick start

### 1. On an internet-connected machine — download artifacts

```bash
./scripts/download-artifacts.sh
# Outputs: ./rke2-airgap-artifacts/ (~1.7 GB)
```

### 2. Transfer to the airgap server

```bash
scp -r ./rke2-airgap-artifacts/ admin@<server-ip>:/root/rke2-upgrade/
```

### 3. On the server — upgrade step by step

```bash
# Repeat for each version: 1.28, 1.29, 1.30, 1.31, 1.32
./scripts/upgrade-server.sh v1.28.9+rke2r1 /root/rke2-upgrade
./scripts/upgrade-server.sh v1.29.9+rke2r1 /root/rke2-upgrade
./scripts/upgrade-server.sh v1.30.9+rke2r1 /root/rke2-upgrade
./scripts/upgrade-server.sh v1.31.9+rke2r1 /root/rke2-upgrade
./scripts/upgrade-server.sh v1.32.13+rke2r1 /root/rke2-upgrade
```

### 4. Verify all services

```bash
./scripts/verify-services.sh
```

### 5. Clean up old RKE2 data

```bash
./scripts/post-upgrade-cleanup.sh
```

## Important notes

- **One minor version at a time** — skipping minor versions is not supported
- **Disk space** — ensure ≥ 20 GB free before starting; each step uses ~300 MB
- **Custom images** — locally-built images may be evicted after a containerd major version upgrade; save them as tar archives and re-import with `ctr images import`
- **etcd snapshot** — always take a snapshot before each step (`rke2 etcd-snapshot save --name pre-upgrade-$(date +%Y%m%d)`)
- **Calico CNI** — this runbook assumes the cluster was installed with `cni: calico` in `/etc/rancher/rke2/config.yaml`. Confirm before upgrading: `grep cni /etc/rancher/rke2/config.yaml` should return `cni: calico`. Calico images are bundled in the RKE2 tarball (v1.30+) — no separate airgap download needed
- **Starting version** — this runbook was tested from `v1.27.13+rke2r1` (EOL, Calico CNI configured); if your starting version differs, verify the upgrade path at [rke2 releases](https://github.com/rancher/rke2/releases)

## Full guide

See [`rke2-airgap-upgrade-guide.html`](rke2-airgap-upgrade-guide.html) for the complete interactive runbook including rollback procedures, troubleshooting, and an upgrade checklist.
