SHELL         := /bin/bash
.DEFAULT_GOAL := help

# ── Paths ────────────────────────────────────────────────────────
VM_DIR        := vm
BASE_IMAGE    := $(VM_DIR)/centos9-base.qcow2
FIPS_IMAGE    := $(VM_DIR)/centos9-fips.qcow2
VM_DISK       := $(VM_DIR)/vm-disk.qcow2
SEED_ISO      := $(VM_DIR)/seed.iso
SSH_KEY       := $(VM_DIR)/vm_key
PID_FILE      := $(VM_DIR)/vm.pid
CONSOLE_LOG   := $(VM_DIR)/console.log
CI_DIR        := $(VM_DIR)/ci

# ── Settings ─────────────────────────────────────────────────────
IMAGE_URL     := https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2
SSH_PORT      := 2222
VM_RAM        := 4G
VM_CPUS       := 2

# ── Derived ──────────────────────────────────────────────────────
SSH_OPTS      := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
SSH           := ssh $(SSH_OPTS) -i $(SSH_KEY) -p $(SSH_PORT) test@localhost
SCP           := scp $(SSH_OPTS) -i $(SSH_KEY) -P $(SSH_PORT)
KVM_FLAGS     := $(shell [ -w /dev/kvm ] && echo "-enable-kvm -cpu host")
QEMU          := qemu-system-x86_64 $(KVM_FLAGS) -m $(VM_RAM) -smp $(VM_CPUS) \
                   -netdev user,id=net0,hostfwd=tcp::$(SSH_PORT)-:22 \
                   -device virtio-net-pci,netdev=net0 -nographic

define wait_ssh # (label, max_attempts)
	@echo "$(1)"; \
	for i in $$(seq 1 $(2)); do \
		$(SSH) true 2>/dev/null && break; \
		[ $$i -eq $(2) ] && { echo "ERROR: timed out"; exit 1; }; \
		sleep 5; \
	done; \
	echo "  VM is reachable."
endef

define assert_running
	@if [ ! -f $(PID_FILE) ] || ! kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "VM not running. Run 'make start' first."; \
		exit 1; \
	fi
endef

# ── Phony targets ────────────────────────────────────────────────
.PHONY: help start stop restart ssh status cache build test console clean clean-all

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "VM lifecycle:"
	@echo "  start      Boot the FIPS VM (creates images on first run)"
	@echo "  stop       Graceful shutdown"
	@echo "  restart    Stop + start"
	@echo "  ssh        Interactive shell into the running VM"
	@echo "  status     Show VM state, FIPS flag, and disk usage"
	@echo "  console    Tail the VM console log"
	@echo ""
	@echo "Build:"
	@echo "  cache      Build image locally and load into VM"
	@echo "  build      Run mod build on VM via podman run (FIPS)"
	@echo "  test       Full cycle: start → cache → build → stop"
	@echo ""
	@echo "Cleanup:"
	@echo "  clean      Remove work disk (keep cached base images)"
	@echo "  clean-all  Remove everything (base image, FIPS image, keys)"
	@echo ""
	@echo "Settings (override via env or command line):"
	@echo "  VM_RAM=$(VM_RAM)  VM_CPUS=$(VM_CPUS)  SSH_PORT=$(SSH_PORT)"

# ── Image creation (file targets, cached) ────────────────────────

$(BASE_IMAGE):
	@mkdir -p $(VM_DIR)
	@echo "Downloading CentOS Stream 9 cloud image (~1.8 GB)..."
	curl -L "$(IMAGE_URL)" -o $@

$(SSH_KEY):
	@mkdir -p $(VM_DIR)
	ssh-keygen -t ecdsa -b 384 -f $@ -N "" -q

