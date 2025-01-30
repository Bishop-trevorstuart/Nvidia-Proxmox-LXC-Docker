# NvidiaGPU in Proxmox Host then unpriviledged LXC and finally available to docker
Nvidia in Proxmox LXC or any other LXC under Linux and more specifically Debian in this example.

This guide is based on Debian Bookworm and/or Proxmomx 8
I'm not the original person to build this guide, you can easily look up where it's forked from!

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

## Check for IOMMU *I haven't hard to do this as so far all systems I've done this on already had IOMMU setup/working!
```
dmesg | grep IOMMU
```
Should result in something like:
```
[    0.554887] pci 0000:00:00.2: AMD-Vi: IOMMU performance counters supported
[    0.560664] pci 0000:00:00.2: AMD-Vi: Found IOMMU cap 0x40
[    0.560961] perf/amd_iommu: Detected AMD IOMMU #0 (2 banks, 4 counters/bank).
```
If you get nothing you better check your bios.

## HOST Debian/Proxmox setup
```
apt install -y pve-headers-$(uname -r) build-essential libvulkan1
```
or if you are on Debian and not in Proxmox
```
sudo apt install -y linux-headers-$(uname -r) build-essential libvulkan1
```

Blacklist nouveau
```
echo "blacklist nouveau" > /etc/modprobe.d/blacklist.conf
echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist.conf
update-initramfs -u
```

## Nvidia 
### download and install Driver (Check for latest rather than blindly using below)
- Find version you want here: https://www.nvidia.com/en-us/drivers/unix/
```
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/550.144.03/NVIDIA-Linux-x86_64-550.144.03.run
sh NVIDIA-Linux-x86_64-550.144.03.run --dkms
```
The installer has a few prompts. Skip secondary cards, No 32 bits, No X 

## Add the output of this command to your LXC config file (/etc/pve/nodes/pve/lxc/xxx.conf)
```
ls -l /dev/nv* |grep -v nvme | grep crw | sed -e 's/.*root root\s*\(.*\),.*\/dev\/\(.*\)/lxc.cgroup2.devices.allow: c \1:* rwm\nlxc.mount.entry: \/dev\/\2 dev\/\2 none bind,optional,create=file/g'
```
Should look something like this(Do not blindly copy the below):
```
lxc.cgroup2.devices.allow: c 195:* rw
lxc.mount.entry: /dev/nvidia0 nvidia0 none bind,optional,create=file
lxc.cgroup2.devices.allow: c 195:* rw
lxc.mount.entry: /dev/nvidiactl nvidiactl none bind,optional,create=file
lxc.cgroup2.devices.allow: c 195:* rw
lxc.mount.entry: /dev/nvidia-modeset nvidia-modeset none bind,optional,create=file
lxc.cgroup2.devices.allow: c 236:* rw
lxc.mount.entry: /dev/nvidia-uvm nvidia-uvm none bind,optional,create=file
lxc.cgroup2.devices.allow: c 236:* rw
lxc.mount.entry: /dev/nvidia-uvm-tools nvidia-uvm-tools none bind,optional,create=file
lxc.cgroup2.devices.allow: c 10:* rw
lxc.mount.entry: /dev/nvram nvram none bind,optional,create=file
```
## [optional, and only on HOST] Turn on persistane mode:
https://docs.nvidia.com/deploy/driver-persistence/index.html
```
nvidia-smi --persistence-mode=1 #only for current session
nvidia-persistenced
```
# Inside the LXC container

## Build Nvidia driver & install Nvidia container toolkit
```
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/550.144.03/NVIDIA-Linux-x86_64-550.144.03.run
sh NVIDIA-Linux-x86_64-550.144.03.run --no-kernel-module
#The installer has a few prompts. Skip secondary cards, No 32 bits, No X 

#############Install NVIDIA Container Toolkit
apt install curl gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list \
  && \
    apt-get update

apt-get install -y nvidia-container-toolkit

nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
sed -i -e 's/.*no-cgroups.*/no-cgroups = true/g' /etc/nvidia-container-runtime/config.toml
```

### TEST setup
```
docker run --gpus all -it --rm nvcr.io/nvidia/tensorflow:23.10-tf2-py3
python3 -c "import tensorflow as tf; print(tf.config.list_physical_devices('GPU'))"
```
Now you have everything working in the docker!

### testing the driver itself (not inside docker) to confirm it's working
This will loop and call the view at every second.
```
nvidia-smi -l 1
```
If you do not want to keep past traces of the looped call in the console history, you can also do:
```
watch -n0.1 nvidia-smi
```
Where 0.1 is the time interval, in seconds.
