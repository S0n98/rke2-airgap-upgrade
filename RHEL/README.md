# RKE2 Airgap Upgrade — RHEL / Rocky Linux / AlmaLinux

This folder contains documentation and scripts for upgrading an RKE2 cluster on **RHEL-family distributions** (RHEL 8/9, Rocky Linux 8/9, AlmaLinux 8/9) in an airgap environment.

## Why a separate guide?

RHEL-family systems differ from Ubuntu in four critical areas that must be addressed before RKE2 will function correctly:

| Area | Issue |
|---|---|
| **SELinux** | RKE2 requires the `rke2-selinux` policy RPM installed before the binary. Without it, containerd and pods are denied by MAC enforcement. |
| **firewalld** | RHEL enables firewalld by default. All RKE2 ports must be opened explicitly. |
| **NetworkManager** | `nm-cloud-setup.service` continuously rewrites routing tables, breaking CNI pod networking. It must be disabled. |
| **nm CNI isolation** | NetworkManager must be told to ignore virtual CNI interfaces (`cni0`, `vxlan.calico`, `cali*`, `veth*`). |

## Contents

| File / Directory | Description |
|---|---|
| `step-by-step.html` | Full interactive guide with all RHEL-specific procedures |
| `scripts/prepare-node.sh` | One-time node setup: kernel modules, sysctl, swap, NM config, SELinux policy |
| `scripts/open-firewall.sh` | Opens required firewalld ports for a server or agent node |
| `scripts/download-artifacts.sh` | Downloads RKE2 tarballs + `rke2-selinux` RPM on an internet machine |
| `scripts/upgrade-server.sh` | Upgrades a server node one step at a time (includes RHEL checks) |
| `scripts/upgrade-agent.sh` | Upgrades an agent node with cordon/drain gate |
| `scripts/post-upgrade-cleanup.sh` | Removes old data dirs, verifies SELinux labels, checks AVC denials |

## Quick start

```bash
# 1. Prepare every node (run once per node, before any RKE2 install)
sudo bash RHEL/scripts/prepare-node.sh \
  --selinux-rpm /path/to/rke2-selinux-0.19-1.el9.noarch.rpm

# 2. Open firewall ports
sudo bash RHEL/scripts/open-firewall.sh server   # on server nodes
sudo bash RHEL/scripts/open-firewall.sh agent    # on agent nodes

# 3. Download artifacts (internet-connected machine)
bash RHEL/scripts/download-artifacts.sh ./rke2-airgap 9   # 9 = RHEL major version

# 4. Transfer to airgap server
scp -r ./rke2-airgap/ admin@<server-ip>:/root/rke2-upgrade/

# 5. Install SELinux policy on each node FIRST
sudo rpm -ivh /root/rke2-upgrade/rke2-selinux-*.rpm

# 6. Upgrade server node — one version at a time
sudo bash RHEL/scripts/upgrade-server.sh v1.28.9+rke2r1   /root/rke2-upgrade
sudo bash RHEL/scripts/upgrade-server.sh v1.29.9+rke2r1   /root/rke2-upgrade
sudo bash RHEL/scripts/upgrade-server.sh v1.30.9+rke2r1   /root/rke2-upgrade
sudo bash RHEL/scripts/upgrade-server.sh v1.31.9+rke2r1   /root/rke2-upgrade
sudo bash RHEL/scripts/upgrade-server.sh v1.32.13+rke2r1  /root/rke2-upgrade

# 7. Upgrade agent nodes (from server: cordon/drain first, then on each agent)
sudo bash RHEL/scripts/upgrade-agent.sh v1.32.13+rke2r1 /root/rke2-upgrade

# 8. Post-upgrade cleanup
sudo bash RHEL/scripts/post-upgrade-cleanup.sh

```

## Supported distributions

| Distribution | RHEL major | Tested |
|---|---|---|
| RHEL 8.x | 8 | Compatible |
| RHEL 9.x | 9 | Compatible |
| Rocky Linux 8.x | 8 | Compatible |
| Rocky Linux 9.x | 9 | Compatible |
| AlmaLinux 8.x | 8 | Compatible |
| AlmaLinux 9.x | 9 | Compatible |
| CentOS Stream 9 | 9 | Compatible |

## Full guide

See [`step-by-step.html`](step-by-step.html) for the complete interactive runbook.

For Ubuntu / Debian environments, see the root-level [`rke2-airgap-upgrade-guide.html`](../rke2-airgap-upgrade-guide.html).