$(SEED_ISO): $(SSH_KEY)
	@mkdir -p $(CI_DIR)
	@echo 'instance-id: fips-test'  > $(CI_DIR)/meta-data
	@echo 'local-hostname: fips-test' >> $(CI_DIR)/meta-data
	@printf '%s\n' \
		'#cloud-config' \
		'users:' \
		'  - name: test' \
		'    sudo: ALL=(ALL) NOPASSWD:ALL' \
		'    shell: /bin/bash' \
		'    lock_passwd: false' \
		'    ssh_authorized_keys:' \
		"      - $$(cat $(SSH_KEY).pub)" \
		'packages:' \
		'  - podman' \
		'  - crypto-policies-scripts' \
		> $(CI_DIR)/user-data
	cloud-localds $@ $(CI_DIR)/user-data $(CI_DIR)/meta-data

$(FIPS_IMAGE): $(BASE_IMAGE) $(SEED_ISO)
	@echo ""; echo "Creating FIPS base image (one-time setup)..."
	@qemu-img create -f qcow2 -b $$(realpath $(BASE_IMAGE)) -F qcow2 $@ 20G >/dev/null
	@$(QEMU) \
		-drive file=$@,format=qcow2,if=virtio \
		-drive file=$(SEED_ISO),format=raw,if=virtio \
		> $(CONSOLE_LOG) 2>&1 & \
	echo $$! > $(PID_FILE); \
	echo "  Setup VM PID: $$(cat $(PID_FILE))"
	$(call wait_ssh,  Waiting for first boot...,90)
	@echo "  Enabling FIPS..."
	@$(SSH) "sudo fips-mode-setup --enable < /dev/null" > /dev/null 2>&1
	@echo "  Rebooting for FIPS activation..."
	@$(SSH) "sudo reboot" 2>/dev/null || true
	@sleep 15
	$(call wait_ssh,  Waiting for FIPS boot...,90)
	@FIPS=$$($(SSH) "cat /proc/sys/crypto/fips_enabled"); \
	if [ "$$FIPS" != "1" ]; then \
		echo "ERROR: FIPS not active after reboot"; \
		kill $$(cat $(PID_FILE)) 2>/dev/null; rm -f $@ $(PID_FILE); exit 1; \
	fi; \
	echo "  FIPS verified. Shutting down..."
	@$(SSH) "sudo poweroff" 2>/dev/null || true
	@wait $$(cat $(PID_FILE)) 2>/dev/null || true
	@rm -f $(PID_FILE)
	@echo "  FIPS base image ready."

# ── VM lifecycle ─────────────────────────────────────────────────

start: $(FIPS_IMAGE) $(SEED_ISO)
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "VM already running (PID $$(cat $(PID_FILE)))"; \
	else \
		for i in $$(seq 1 10); do \
			ss -tlnp 2>/dev/null | grep -q ':$(SSH_PORT) ' || break; \
			[ $$i -eq 10 ] && { echo "ERROR: port $(SSH_PORT) still in use"; exit 1; }; \
			sleep 1; \
		done; \
		rm -f $(VM_DISK); \
		qemu-img create -f qcow2 -b $$(realpath $(FIPS_IMAGE)) -F qcow2 $(VM_DISK) 20G >/dev/null; \
		$(QEMU) \
			-drive file=$(VM_DISK),format=qcow2,if=virtio \
			-drive file=$(SEED_ISO),format=raw,if=virtio \
			> $(CONSOLE_LOG) 2>&1 & \
		echo $$! > $(PID_FILE); \
		echo "VM starting (PID $$(cat $(PID_FILE)))..."; \
	fi
	$(call wait_ssh,Waiting for boot...,90)
	@echo "FIPS: $$($(SSH) 'cat /proc/sys/crypto/fips_enabled')"

