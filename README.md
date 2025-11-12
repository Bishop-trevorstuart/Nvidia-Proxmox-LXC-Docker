# NvidiaGPU in Proxmox Host then unprivileged LXC and finally available to Docker

Nvidia in Proxmox LXC or any other LXC under Linux, specifically Debian in this example.

This guide is based on Debian Bookworm and/or Proxmox 8.  
I'm not the original author—see fork/references below!

Inspired by:  
* https://github.com/gma1n/LXC-JellyFin-GPU  
* https://developer.nvidia.com/cuda-downloads?target_os=Linux&target_arch=x86_64&Distribution=Debian&target_version=12&target_type=deb_network  
* https://docs.nvidia.com/cuda/cuda-installation-guide-linux/#meta-packages  
* https://catalog.ngc.nvidia.com/orgs/nvidia/containers/tensorflow  
* https://github.com/NVIDIA/libnvidia-container/issues/176  
* https://gist.github.com/MihailCosmin/affa6b1b71b43787e9228c25fe15aeba  
* https://sluijsjes.nl/2024/05/18/coral-and-nvidia-passthrough-for-proxmox-lxc-to-install-frigate-video-surveillance-server/  
* https://stackoverflow.com/questions/8223811/a-top-like-utility-for-monitoring-cuda-activity-on-a-gpu  
* https://forum.proxmox.com/threads/nvidia-drivers-instalation-proxmox-and-ct.156421/  
* https://hostbor.com/gpu-passthrough-in-lxc-containers/  

---

## Check for IOMMU

```bash
dmesg | grep IOMMU
```
Should result in something like:

```
[    0.554887] pci 0000:00:00.2: AMD-Vi: IOMMU performance counters supported  
[    0.560664] pci 0000:00:00.2: AMD-Vi: Found IOMMU cap 0x40  
[    0.560961] perf/amd_iommu: Detected AMD IOMMU #0 (2 banks, 4 counters/bank).
```
If you get nothing, check your BIOS.

---

## HOST Debian/Proxmox setup

**Install required packages. This will future-proof for DKMS + all kernel upgrades.**

```bash
apt install -y dkms pve-headers build-essential libvulkan1
```
> **Note:** The `pve-headers` meta-package keeps headers for the newest kernel automatically installed after upgrades.  
> Use `pve-headers-$(uname -r)` only if you are running an older kernel, but usually this is not needed.

_For Debian (not Proxmox):_
```bash
sudo apt install -y dkms linux-headers build-essential libvulkan1
```

---

### Blacklist nouveau

```bash
# Blacklist nouveau driver (required before NVIDIA driver installation)
# The open-source nouveau driver conflicts with the NVIDIA proprietary driver and must be disabled before installation.
bash -c "echo blacklist nouveau > /etc/modprobe.d/blacklist-nvidia-nouveau.conf"
bash -c "echo options nouveau modeset=0 >> /etc/modprobe.d/blacklist-nvidia-nouveau.conf"

# Verify the configuration
cat /etc/modprobe.d/blacklist-nvidia-nouveau.conf

# Update initramfs to apply changes
update-initramfs -u
```
REBOOT

---

## Nvidia Driver

### Download and install the latest version—check for your card at https://www.nvidia.com/en-us/drivers/unix/

```bash
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/580.105.08/NVIDIA-Linux-x86_64-580.105.08.run
# Optional: Verify download integrity (checksum available on NVIDIA website)
# sha256sum NVIDIA-Linux-x86_64-580.105.08.run

# Make installer executable
chmod +x NVIDIA-Linux-x86_64-580.105.08.run

# Install driver with DKMS support
./NVIDIA-Linux-x86_64-580.105.08.run --dkms
```
The installer has a few prompts. Skip secondary cards, No 32 bits, No X. Near end will ask about register kernel module sources with dkms - **YES**.

---

### Verify DKMS status

```bash
dkms status
# Should show: nvidia, 580.105.08, <kernel-version>: installed
```
> If not present, repeat the installer after confirming both `pve-headers` and `dkms` are installed.

---

## [Optional, but HIGHLY recommended on HOST] Persistent Mode (Across Reboots)

