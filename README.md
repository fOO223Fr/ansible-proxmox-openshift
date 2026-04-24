# ansible-proxmox-openshift

Deploy OpenShift clusters on Proxmox VE with a single command.
No static IPs. No MAC addresses. No VMID tracking. Just a cluster name and sizing.

```bash
make install   # full SNO or multi-node cluster, automatically configured
make destroy   # clean teardown, infra stays ready for the next install
```

---

## Motivation

Running OpenShift on bare metal (Proxmox) for homelab, development, or disaster
recovery testing should be as simple as it is on AWS or GCP. On cloud providers
you get:

- A load balancer automatically
- DNS automatically  
- A default StorageClass automatically
- No DHCP configuration
- No static IP management

This project brings the same experience to Proxmox. One config file per cluster
(just a name and node sizing), one command to install, one command to destroy.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Infra VM (permanent, shared across all clusters)           │
│  ─────────────────────────────────────────────────────────  │
│  HAProxy      SNI routing: api/:6443, ingress/:443/:80      │
│  dnsmasq      DNS + DHCP for isolated cluster bridge        │
│  iptables     NAT: cluster VMs → internet via infra VM      │
│  Registry     OCP mirror (port 5000) + pull-through caches  │
│               quay.io/:5001, registry.redhat.io/:5002        │
│               docker.io/:5003, registry.k8s.io/:5004         │
└──────────────────────┬──────────────────────────────────────┘
                       │ vmbrN (isolated Linux bridge, auto-created by make infra)
          ┌────────────┼────────────┐
          │            │            │
     hub-master-0  dr1-master-0  dr2-master-0
     10.0.1.11     10.0.2.11     10.0.3.11
```

Cluster VMs connect to an **isolated Linux bridge** (auto-discovered or created
by `make infra` — no manual setup needed) with no physical NIC. The bridge name
is persisted on the infra VM and reused across installs. The infra VM NATs
their internet traffic through the physical VLAN. The infra VM's dnsmasq is the
only DHCP server — no DHCP race condition with the router.

### What gets auto-allocated per cluster

| Resource | How |
|----------|-----|
| Machine IPs | dnsmasq DHCP reservations from `10.0.N.0/24` |
| MACs | Deterministic from cluster name (stable, reproducible) |
| VMIDs | First free IDs from configurable pool |
| Pod CIDR | `10.(128+N×4).0.0/14` — non-overlapping across clusters |
| Service CIDR | `172.(30+N).0.0/16` — non-overlapping across clusters |
| Machine network | `10.0.N.0/24` — unique per cluster (satisfies Submariner) |

---

## Prerequisites

- **Proxmox VE** (tested on 7.x and 8.x) with:
  - API token for the `ansible` user
  - SSH access from the Ansible controller
  - **No manual bridge setup needed** — `make infra` automatically finds the
    next unused `vmbrN` on the Proxmox host and creates it as an isolated
    internal bridge for cluster VMs. The bridge is added to
    `/etc/network/interfaces` with a comment matching your existing interface
    style and persisted for reuse.
- **OpenShift pull secret** from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret)
- **DNS** — add one forwarding rule in your DNS server (Pi-hole, Adguard, etc.):
  ```
  address=/yourdomain.local/INFRA_VM_IP
  ```
  That single entry handles all clusters forever.
- **Router** — one static DHCP reservation for the infra VM's MAC → `infra_ip`
- **Python 3.9+** and `make` on the Ansible controller

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/yourorg/ansible-proxmox-openshift.git
cd ansible-proxmox-openshift

# 2. Install dependencies
make deps

# 3. Configure Proxmox host + infra VM (one-time)
cp proxmox.yml.example proxmox.yml
# Edit proxmox.yml — fill in your Proxmox API credentials, infra VM IP, etc.

# 4. Create the shared infra VM (one-time per Proxmox host)
make infra

# 5. Add DNS forwarding rule in your DNS server:
#    address=/local.lab/<infra_ip>    (Pi-hole / dnsmasq format)
#    or: server=/local.lab/<infra_ip> (conditional forwarding format)

# 6. Mirror OCP images + sigstore signatures (one-time per OCP version, slow first time)
cp overrides.yml.example overrides.yml
# Set ocp_version in overrides.yml
make cache

# 7. Deploy your first cluster
# Edit overrides.yml — set cluster_name, master sizing, etc.
make install

# Access the cluster
export KUBECONFIG=hub-kubeconfig
oc get nodes
```

---

## Configuration

### `proxmox.yml` — Proxmox host + infra VM (gitignored, contains secrets)

