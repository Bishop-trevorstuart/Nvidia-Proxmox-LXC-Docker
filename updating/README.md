# NVIDIA GPU Update Script (Proxmox + LXC + Docker)

Updates NVIDIA drivers across:

* Proxmox host
* GPU-enabled LXC containers
* Docker runtime inside those containers

---

## What it does

* Detects latest NVIDIA driver version
* Upgrades host driver (`.run + DKMS`)
* Ensures `/dev/nvidia-uvm` exists
* Updates user-space driver inside GPU-enabled LXCs
* Reconfigures NVIDIA container runtime
* Validates Docker GPU access (`--gpus all`)

---

## Requirements

* NVIDIA driver already working on host
* LXC GPU passthrough already configured
* Docker + NVIDIA container toolkit installed in LXC

---

## Run
# Get script (choose one)

# Option 1: clone repo
git clone https://github.com/Bishop-trevorstuart/Nvidia-Proxmox-LXC-Docker.git

# Option 2: download directly
wget https://raw.githubusercontent.com/Bishop-trevorstuart/Nvidia-Proxmox-LXC-Docker/main/updating/nvidia-upgrade.sh

```bash
chmod +x nvidia-upgrade.sh
./nvidia-upgrade.sh
```

---

## Container Detection

Containers are detected by scanning LXC configs for GPU devices:

* `/dev/nvidia0`
* `/dev/nvidia-uvm`

If a container is not detected, verify GPU passthrough exists in:

```bash
/etc/pve/nodes/<node>/lxc/<CTID>.conf
```

---

## What it guarantees

After completion:

* `/dev/nvidia-uvm` exists on host
* NVIDIA driver is updated
* Docker GPU works (`gpus: all`)
* Containers can use CUDA

---

## Quick Validation

Run these if needed:

```bash
ls -l /dev/nvidia-uvm
```

```bash
docker run --rm --gpus all nvidia/cuda:12.6.1-base-ubuntu24.04 nvidia-smi
```

---

## Notes

* Uses `.run` installer for consistency across Proxmox + mixed LXC OS
* Does NOT modify LXC configs
* Does NOT manage application containers
* UVM is automatically ensured during upgrade
Safe check
DRY_RUN=true ./nvidia-upgrade.sh
Normal (safe mode)
./nvidia-upgrade.sh

👉 Will refuse if GPU in use

Forced full upgrade + restore
./nvidia-upgrade.sh --force

👉 Will:

stop compose stacks
upgrade driver
bring compose stacks back up