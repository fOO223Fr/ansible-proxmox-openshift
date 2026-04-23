# AGENTS.md

This file is a reference for AI agents and developers working in this repository.
It covers commands, conventions, and architecture to orient you quickly.

---

## 1. Common Commands

| Command | Description |
|---------|-------------|
| `make deps` | Install Python, Ansible, and collections into `venv/`. Run once after cloning or after changing `requirements.txt`/`requirements.yml`. |
| `make infra` | Create/configure the permanent shared infra VM (HAProxy, dnsmasq, NAT, registry). One-time per Proxmox host. |
| `make cache` | Mirror OCP release images into the infra VM registry. One-time per OCP version. |
| `make validate` | Pre-flight checks (Proxmox API, infra VM reachable, registry has images). |
| `make install` | Deploy an OpenShift cluster. Reads `proxmox.yml` + `overrides.yml`. |
| `make destroy` | Destroy cluster VMs and deregister from infra VM. |
| `make storage` | Deploy post-install storage (local-path-provisioner) on an existing cluster. |
| `make add-disk` | Hot-add a second raw disk to master VMs (for TopoLVM/Ceph). |
| `make start` | Start all cluster VMs. |
| `make stop` | Stop all cluster VMs gracefully. |
| `make status` | Show cluster VM status. |
| `make console` | Print cluster console URL and kubeadmin credentials. |
| `make lint` | Run `ansible-lint` and `yamllint`. |
| `make format` | Format with `black` and `yamllint`. |

---

## 2. Repository Layout

```
ansible-proxmox-openshift/
├── proxmox.yml.example      # Copy to proxmox.yml — Proxmox host + infra VM config
├── overrides.yml.example    # Copy to overrides.yml — per-cluster config
├── Makefile                 # All user-facing targets
├── ansible.cfg
├── requirements.yml         # Ansible collections
├── requirements.txt         # Python dependencies
│
├── inventory/
│   ├── hosts.yml            # Defines proxmox_host group
│   └── group_vars/all.yml   # All defaults (override in proxmox.yml / overrides.yml)
│
├── playbooks/
│   ├── infra.yml            # Create/configure shared infra VM
│   ├── install.yml          # Full cluster install
│   ├── destroy.yml          # Tear down cluster
│   ├── cache.yml            # Mirror OCP images
│   ├── storage.yml          # Post-install storage
│   ├── add-disk.yml         # Hot-add data disk to masters
│   └── validate.yml         # Pre-flight checks
│
└── roles/
    ├── infra/               # Infra VM: HAProxy, dnsmasq, NAT, registry, lifecycle
    ├── cluster/             # Cluster VM creation, ISO building, bootstrap monitoring
    ├── config/              # Post-install day-2 configuration
    ├── post-install-storage/ # local-path-provisioner, KubeletConfig
    └── validate/            # Pre-flight checks
```

---

## 3. Key Architecture Decisions

### Shared Infra VM
A single permanent Rocky Linux 9 VM (not destroyed between installs) provides:
- **HAProxy** — SNI-based TCP passthrough routing for API (:6443), ingress (:443/:80), MCS (:22623)
- **dnsmasq** — DNS + DHCP for the isolated cluster bridge (vmbr1)
- **iptables NAT** — cluster VMs use the infra VM as their internet gateway
- **OCP registry** — mirror (port 5000) + pull-through caches (5001–5004)

State is tracked in `/etc/infra/clusters.json` on the infra VM.

### Isolated Cluster Bridge (vmbr1)
Cluster VMs connect to an isolated Linux bridge (`vmbr1`) with no physical NIC.
The infra VM bridges this to the physical VLAN via NAT.
Benefits:
- Infra VM's dnsmasq is the **only** DHCP server — no race condition with router
- Cluster VMs are invisible to the physical network
- Each cluster gets its own `/24` machine network (satisfies Submariner requirements)

### Fully Automatic Resource Allocation
All VMIDs, IPs, MACs, pod CIDRs, and service CIDRs are allocated automatically
from the infra VM at install time. The only per-cluster config needed is sizing
and a name.

### OCP 4.21+ Workaround
OCP 4.21.0 has a bug in `openshift-apiserver-operator` where `audit-0` configmap
is not created on fresh installs, causing a circular deadlock. The bootstrap
monitoring loop (`monitor_bootstrap_tick.yml`) automatically applies the workaround.
See `roles/cluster/tasks/fix_openshift_apiserver_revision.yml` for details.

---

## 4. Style Conventions

- **Modules over shell**: use `ansible.builtin.*` and collection modules; only use
  `shell`/`command` when no module exists
- **Idempotent**: every task must be safe to run multiple times
- **No heredoc YAML in shell tasks**: use JSON (`printf '{"apiVersion":...}'`) to
  avoid Ansible YAML parser conflicts
- **Variable naming**: `_` prefix for internal task vars (`_alloc_free_ips`),
  no prefix for public vars (`bootstrap_ip`, `infra_ip`)
- **Debug messages**: use list format (`msg: [...]`), never dict format (renders as JSON)
- **Secrets**: `proxmox.yml` and `overrides.yml` are gitignored — never commit them

---

## 5. Testing Changes

```bash
# Syntax check all playbooks
for pb in playbooks/*.yml; do
  ./venv/bin/ansible-playbook -e @./proxmox.yml -e @./overrides.yml \
    --syntax-check "$pb"
done

# Lint
make lint

# Test infra idempotency (runs against live infra VM)
make infra  # should show 0 changes on second run
```
