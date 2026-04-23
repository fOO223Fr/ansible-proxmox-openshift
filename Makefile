.DEFAULT_GOAL := help

EXTRA_VARS ?=
ANSIBLE_PLAYBOOK := ./venv/bin/ansible-playbook
RUN := $(ANSIBLE_PLAYBOOK) -e @./proxmox.yml -e @./overrides.yml $(EXTRA_VARS)

##@ General
.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Infrastructure (one-time per Proxmox host)
.PHONY: infra
infra: ## Create or update the shared infra VM (HAProxy, dnsmasq, registry, NAT)
	$(ANSIBLE_PLAYBOOK) -e @./proxmox.yml playbooks/infra.yml

.PHONY: cache
cache: ## Mirror OCP release images into infra VM registry (run once per OCP version)
	$(ANSIBLE_PLAYBOOK) -e @./proxmox.yml -e @./overrides.yml playbooks/cache.yml

##@ Cluster Lifecycle
.PHONY: install
install: ## Install OpenShift cluster (registers with infra VM, auto-allocates IPs/VMIDs/CIDRs)
	$(RUN) playbooks/install.yml

.PHONY: destroy
destroy: ## Destroy cluster VMs and deregister from infra VM
	$(RUN) playbooks/destroy.yml

.PHONY: storage
storage: ## Deploy post-install storage (local-path-provisioner as default StorageClass)
	$(RUN) playbooks/storage.yml

.PHONY: install-with-storage
install-with-storage: install storage ## Install cluster and provision storage in one step

.PHONY: add-disk
add-disk: ## Hot-add second raw disk to master VMs (DISK_SIZE=200 default, for TopoLVM/Ceph)
	$(RUN) -e "disk_size_gb=$(or $(DISK_SIZE),200)" playbooks/add-disk.yml

##@ Cluster Operations
.PHONY: start
start: ## Start all cluster VMs
	$(RUN) playbooks/start.yml

.PHONY: stop
stop: ## Stop all cluster VMs gracefully
	$(RUN) playbooks/stop.yml

.PHONY: status
status: ## Show cluster VM status
	$(RUN) playbooks/status.yml

.PHONY: console
console: ## Show cluster console URL and credentials
	@CLUSTER=$$(grep '^cluster_name:' overrides.yml | awk '{print $$2}'); \
	KUBECONFIG="./$${CLUSTER}-kubeconfig"; \
	if [ -f "$$KUBECONFIG" ]; then \
		OC=$$(if [ -f "./oc" ]; then echo "./oc"; else echo "oc"; fi); \
		export KUBECONFIG=$$KUBECONFIG; \
		echo "Console: $$($$OC whoami --show-console 2>/dev/null || echo 'not available yet')"; \
		echo "Username: kubeadmin"; \
		if [ -f "$${CLUSTER}-kubeadmin-password" ]; then \
			echo "Password: $$(cat $${CLUSTER}-kubeadmin-password)"; \
		fi; \
	else \
		echo "No kubeconfig found for cluster '$${CLUSTER}'. Run make install first."; \
	fi

.PHONY: approve-csrs
approve-csrs: ## Approve pending CSRs (useful for worker node joins)
	@CLUSTER=$$(grep '^cluster_name:' overrides.yml | awk '{print $$2}'); \
	OC=$$(if [ -f "./oc" ]; then echo "./oc"; else echo "oc"; fi); \
	export KUBECONFIG="./$${CLUSTER}-kubeconfig"; \
	$$OC get csr | grep Pending || echo "No pending CSRs"; \
	$$OC get csr -o name | xargs -r $$OC adm certificate approve 2>/dev/null || true

##@ Templates (snapshot-based fast restore)
.PHONY: template
template: ## Save running cluster as Proxmox templates
	$(RUN) playbooks/template.yml

.PHONY: restore
restore: ## Restore cluster from Proxmox templates (skips full install)
	$(RUN) playbooks/restore.yml

##@ Diagnostics
.PHONY: validate
validate: ## Run pre-flight checks (infra VM reachable, credentials valid, etc.)
	$(RUN) playbooks/validate.yml

.PHONY: disk-perf
disk-perf: ## Check disk performance on masters (etcd fsync latency)
	$(RUN) playbooks/disk-perf.yml

##@ Storage (ZFS volumes — for GPFS or manual block device use)
NUM_VOLUMES ?= 1
VOLUME_SIZE ?= 150
VOLUME_NAME ?=

.PHONY: zvol-add
zvol-add: ## Add shared ZFS volume(s) to workers. NUM_VOLUMES=N VOLUME_SIZE=GB
	$(RUN) -e "num_volumes=$(NUM_VOLUMES)" -e "zvol_size_gb=$(VOLUME_SIZE)" playbooks/zvol-add.yml

.PHONY: zvol-remove
zvol-remove: ## Remove a ZFS volume. VOLUME_NAME=<name>
	@if [ -z "$(VOLUME_NAME)" ]; then echo "Error: VOLUME_NAME required"; exit 1; fi
	$(RUN) -e "zvol_name=$(VOLUME_NAME)" playbooks/zvol-remove.yml

##@ Development
.PHONY: lint
lint: ## Run ansible-lint and yamllint
	./venv/bin/ansible-lint playbooks/*.yml roles/
	./venv/bin/yamllint .

.PHONY: deps
deps: ## Install Ansible dependencies (creates venv if needed)
	@if [ ! -d "venv" ]; then \
		echo "Creating virtual environment..."; \
		python3 -m venv venv; \
	fi
	@./venv/bin/pip install --upgrade pip -q
	@./venv/bin/pip install -r requirements.txt -q
	@./venv/bin/ansible-galaxy collection install -r requirements.yml
	@echo ""
	@echo "Dependencies installed. Quick start:"
	@echo "  1. cp proxmox.yml.example proxmox.yml   # fill in your Proxmox host details"
	@echo "  2. make infra                            # create shared infra VM (once per host)"
	@echo "  3. make cache                            # mirror OCP images (once per version)"
	@echo "  4. cp overrides.yml.example overrides.yml && edit  # set cluster name + sizing"
	@echo "  5. make install                          # deploy OpenShift"

.PHONY: clean-venv
clean-venv: ## Remove Python virtual environment
	@rm -rf venv
	@echo "Virtual environment removed"