[NVIDIA Official Reference](https://docs.nvidia.com/deploy/driver-persistence/index.html)  
Ensures your GPU remains initialized and responsive across reboots—**critical for Proxmox, LXC, and Docker GPU workflows**.

1. **Create or overwrite `/etc/systemd/system/nvidia-persistenced.service` with:**

```
[Unit]
Description=NVIDIA Persistence Daemon
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/nvidia-persistenced --user root
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

2. **Register, enable, and start the service:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nvidia-persistenced
sudo systemctl status nvidia-persistenced
```

3. **Result:** Persistence mode will now survive *all* reboots automatically.

> **Note:** No need for manual `nvidia-smi --persistence-mode=1`.  
> Use `systemctl` to manage or check the daemon.

---

## Test the driver is working (you only need to do one of the below tests)

### You can do this same test inside the LXC to confirm the driver install is good there too!

This will loop and call the view at every second.
```bash
nvidia-smi -l 1
```
If you do not want to keep past traces of the looped call in the console history, you can also do:
```bash
# Where 0.1 is the time interval, in seconds.
watch -n0.1 nvidia-smi
```

---

## Add the output of this command to your LXC config file (/etc/pve/nodes/pve/lxc/xxx.conf)

```bash
ls -l /dev/nv* |grep -v nvme | grep crw | sed -e 's/.*root root\s*\(.*\),.*\/dev\/\(.*\)/lxc.cgroup2.devices.allow: c \1:* rwm\nlxc.mount.entry: \/dev\/\2 dev\/\2 none bind,optional,create=file/g'
```
Should look something like this (While you CAN copy/paste the output of the above command, Do not blindly copy the below):
```
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:1 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.cgroup2.devices.allow: c 195:0 rwm
lxc.cgroup2.devices.allow: c 195:255 rwm
lxc.cgroup2.devices.allow: c 195:254 rwm
lxc.cgroup2.devices.allow: c 509:0 rwm
lxc.cgroup2.devices.allow: c 509:1 rwm
lxc.cgroup2.devices.allow: c 234:1 rwm
lxc.cgroup2.devices.allow: c 234:2 rwm
lxc.mount.entry: /dev/card0 dev/card0 none bind,optional,create=file
lxc.mount.entry: /dev/card1 dev/card1 none bind,optional,create=file
lxc.mount.entry: /dev/renderD128 dev/renderD128 none bind,optional,create=file
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-cap1 dev/nvidia-cap1 none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-cap2 dev/nvidia-cap2 none bind,optional,create=file
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
```

> **Note:** For unprivileged LXCs with file/bind mounts, ensure correct UID/GID mapping for storage access.

---

# Inside the LXC container

## OPTIONAL permissions you can adjust. 
# 1. Add user to groups
sudo usermod -aG video stumed
sudo usermod -aG render stumed

# 2. Create udev rule
sudo bash -c 'cat > /etc/udev/rules.d/70-nvidia.rules << EOF
# NVIDIA devices
KERNEL=="nvidia", RUN+="/bin/bash -c \"/usr/bin/nvidia-smi -L && /bin/chmod 666 /dev/nvidia*\""
KERNEL=="nvidia_uvm", RUN+="/bin/bash -c \"/usr/bin/nvidia-modprobe -c0 -u && /bin/chmod 666 /dev/nvidia-uvm*\""

# DRI devices - set permissions to 0666 for all users
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", MODE="0666"
KERNEL=="renderD[0-9]*", SUBSYSTEM=="drm", MODE="0666"
EOF'

# 3. Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger

# 4. Log out and back in (for group changes to take effect)
exit

## Actual Driver install
## Build Nvidia driver & install Nvidia container toolkit

```bash
# Install Vulkan user-space library
sudo apt install -y libvulkan1

# Install driver without kernel module
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/580.105.08/NVIDIA-Linux-x86_64-580.105.08.run
chmod +x NVIDIA-Linux-x86_64-580.105.08.run
sudo ./NVIDIA-Linux-x86_64-580.105.08.run --no-kernel-module
# The installer has a few prompts. Skip secondary cards, No 32 bits, No X 

## This section installs the Nvidia container runtime
# Install prerequisites
sudo apt install -y curl gpg

# Add NVIDIA Container Toolkit repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Update package list
sudo apt-get update

# Install latest stable version (recommended for security updates)
sudo apt-get install -y \
  nvidia-container-toolkit \
  nvidia-container-toolkit-base \
  libnvidia-container-tools \
  libnvidia-container1

# CRITICAL: Enable no-cgroups for unprivileged LXC (BEFORE runtime config)
sudo sed -i -e 's/.*no-cgroups.*/no-cgroups = true/g' /etc/nvidia-container-runtime/config.toml

# Configure Docker runtime
sudo nvidia-ctk runtime configure --runtime=docker

# Verify no-cgroups setting
grep "no-cgroups" /etc/nvidia-container-runtime/config.toml
# Should output: no-cgroups = true

# Restart Docker to apply changes
sudo systemctl restart docker

# Verify Docker runtime configuration
docker info | grep -i runtime
# Should show nvidia runtime available
```

---

### TEST setup

```bash
# Docker test
docker run --gpus all nvidia/cuda:12.6.1-base-ubuntu24.04 nvidia-smi
```
Now you have everything working in the docker!

All the tests provided should give an output similar to:
```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.144.03             Driver Version: 550.144.03     CUDA Version: 12.4     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  Quadro P4000                   On  |   00000000:86:00.0 Off |                  N/A |
| 46%   30C    P8              5W /  105W |       5MiB /   8192MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI        PID   Type   Process name                              GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|  No running processes found                                                             |
+-----------------------------------------------------------------------------------------+
```

---

## After a Proxmox or Kernel Upgrade

- **Reboot into the new kernel**.
- Run `dkms status` to confirm NVIDIA modules are built for the new kernel.
- Run `nvidia-smi` (host) to verify driver is active.
- Headers are managed by `pve-headers`; if issues arise, manually install with `apt install pve-headers-$(uname -r)`.

---

## Tips

- **Version Matching:** For maximum reliability, keep NVIDIA driver versions the same between host and LXC container.  
- **Troubleshooting:** If Docker inside LXC can't see the GPU, double-check device mappings and driver versions.
- **Cleanup:** Old kernels/headers can accumulate; if disk usage becomes an issue, use `apt autoremove` after rebooting to latest kernel.

---

## Uninstalling/Upgrading

If you need to uninstall a version use the command (not the .run application downloaded for install):
This is also used if you wish to upgrade the driver. Uninstall old on Host AND all LXC's. Then follow directions above to reinstall latest wanted version. 
```bash
nvidia-installer --uninstall 
```