```yaml
proxmox_api_host: 10.0.0.3          # Proxmox host IP
proxmox_node: pve                    # Proxmox node name
proxmox_api_user: root@pam
proxmox_api_token_id: ansible
proxmox_api_token_secret: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
proxmox_ssh_key: ~/.ssh/id_rsa

storage_pool: local-zfs             # Proxmox storage pool
network_bridge: vmbr0               # Physical bridge (VLAN-aware)
network_vlan: 420                   # VLAN tag for the OCP network
network_gateway: 192.168.1.1        # Your router
vlan_network_cidr: 192.168.1.0/24  # Physical VLAN subnet (for infra VM cloud-init)

infra_vmid: 110
infra_ip: 192.168.1.2              # Static IP for infra VM on physical VLAN
infra_vcpus: 2
infra_memory_mb: 4096
infra_disk_gb: 40                  # Root disk
infra_data_disk_gb: 200            # Registry data disk

# cluster_bridge is NOT required — make infra auto-discovers or creates the
# next available vmbrN on the Proxmox host and persists the choice.
# Uncomment only to force a specific bridge: cluster_bridge: vmbr2
infra_cluster_ip: "10.0.0.1"      # Infra VM's IP on the auto-created cluster bridge

vmid_pool_start: 200               # Cluster VMIDs auto-allocated from this range
vmid_pool_end: 999
```

### `overrides.yml` — per-cluster config (gitignored)

```yaml
cluster_name: hub                  # Unique lowercase name
cluster_base_domain: local.lab
ocp_version: "4.21.0"

ocp_pull_secret_file: ~/.tokens/pull-secret.txt
ocp_ssh_pubkey_file: ~/.ssh/id_rsa.pub

# Topology
master_count: 1       # 1=SNO, 3=compact/full
master_vcpus: 16
master_memory_mb: 65536
master_disk_gb: 256

worker_count: 0       # 0 for SNO or compact
# worker_vcpus: 8
# worker_memory_mb: 32768
# worker_disk_gb: 120

# Optional — auto-assigned if not set
# cluster_network_cidr: "10.128.0.0/14"
# service_network_cidr: "172.30.0.0/16"

# Optional — add raw disk for TopoLVM/Ceph (use with: make add-disk)
# master_data_disk_gb: 200
```

---

## Usage Scenarios

### Single Node OpenShift (SNO)

For homelab, development, or a hub cluster in an ACM multi-cluster setup:

```yaml
# overrides.yml
cluster_name: hub
master_count: 1
master_vcpus: 16
master_memory_mb: 65536
master_disk_gb: 256
worker_count: 0
```

```bash
make install
```

### Compact Cluster (3 masters, no workers)

For an HA control plane without dedicated workers (masters also serve workloads):

```yaml
master_count: 3
master_vcpus: 8
master_memory_mb: 32768
worker_count: 0
```

### Full HA Cluster (3 masters + N workers)

For production-like workloads with dedicated worker nodes:

```yaml
master_count: 3
master_vcpus: 8
master_memory_mb: 32768
worker_count: 3
worker_vcpus: 16
worker_memory_mb: 65536
worker_disk_gb: 200
```

### Multiple Clusters Side by Side

The infra VM handles multiple clusters simultaneously. Run `make install` with
different `cluster_name` values while other clusters are running:

```bash
# Terminal 1: hub cluster running
make install   # overrides.yml has cluster_name: hub

# Terminal 2: deploy dr1 while hub is running
sed -i 's/cluster_name: hub/cluster_name: dr1/' overrides.yml
make install
```

Each cluster gets unique IPs, CIDRs, DNS, and HAProxy backends automatically.

### Disaster Recovery Lab (ACM + Ramen)

This project is designed for multi-cluster DR patterns. Each cluster gets
non-overlapping pod, service, AND machine network CIDRs — satisfying both
ACM/Ramen validation and Submariner requirements:

| Cluster | Machine Network | Pod CIDR | Service CIDR |
|---------|----------------|----------|--------------|
| hub | 10.0.1.0/24 | 10.128.0.0/14 | 172.30.0.0/16 |
| dr1 | 10.0.2.0/24 | 10.132.0.0/14 | 172.31.0.0/16 |
| dr2 | 10.0.3.0/24 | 10.136.0.0/14 | 172.32.0.0/16 |

All CIDRs are auto-assigned — you don't need to track or configure them.

### Cluster with Ceph/ODF Storage

```bash
# Deploy cluster, then hot-add a raw disk to masters:
make add-disk DISK_SIZE=200

# The disk appears as /dev/sdb on each master (unformatted, ready for ODF)
# Then deploy Local Storage Operator + ODF manually or via ACM policy
```

### Snapshot and Fast Restore

```bash
make template    # Save running cluster as Proxmox templates
make restore     # Restore from templates (minutes instead of hours)
```

---

## Makefile Targets

```
Infrastructure (one-time per Proxmox host):
  make infra                  Create/configure shared infra VM
  make cache                  Mirror OCP images (once per OCP version)

Cluster Lifecycle:
  make install                Deploy cluster
  make destroy                Destroy cluster
  make storage                Deploy local-path-provisioner StorageClass
  make install-with-storage   Install + storage in one step
  make add-disk               Hot-add data disk to masters (DISK_SIZE=200)

Cluster Operations:
  make start                  Start all cluster VMs
  make stop                   Stop all cluster VMs
  make status                 Show VM status
  make console                Print console URL + credentials
  make approve-csrs           Approve pending worker node CSRs
  scripts/status.sh           Live dashboard: all clusters, operators, CVO %

Templates (fast restore):
  make template               Save cluster as Proxmox templates
  make restore                Restore cluster from templates

Development:
  make validate               Pre-flight checks
  make lint                   ansible-lint + yamllint
  make deps                   Install dependencies
```

