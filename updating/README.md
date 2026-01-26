# NVIDIA Driver Upgrade Script (NO REBOOT)

Automated NVIDIA driver upgrades for Proxmox hosts and GPU-enabled LXC containers **without triggering system reboots**.

## Overview

This script:
- **Auto-detects** latest production-branch NVIDIA driver from official servers
- **Shows** currently installed version vs. target version
- **Upgrades** Proxmox host with DKMS kernel module support
- **Auto-detects** all LXC containers with GPU passthrough
- **Upgrades** driver in each container (no kernel modules)
- **Restarts** Docker workloads gracefully (NO SYSTEM REBOOT)
- **Displays** post-upgrade reboot/restart requirements
- **Logs** all actions for troubleshooting

**Key Point:** This script is designed for production environments where reboots must be scheduled separately.

## Quick Start

```bash
# Download and run on Proxmox host
cd /root
wget https://raw.githubusercontent.com/Bishop-trevorstuart/Nvidia-Proxmox-LXC-Docker/main/updating/nvidia-upgrade.sh
chmod +x nvidia-upgrade.sh

# Auto-detect latest and upgrade (recommended)
./nvidia-upgrade.sh

# Dry-run to see what would happen
DRY_RUN=true ./nvidia-upgrade.sh

# Use specific version
./nvidia-upgrade.sh 550.127.05
```

## What Gets Upgraded

### Proxmox Host
✓ Driver installation with DKMS kernel module (persists after kernel upgrades)
✓ DKMS module registration
✓ NVIDIA persistence daemon
✗ **Does NOT reboot the host**

