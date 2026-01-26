# NVIDIA Driver Upgrade Script

Automated NVIDIA driver upgrades for Proxmox hosts and GPU-enabled LXC containers.

## Overview

This script automates driver upgrades across your Proxmox infrastructure - host and all LXC containers with GPU passthrough. It auto-detects the latest driver version, downloads it, upgrades everything, and verifies the installation.

**⚠️ Important:** For initial NVIDIA setup, see the [main installation guide](../README.md).

## Quick Start

```bash
# Download and run on Proxmox host
cd /root
wget https://raw.githubusercontent.com/Bishop-trevorstuart/Nvidia-Proxmox-LXC-Docker/main/updating/nvidia-upgrade.sh
chmod +x nvidia-upgrade.sh

# Auto-detect latest version and upgrade
./nvidia-upgrade.sh

# Dry run to preview changes
DRY_RUN=true ./nvidia-upgrade.sh

# Use specific version
./nvidia-upgrade.sh 585.05.10
```

## What It Does

1. Checks NVIDIA servers for latest driver version
2. Downloads driver automatically (if needed)
3. Upgrades Proxmox host with DKMS support
4. Auto-discovers LXC containers with GPU passthrough
5. Upgrades driver in each container
6. Verifies installation and Docker GPU access
7. Restarts Docker Compose stacks
8. Logs everything to `/var/log/nvidia-upgrade-*.log`

## Usage Options

| Mode | Command | Description |
|------|---------|-------------|
| **Auto (recommended)** | `./nvidia-upgrade.sh` | Auto-detect latest, download, upgrade |
| **Dry run** | `DRY_RUN=true ./nvidia-upgrade.sh` | Preview changes without modifying system |
| **Manual version** | `./nvidia-upgrade.sh 585.05.10` | Specify exact driver version |
| **Skip download** | `AUTO_DOWNLOAD=false ./nvidia-upgrade.sh` | Don't auto-download driver |
| **Manual containers** | `LXC_CONTAINERS="101 102" ./nvidia-upgrade.sh` | Override container detection |

## Prerequisites

- Proxmox VE 8.x (Debian Bookworm)
- Existing NVIDIA driver installation
- Root access
- Internet connection
- Dependencies: `wget`, `curl`, `pct` (auto-checked)

## Upgrade Process

### Proxmox Host
1. Uninstall old driver and DKMS modules
2. Install new driver with `--dkms` flag for kernel upgrade support
3. Verify DKMS registration and persistence daemon

### LXC Containers
1. Copy driver to container
2. Install with `--no-kernel-module` flag (uses host kernel module)
3. Test Docker GPU access with CUDA container
4. Verify `no-cgroups = true` setting

## NVIDIA Container Toolkit

The toolkit updates **separately** via `apt` and doesn't need this script:

```bash
# Inside each LXC - part of normal updates
apt update && apt upgrade
```

The toolkit is decoupled from the driver - it just passes GPU devices to Docker. As long as `no-cgroups = true` stays in `/etc/nvidia-container-runtime/config.toml`, updates are safe.

## Troubleshooting

**Containers not detected:**
```bash
LXC_CONTAINERS="101 102 103" ./nvidia-upgrade.sh
```

**Download fails:**
```bash
wget https://download.nvidia.com/XFree86/Linux-x86_64/XXX.XX.XX/NVIDIA-Linux-x86_64-XXX.XX.XX.run
```

**Docker GPU test fails in container:**
```bash
# Check no-cgroups setting
grep "no-cgroups" /etc/nvidia-container-runtime/config.toml
# Should show: no-cgroups = true

# Reconfigure if needed
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
```

**View logs:**
```bash
tail -f /var/log/nvidia-upgrade-*.log
```

## Kernel Upgrades

After Proxmox kernel upgrades, DKMS automatically rebuilds driver modules - **you don't need this script**. Just reboot and verify:

```bash
dkms status    # Check module rebuilt
nvidia-smi     # Verify driver works
```

## Time Estimates

- 1 container: ~30 minutes
- 3 containers: ~60 minutes
- 5+ containers: ~90 minutes

## Related Documentation

- [Initial NVIDIA GPU Setup](../README.md)
- [NVIDIA Driver Installation Guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/)
- [NVIDIA Container Toolkit Docs](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)

## License

MIT License - See [LICENSE](../LICENSE)
