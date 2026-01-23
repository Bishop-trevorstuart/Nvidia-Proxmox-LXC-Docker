# Nvidia Driver Update Management

## Overview
Automated update system for Nvidia GPU drivers across the Proxmox → LXC → Docker stack.

## Files
- `update-nvidia-driver.sh` - Smart update script that detects environment and updates appropriately
- `.github/workflows/nvidia-update.yml` - GitHub Actions for automated updates

## Architecture

### Update Flow
```
Proxmox Host (with DKMS)
    ↓
LXC Container (userspace only)
    ↓
Docker Containers (via nvidia-container-toolkit)
```

## Usage

### Check Current Version
```bash
# On host or in LXC
nvidia-smi
```

### Update to Latest Driver
```bash
cd /opt/Nvidia-Proxmox-LXC-Docker/updating
chmod +x update-nvidia-driver.sh

# Use default version from script
sudo ./update-nvidia-driver.sh

# Or specify version
sudo NVIDIA_VERSION=570.133.07 ./update-nvidia-driver.sh
```

### Update Specific LXC from Host
```bash
# On Proxmox host - update LXC container
pct exec <LXC_ID> -- bash -c "cd /opt/Nvidia-Proxmox-LXC-Docker/updating && ./update-nvidia-driver.sh"
```

## Features

### Environment Detection
- Auto-detects: Proxmox host, LXC container, or standalone
- Adapts installation method automatically
- Host: Full driver with DKMS kernel modules
- LXC: Userspace libraries only (no kernel module)

### Backup & Rollback
- Automatic backup before updates
- Backups stored in `/opt/nvidia-backups/YYYYMMDD-HHMMSS/`
- Contains: driver version, GPU list, loaded modules

### Health Checks
- Verifies nvidia-smi functionality
- Tests Docker GPU access in LXC
- Reports driver version and GPU detection

### Logging
- Comprehensive logging to `/var/log/nvidia-updates.log`
- Timestamped entries with color-coded console output

## Initial Setup Checklist

Before using this update script, ensure base setup is complete:

### Proxmox Host
- [ ] IOMMU enabled in BIOS
- [ ] `pve-headers` installed
- [ ] nouveau blacklisted
- [ ] Initial Nvidia driver installed

### LXC Container
- [ ] GPU device nodes passed through in LXC config
- [ ] Container configured as unprivileged
- [ ] Docker installed
- [ ] Initial Nvidia driver (userspace) installed

See [main README](../README.md) for detailed setup instructions.

## CI/CD Integration

### GitHub Actions Workflow
Automates driver updates across your infrastructure:
- Scheduled monthly updates (configurable)
- Manual trigger for emergency updates
- SSH deployment to Proxmox host
- Cascading updates: Host → LXC → Docker test

### Setup Requirements

**1. GitHub Repository Secrets:**
- `PROXMOX_HOST_IP` - Proxmox server IP
- `PROXMOX_SSH_USER` - SSH username
- `PROXMOX_SSH_KEY` - Private SSH key
- `LXC_ID` - Container ID to update (e.g., 100)

**2. Host Requirements:**
- SSH access configured with key-based auth
- Repository cloned to: `/opt/Nvidia-Proxmox-LXC-Docker/`
- Script permissions: `chmod +x updating/update-nvidia-driver.sh`

**3. LXC Requirements:**
- Repository accessible (bind mount or clone inside LXC)
- Path: `/opt/Nvidia-Proxmox-LXC-Docker/`

## Monitoring

### Check Last Update
```bash
tail -20 /var/log/nvidia-updates.log
```

### Watch GPU Status
```bash
# Continuous monitoring
watch -n 1 nvidia-smi

# Or
nvidia-smi -l 1
```

### Verify Docker GPU Access
```bash
docker run --rm --gpus all nvidia/cuda:12.6.1-base-ubuntu24.04 nvidia-smi
```

## Rollback Procedure

If an update fails:

```bash
# Find backup
ls -lt /opt/nvidia-backups/

# Navigate to backup
cd /opt/nvidia-backups/YYYYMMDD-HHMMSS/

# Check what version you had
cat driver-version.txt

# Reinstall that version
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/XXX.XX.XX/NVIDIA-Linux-x86_64-XXX.XX.XX.run
chmod +x NVIDIA-Linux-x86_64-XXX.XX.XX.run

# On host
sudo sh NVIDIA-Linux-x86_64-XXX.XX.XX.run --dkms

# In LXC
sudo sh NVIDIA-Linux-x86_64-XXX.XX.XX.run --no-kernel-module
```

## Troubleshooting

### Driver Install Fails
```bash
# Check loaded modules
lsmod | grep nvidia

# Unload manually
sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia

# Check kernel headers
dpkg -l | grep headers

# Check logs
tail -50 /var/log/nvidia-updates.log
```

### nvidia-smi Not Found
```bash
# Check installation
which nvidia-smi
ls -la /usr/bin/nvidia-smi

# Verify PATH
echo $PATH

# Re-run installation
sudo ./update-nvidia-driver.sh
```

### Docker Can't Access GPU
```bash
# Check nvidia-container-toolkit
dpkg -l | grep nvidia-container-toolkit

# Reconfigure
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Check config
cat /etc/nvidia-container-runtime/config.toml | grep no-cgroups
# Should show: no-cgroups = true
```

### LXC Can't See GPU
```bash
# On Proxmox host - verify devices passed through
cat /etc/pve/lxc/<LXC_ID>.conf | grep lxc.cgroup2.devices

# Should see entries for /dev/nvidia* devices
# If missing, re-run device mapping from main README
```

## Version Management

### Check Available Versions
📅 [Nvidia Unix Drivers](https://www.nvidia.com/en-us/drivers/unix/) | Last Updated: 2026-01-23

### Current Tested Versions
- ✅ 570.133.07 (Production - Recommended)
- ✅ 565.x.x (Long-term support branch)
- ⚠️ Beta/New Feature branches (Test before deploying)

### Update Strategy
1. **Test in dev environment first**
2. **Update Proxmox host during maintenance window**
3. **Verify host GPU functionality**
4. **Update LXC containers sequentially**
5. **Test Docker GPU access in each LXC**
6. **Monitor for 24 hours post-update**

## Best Practices

✅ **DO:**
- Test updates in non-production first
- Keep backups for 90 days
- Schedule updates during low-usage windows
- Update host before LXC containers
- Verify GPU access after each update
- Document any custom configurations

❌ **DON'T:**
- Update production without testing
- Skip backup verification
- Update all systems simultaneously
- Ignore warning messages
- Mix driver versions (host vs LXC)

## Development on Windows

This repository is developed on Windows using VS Code and deployed to Linux infrastructure:
- **Development:** Windows 11, VS Code, Git
- **Deployment:** Proxmox VE (Debian-based), LXC containers
- **Version Control:** Git with proper line ending handling (LF for shell scripts)

## References

📅 [Nvidia CUDA Installation Guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/) | Last Updated: 2026-01-23
📅 [Nvidia Container Toolkit](https://github.com/NVIDIA/nvidia-container-toolkit) | Last Updated: 2026-01-23
📅 [Proxmox GPU Passthrough](https://pve.proxmox.com/wiki/PCI(e)_Passthrough) | Last Updated: 2026-01-23