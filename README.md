# Nvidia GPU → Proxmox Host → Unprivileged LXC → Docker

Full GPU passthrough for **any CUDA-capable workload** inside Docker running in an unprivileged LXC.

Tested: Proxmox 9 / Debian Bookworm
Applies to: any NVIDIA GPU

---

## Summary (Read First)

* Host owns NVIDIA kernel driver and devices
* LXC installs **user-space driver only**
* Docker exposes GPU to containers
* **`no-cgroups = true` is REQUIRED for unprivileged LXC**
* **`/dev/nvidia-uvm` MUST exist or CUDA workloads fail**

Docker GPU access is provided via NVIDIA Container Toolkit, which dynamically exposes devices and driver libraries at runtime ([NVIDIA Developer][2])

---

# 1. PROXMOX HOST SETUP

## Install prerequisites

```bash
apt install -y dkms pve-headers build-essential libvulkan1
```

---

## Disable nouveau

```bash
cat <<EOF > /etc/modprobe.d/blacklist-nvidia-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF

update-initramfs -u
reboot
```

---

## Install NVIDIA driver (.run method)

> NVIDIA recommends package-managed installs where possible.
> This guide uses `.run` for consistency across Proxmox and mixed LXC environments.

```bash
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/580.105.08/NVIDIA-Linux-x86_64-580.105.08.run
chmod +x NVIDIA-Linux-x86_64-580.105.08.run

./NVIDIA-Linux-x86_64-580.105.08.run --dkms
```

Selections:

* No 32-bit
* No X
* DKMS = YES

---

## Verify driver

```bash
dkms status
nvidia-smi
```

---

## CRITICAL: Ensure required kernel modules are loaded

```bash
# REQUIRED for CUDA workloads (creates /dev/nvidia-uvm)
modprobe nvidia_uvm
```

Optional (safe but not required):

```bash
modprobe nvidia
modprobe nvidia_modeset
modprobe nvidia_drm
```

---

## Enable persistence (recommended)

```bash
cat <<EOF > /etc/systemd/system/nvidia-persistenced.service
[Unit]
Description=NVIDIA Persistence Daemon
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/nvidia-persistenced --user root
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nvidia-persistenced
```

---

# 2. LXC CONFIG (DO BEFORE STARTING CONTAINER)

## Generate GPU passthrough config

```bash
# Ensure required devices exist BEFORE generation
modprobe nvidia_uvm

echo "lxc.cgroup2.devices.allow: c 226:* rwm"
echo "lxc.cgroup2.devices.allow: c 195:* rwm"
echo "lxc.cgroup2.devices.allow: c 509:* rwm"
echo "lxc.cgroup2.devices.allow: c 234:* rwm"

echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"

ls -l /dev/nvidia* | awk '/^crw/ {
  dev=$NF; gsub(/.*\//,"",dev);
  print "lxc.mount.entry: /dev/"dev" dev/"dev" none bind,optional,create=file"
}'
```

Copy output into:

```
/etc/pve/nodes/pve/lxc/<CTID>.conf
```

---

## REQUIRED DEVICES (must exist)

```
/dev/nvidia0
/dev/nvidiactl
/dev/nvidia-modeset
/dev/nvidia-uvm
/dev/nvidia-uvm-tools
/dev/dri
```

### Critical rule

* Missing `/dev/nvidia-uvm` → Docker GPU fails
* Even if `nvidia-smi` works

---

# 3. INSIDE THE LXC

## Install base packages

```bash
apt install -y libvulkan1 curl gpg
```

---

## Install NVIDIA (user-space only)

```bash
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/580.105.08/NVIDIA-Linux-x86_64-580.105.08.run
chmod +x NVIDIA-Linux-x86_64-580.105.08.run

./NVIDIA-Linux-x86_64-580.105.08.run --no-kernel-module
```

---

## Install NVIDIA container toolkit

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update

apt install -y \
  nvidia-container-toolkit \
  nvidia-container-toolkit-base \
  libnvidia-container-tools \
  libnvidia-container1
```

---

## CRITICAL: Required for unprivileged LXC

```bash
sed -i 's/^#\?no-cgroups.*/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml
```

* MUST be set before configuring runtime
* Required due to LXC cgroup limitations

---

## Configure Docker runtime

```bash
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
```

---

## Verify runtime

```bash
docker info | grep -i runtime
```

---

# 4. VALIDATION (ALL LAYERS)

## Host

```bash
nvidia-smi
```

## LXC

```bash
nvidia-smi
```

## Docker

```bash
docker run --gpus all nvidia/cuda:12.6.1-base-ubuntu24.04 nvidia-smi
```

---

# 5. DOCKER GPU STANDARD

Use:

```
gpus: all
```

Fallback only:

```
runtime: nvidia
```

Do not mix arbitrarily.

GPU selection is handled via Docker/NVIDIA runtime (`--gpus`) or `NVIDIA_VISIBLE_DEVICES` ([NVIDIA Docs][3])

---

# 6. IMPORTANT NOTES

* Do NOT install kernel modules inside LXC
* Driver versions should match host + LXC
* Always generate LXC config dynamically
* `/dev/nvidia-uvm` is required for CUDA
* `no-cgroups = true` is mandatory
* Docker automatically mounts required NVIDIA driver libraries

---

# 7. AFTER UPDATES / REBOOTS

If GPU fails:

```bash
modprobe nvidia_uvm
```

Verify:

```bash
ls -l /dev/nvidia-uvm
```

---

# FINAL STATE

Working system must have:

* GPU visible on host
* GPU visible in LXC
* Docker `--gpus all` works
* Containers can use CUDA

---