stop:
	@PID=""; \
	if [ -f $(PID_FILE) ]; then \
		PID=$$(cat $(PID_FILE)); \
		kill -0 $$PID 2>/dev/null || PID=""; \
	fi; \
	if [ -z "$$PID" ]; then \
		PID=$$(lsof -ti :$(SSH_PORT) 2>/dev/null | head -1) || true; \
	fi; \
	if [ -z "$$PID" ]; then \
		echo "VM not running."; rm -f $(PID_FILE); exit 0; \
	fi; \
	echo "Stopping VM (PID $$PID)..."; \
	$(SSH) "sudo poweroff" 2>/dev/null || true; \
	for i in $$(seq 1 30); do \
		kill -0 $$PID 2>/dev/null || break; \
		sleep 1; \
	done; \
	kill -0 $$PID 2>/dev/null && kill $$PID 2>/dev/null; \
	rm -f $(PID_FILE); \
	echo "VM stopped."

restart: stop start

ssh:
	$(assert_running)
	@$(SSH)

status:
	@echo "── VM ──"
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "  state: running (PID $$(cat $(PID_FILE)))"; \
		echo "  fips:  $$($(SSH) 'cat /proc/sys/crypto/fips_enabled' 2>/dev/null || echo 'unreachable')"; \
		echo "  ssh:   ssh $(SSH_OPTS) -i $(SSH_KEY) -p $(SSH_PORT) test@localhost"; \
	else \
		echo "  state: stopped"; \
	fi
	@echo "── Images ──"
	@for f in $(BASE_IMAGE) $(FIPS_IMAGE) $(VM_DISK); do \
		if [ -f "$$f" ]; then \
			printf "  %-40s %s\n" "$$f" "$$(du -h "$$f" | cut -f1)"; \
		else \
			printf "  %-40s %s\n" "$$f" "(absent)"; \
		fi; \
	done

console:
	@if [ -f $(CONSOLE_LOG) ]; then \
		tail -f $(CONSOLE_LOG); \
	else \
		echo "No console log. Start the VM first."; \
	fi

# ── Build / test ─────────────────────────────────────────────────

BASE_TAR := $(VM_DIR)/mod-build-base.tar

cache: $(BASE_TAR)
	$(assert_running)
	@LOCAL_ID=$$(docker inspect mod-build-base --format '{{.Id}}' 2>/dev/null); \
	REMOTE_ID=$$($(SSH) "podman inspect mod-build-base --format '{{.Id}}' 2>/dev/null" 2>/dev/null); \
	if [ -n "$$LOCAL_ID" ] && [ "$$LOCAL_ID" = "$$REMOTE_ID" ]; then \
		echo "Image already up to date on VM ($$LOCAL_ID)."; \
	else \
		echo "Loading base image into VM..."; \
		$(SCP) $(BASE_TAR) test@localhost:/tmp/mod-build-base.tar >/dev/null; \
		$(SSH) "podman load -i /tmp/mod-build-base.tar && rm -f /tmp/mod-build-base.tar"; \
		echo "Base image cached in VM."; \
	fi

$(BASE_TAR): Dockerfile $(wildcard repos/**/*)
	@echo "Building base image locally..."
	docker build -t mod-build-base .
	@echo "Saving base image..."
	docker save mod-build-base -o $@
	@echo "Saved: $@ ($$(du -h $@ | cut -f1))"

build:
	$(assert_running)
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  mod build /repos   (FIPS-enabled host via podman run)"
	@echo "════════════════════════════════════════════════════════════"
	@echo ""
	@$(SSH) "podman run --rm mod-build-base mod build /repos"
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  BUILD SUCCEEDED under kernel FIPS mode"
	@echo "════════════════════════════════════════════════════════════"

test: start cache build stop

# ── Cleanup ──────────────────────────────────────────────────────

clean: stop
	rm -f $(VM_DISK) $(CONSOLE_LOG) $(BASE_TAR)

clean-all: stop
	rm -f $(VM_DISK) $(FIPS_IMAGE) $(BASE_IMAGE) $(SEED_ISO) $(BASE_TAR)
	rm -f $(SSH_KEY) $(SSH_KEY).pub $(PID_FILE) $(CONSOLE_LOG)
	rm -rf $(CI_DIR)