### LXC Containers
✓ Driver installation (no kernel modules - uses host's)
✓ Docker service restart
✓ Docker Compose stack restart
✗ **Does NOT reboot containers**

## Reboot Requirements

### After Upgrade, You May Need To:

**For Proxmox Host:**
- ⚠️ **Reboot is required** for the new DKMS kernel module to take effect
- Old kernel module remains in use until reboot
- Schedule at your convenience: `reboot`

**For LXC Containers:**
- ✓ Docker services restarted automatically (no reboot needed)
- GPU workloads restarted automatically
- If GPU apps don't reconnect, manually restart them

## Usage Modes

| Mode | Command | Description |
|------|---------|-------------|
| **Auto (recommended)** | `./nvidia-upgrade.sh` | Detects latest, downloads, upgrades |
| **Specific version** | `./nvidia-upgrade.sh 550.127.05` | Use exact driver version |
| **Dry-run preview** | `DRY_RUN=true ./nvidia-upgrade.sh` | Show changes without applying |
| **Skip download** | `AUTO_DOWNLOAD=false ./nvidia-upgrade.sh` | Use pre-downloaded driver |
| **Manual containers** | `LXC_CONTAINERS='101 102 103' ./nvidia-upgrade.sh` | Override auto-detection |
| **No workload restart** | `SKIP_WORKLOAD_RESTART=true ./nvidia-upgrade.sh` | Upgrade only, no restart |

## Prerequisites

- Proxmox VE 8.x (Debian Bookworm)
- Existing NVIDIA driver installation
- Root access on Proxmox host
- Internet connection (for driver download)
- Dependencies: `wget curl pct nvidia-smi dkms`

All checked automatically before upgrade.

## How It Works

### Version Detection
```
1. Queries NVIDIA official servers for latest production version
2. Compares with currently installed version
3. Shows side-by-side comparison
4. Asks for confirmation before proceeding
```

### Host Upgrade
```
1. Stops Docker services
2. Uninstalls old driver
3. Removes old DKMS modules
4. Installs new driver with DKMS
5. Verifies installation
6. Registers DKMS kernel module
7. Restarts NVIDIA persistence daemon
```

### Container Upgrade
```
1. Starts container if stopped
2. Stops Docker workloads gracefully
3. Uninstalls old driver
4. Copies new driver to container
5. Installs driver (no kernel module)
6. Verifies installation
7. Restarts Docker daemon
8. Auto-restarts Docker Compose stacks
```

## Output Example

```
╔══════════════════════════════════════════════════════════════╗
║         NVIDIA Driver Upgrade Script (No Reboot)            ║
╚══════════════════════════════════════════════════════════════╝

[2026-01-26 01:50:39] Initialization started
[INFO] ✓ Proxmox VE is running
[INFO] ✓ NVIDIA driver is installed
[INFO] Querying NVIDIA for latest production driver version...
[INFO] Latest production version: 550.127.05

╔══════════════════════════════════════════════════════════════╗
║              Driver Version Information                      ║
╚══════════════════════════════════════════════════════════════╝

  Currently installed: 550.100.04
  Target version:      550.127.05
  ⬆ Upgrade available

Proceed with upgrade to version 550.127.05? (yes/no): yes

[INFO] Downloading NVIDIA driver 550.127.05...
✓ Download complete (614MB)

╔══════════════════════════════════════════════════════════════╗
║              Upgrading Proxmox Host Driver                  ║
╚══════════════════════════════════════════════════════════════╝

[2026-01-26 01:50:39] Current host driver: 550.100.04
[2026-01-26 01:50:39] Target host driver:  550.127.05
[2026-01-26 01:50:40] Step 1/4: Stopping GPU workloads...
[2026-01-26 01:50:42] Step 2/4: Uninstalling current driver...
[2026-01-26 01:50:55] Step 3/4: Cleaning DKMS modules...
[2026-01-26 01:51:02] Step 4/4: Installing new driver with DKMS...
✓ Host driver installation successful
✓ Host driver version verified: 550.127.05
✓ DKMS module registered
✓ NVIDIA persistence daemon restarted
⚠ Host will need reboot for DKMS kernel module to take effect

╔══════════════════════════════════════════════════════════════╗
║              Auto-detected GPU Containers                    ║
╚══════════════════════════════════════════════════════════════╝

✓ Auto-detected GPU containers: 101 102

╔══════════════════════════════════════════════════════════════╗
║              Upgrading LXC Container 101                     ║
╚══════════════════════════════════════════════════════════════╝

✓ Container 101 driver verified: 550.127.05
✓ Container 101 workloads restarted

╔══════════════════════════════════════════════════════════════╗
║        IMPORTANT: Post-Upgrade Actions Required             ║
╚══════════════════════════════════════════════════════════════╝

⚠ HOST SYSTEM REQUIRES REBOOT
  The new DKMS kernel module will only load after reboot.
  Reboot when ready: reboot

Log file: /var/log/nvidia-upgrade-20260126-015039.log
```

## Troubleshooting

### Driver download fails
```bash
# Download manually
wget https://download.nvidia.com/XFree86/Linux-x86_64/550.127.05/NVIDIA-Linux-x86_64-550.127.05.run

# Then run script with AUTO_DOWNLOAD=false
AUTO_DOWNLOAD=false ./nvidia-upgrade.sh 550.127.05
```

### Containers not auto-detected
```bash
# Manually specify containers
LXC_CONTAINERS='101 102 103' ./nvidia-upgrade.sh
```

### Docker GPU test fails in container
```bash
# Inside container, verify no-cgroups setting
grep "no-cgroups" /etc/nvidia-container-runtime/config.toml
# Should show: no-cgroups = true

# If missing, reconfigure
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
```

### View detailed logs
```bash
# Find latest log
tail -f /var/log/nvidia-upgrade-*.log

# Or enable debug output
DEBUG=1 ./nvidia-upgrade.sh
```

### Verify DKMS module status
```bash
# Check DKMS registration
dkms status

# After reboot, verify module loaded
grep nvidia /proc/modules

# Check driver
nvidia-smi
```

## Post-Reboot Verification

After rebooting the Proxmox host:

```bash
# Verify DKMS module rebuilt for new kernel
dkms status

# Verify driver still working
nvidia-smi

# Check for GPU errors
nvidia-smi -q

# Test containers
pct exec 101 -- nvidia-smi
```

## Kernel Upgrade Handling

After a Proxmox kernel upgrade, DKMS automatically rebuilds the driver module. **You don't need this script.** Just reboot:

```bash
reboot

# After reboot
dkms status    # Check DKMS auto-rebuild
nvidia-smi     # Verify driver works
```

## Key Differences from Previous Version

| Feature | Old | New |
|---------|-----|-----|
| Latest version detection | Semi-manual | Production-branch auto-detect |
| Show installed version | No | Yes, with comparison |
| No reboot option | No | Yes (explicit) |
| Container detection | Basic | Improved config parsing |
| Reboot requirements | Not shown | Clearly displayed |
| Error handling | Basic | Robust with recovery |
| DKMS support | Present | Improved verification |

## Time Estimates

- **1 container:** ~30 minutes
- **3 containers:** ~60 minutes  
- **5+ containers:** ~90 minutes

(Includes download time; cached drivers are much faster)

## Related Documentation

- [Initial NVIDIA GPU Setup](../README.md)
- [NVIDIA Driver Installation Guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/)
- [DKMS Documentation](https://help.ubuntu.com/community/DKMS)

## License

MIT License - See [LICENSE](../LICENSE)

---

**Last Updated:** 2026-01-26
**Tested on:** Proxmox VE 8.x (Debian Bookworm), NVIDIA driver 550.x branch
