#!/usr/bin/env bash

set -euo pipefail

DRY_RUN=${DRY_RUN:-false}

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] $*"
  else
    "$@"
  fi
}

get_latest_version() {
  curl -s https://download.nvidia.com/XFree86/Linux-x86_64/ \
    | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -V \
    | tail -n1
}

get_current_version() {
  nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1
}

ensure_uvm() {
  if [[ ! -c /dev/nvidia-uvm ]]; then
    warn "UVM missing, loading module..."
    run modprobe nvidia_uvm
  fi
}

upgrade_host() {
  log "Checking host driver..."

  NEW_VERSION=$(get_latest_version)
  CURRENT_VERSION=$(get_current_version)

  if [[ -z "$NEW_VERSION" ]]; then
    echo "[ERROR] Failed to detect latest NVIDIA version"
    exit 1
  fi

  if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
    log "Host already on latest version ($CURRENT_VERSION)"
    return
  fi

  log "Updating $CURRENT_VERSION → $NEW_VERSION"

  cd /tmp

  run wget -q https://us.download.nvidia.com/XFree86/Linux-x86_64/$NEW_VERSION/NVIDIA-Linux-x86_64-$NEW_VERSION.run
  run chmod +x NVIDIA-Linux-x86_64-$NEW_VERSION.run

  if systemctl list-units --type=service | grep -q docker; then
    run systemctl stop docker
  fi

  run ./NVIDIA-Linux-x86_64-$NEW_VERSION.run --dkms --silent

  run modprobe nvidia_uvm
  if [[ "$DRY_RUN" != "true" ]]; then
    grep -q nvidia_uvm /etc/modules || echo nvidia_uvm >> /etc/modules
  else
    echo "[DRY RUN] ensure nvidia_uvm in /etc/modules"
  fi

  if systemctl list-units --type=service | grep -q docker; then
    run systemctl start docker
  fi

  log "✓ Host upgraded"
}

upgrade_container() {
  vmid="$1"
  log "Upgrading container $vmid..."

  VERSION=$(get_latest_version)

  run pct exec "$vmid" -- bash -c "
    set -e
    cd /tmp
    wget -q https://us.download.nvidia.com/XFree86/Linux-x86_64/$VERSION/NVIDIA-Linux-x86_64-$VERSION.run
    chmod +x NVIDIA-Linux-x86_64-$VERSION.run
    ./NVIDIA-Linux-x86_64-$VERSION.run --no-kernel-module --silent
    sed -i 's/^#\\?no-cgroups.*/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
  "

  log "Validating Docker GPU in container $vmid..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Skipping GPU validation in container $vmid"
  else
    pct exec "$vmid" -- docker run --rm --gpus all nvidia/cuda:12.6.1-base-ubuntu24.04 nvidia-smi >/dev/null 2>&1 \
      && log "✓ GPU OK in container $vmid" \
      || warn "GPU FAILED in container $vmid"
  fi
}

find_gpu_containers() {
  grep -l "nvidia0\|nvidia-uvm" /etc/pve/nodes/*/lxc/*.conf | \
    awk -F'/' '{print $NF}' | cut -d'.' -f1
}

main() {
  ensure_uvm

  upgrade_host

  for vmid in $(find_gpu_containers); do
    upgrade_container "$vmid"
  done

  log "Done"
}

main "$@"