---

## Output Files

After a successful install, the following files appear in the project root
(all gitignored):

```
hub-kubeconfig              # Use with: export KUBECONFIG=hub-kubeconfig
hub-kubeadmin-password      # kubeadmin password
hub-cluster-credentials.txt # Summary: console URL, API, username, password
```

---

## How It Works

### Install Flow

The install mode is selected automatically based on the cluster topology:

**SNO (`master_count: 1`) → Bootstrap-In-Place (BIP)** — official Red Hat SNO method.
No separate bootstrap VM. The single node boots the live ISO, installs RHCOS
directly to disk, and reboots as a fully running cluster.

**Multi-node (`master_count: 3+`) → UPI** — standard bare-metal UPI with a
temporary bootstrap VM that the master nodes contact for their ignition configs.

```
make install
  │
  ├── Detect install mode: SNO=BIP or multi-node=UPI
  ├── Check infra VM exists (fail if not: run make infra first)
  ├── register_cluster → allocate VMIDs, IPs, MACs, pod/service/machine CIDRs
  │   SNO: allocates master only (no bootstrap VM/IP/MAC)
  │   UPI: allocates bootstrap + masters + workers
  ├── Download OCP tools + RHCOS ISO (cached)
  │
  ├── [SNO/BIP] openshift-install create single-node-ignition-config
  │            → bootstrap-in-place-for-live-iso.ign (merged bootstrap+master)
  │   [UPI]    openshift-install create ignition-configs
  │            → bootstrap.ign + master.ign + worker.ign
  │
  ├── [SNO/BIP] coreos-installer iso ignition embed → ONE iso for master
  │   [UPI]    coreos-installer iso customize → per-node ISOs with DHCP
  │
  ├── Create VMs: [SNO] master only | [UPI] bootstrap + masters + workers
  │
  ├── [SNO/BIP] Monitor CVO + operator progress with live output (up to 90 min)
  │            Shows: API version, node status, operator counts, CVO %, waiting list
  │            Node reboots automatically after writing RHCOS to disk
  │   [UPI]    Monitor bootstrap with live output (up to 150 min)
  │            Shows: masters ready, etcd health, operator counts, bootstrap status
  │            Delete bootstrap VM after handoff
  │
  ├── Post-install day-2 config
  ├── Save credentials to project root
  └── Deploy local-path-provisioner as default StorageClass
```

### Infra VM Services

The infra VM is a permanent Rocky Linux 9 VM that runs:

- **HAProxy** — listens on the physical VLAN IP, routes by TLS SNI:
  - `:6443` → `api.<cluster>.<domain>` → master API
  - `:443` → `*.apps.<cluster>.<domain>` → ingress
  - `:22623` → MCS (bootstrap phase only)
  - `:9000` → HAProxy stats dashboard
- **dnsmasq** — authoritative DNS for your cluster domain + DHCP for cluster VMs
- **iptables MASQUERADE** — cluster VMs use infra VM as internet gateway
- **Podman containers** — OCP image registry (mirror + 4 pull-through caches)

---

## Known Issues

### RHCOS 9.6: Sigstore signature verification with mirror registries

**Symptom:** CVO pod stuck in `ImagePullBackOff` with `SignatureValidationFailed`.

**Root cause:** RHCOS 9.6 enforces sigstore signature verification for
`quay.io/openshift-release-dev/ocp-release` in `/etc/containers/policy.json`.
`oc adm release mirror` copies images but not the `.sig` sigstore artifact,
so CRI-O cannot verify the signature and rejects the pull.

**This project handles it automatically** in `cache_warmup.yml` by mirroring
both the release images and the `.sig` sigstore signature artifact to the
local registry, so CRI-O can verify signatures without reaching quay.io.

---

## Requirements

- Proxmox VE 7.x or 8.x
- OpenShift 4.19–4.21 (tested on 4.21.10 SNO and multi-node)
- Rocky Linux 9 (for infra VM, downloaded automatically)
- Python 3.9+ on Ansible controller
- Ansible 2.15+

```
# requirements.yml (installed via make deps)
collections:
  - community.general
  - community.proxmox
  - community.crypto
  - kubernetes.core
  - ansible.posix
  - containers.podman
```

---

## Contributing

Pull requests welcome. Please:
- Run `make lint` before submitting
- Keep tasks idempotent
- Prefer modules over `shell`/`command`
- Never use heredoc YAML in shell tasks (use JSON with `printf` instead — avoids
  Ansible YAML parser conflicts)
- Test with both SNO and compact topologies if modifying cluster creation

---

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE) for details.
