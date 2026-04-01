#!/usr/bin/env bash

set -euo pipefail

DRY_RUN=${DRY_RUN:-false}
FORCE=false
MANUAL_VERSION=""

# --- ARG PARSING ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true ;;
    --version) MANUAL_VERSION="$2"; shift ;;
    *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
fail() { echo "[ERROR] $*"; exit 1; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] $*"
  else
    "$@"
  fi
}

# --- CORE FUNCTIONS ---

get_current_version() {
  nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1
}

find_gpu_containers() {
  grep -l "nvidia0\|nvidia-uvm" /etc/pve/nodes/*/lxc/*.conf \
    | awk -F'/' '{print $NF}' | cut -d'.' -f1
}

gpu_in_use() {
  nvidia-smi | grep -A10 "Processes" | grep -qE '[0-9]+MiB'
}

get_compose_dirs() {
  pct exec "$1" -- bash -c '
    find /opt -type f \( -name docker-compose.yml -o -name compose.yaml \) \
    -exec dirname {} \; 2>/dev/null
  '
}

stop_compose() {
  vmid="$1"
  for dir in $(get_compose_dirs "$vmid"); do
    run pct exec "$vmid" -- bash -c "cd \"$dir\" && docker compose down"
  done
}

start_compose() {
  vmid="$1"
  for dir in $(get_compose_dirs "$vmid"); do
    run pct exec "$vmid" -- bash -c "cd \"$dir\" && docker compose up -d"
  done
}

stop_gpu_usage() {
  log "Stopping GPU workloads..."

  for vmid in $(find_gpu_containers); do
    stop_compose "$vmid"
  done

  run systemctl stop nvidia-persistenced 2>/dev/null || true

  run modprobe -r nvidia_uvm 2>/dev/null || true
  run modprobe -r nvidia_modeset 2>/dev/null || true
  run modprobe -r nvidia 2>/dev/null || true
}

install_version() {
  VERSION="$1"

  FILE="NVIDIA-Linux-x86_64-$VERSION.run"
  URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/$VERSION/$FILE"

  log "Installing $VERSION"
  log "Source: $URL"

  cd /tmp

  run rm -f "$FILE"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] wget $URL"
    return 0
  fi

  # --- DOWNLOAD ---
  if ! wget "$URL" -O "$FILE"; then
    fail "Download failed (bad version or network issue)"
  fi

  # --- VALIDATE FILE ---
  if ! file "$FILE" | grep -q "shell script"; then
    fail "Downloaded file is not a valid NVIDIA installer"
  fi

  chmod +x "$FILE"

  log "Running NVIDIA installer..."

  # --- RUN INSTALLER ---
  if ! ./"$FILE" --dkms --silent; then
    echo "------ NVIDIA INSTALL LOG ------"
    cat /var/log/nvidia-installer.log || true
    fail "Installer failed"
  fi

  log "Install successful: $VERSION"
}

upgrade_host() {
  CURRENT=$(get_current_version)
  log "Current driver: $CURRENT"

  if gpu_in_use && [[ "$FORCE" != true ]]; then
    fail "GPU is in use. Re-run with --force"
  fi

  [[ "$FORCE" == true ]] && stop_gpu_usage

  if [[ -z "$MANUAL_VERSION" ]]; then
    fail "No version specified. Use --version"
  fi

  install_version "$MANUAL_VERSION"
  TARGET_VERSION="$MANUAL_VERSION"

  run modprobe nvidia_uvm

  if [[ "$DRY_RUN" != "true" ]]; then
    grep -q nvidia_uvm /etc/modules || echo nvidia_uvm >> /etc/modules
  else
    echo "[DRY RUN] ensure nvidia_uvm in /etc/modules"
  fi
}

upgrade_container() {
  vmid="$1"
  version="$2"

  log "Updating container $vmid"

  run pct exec "$vmid" -- bash -c "
    set -e
    cd /tmp
    rm -f NVIDIA-Linux-x86_64-$version.run
    wget https://us.download.nvidia.com/XFree86/Linux-x86_64/$version/NVIDIA-Linux-x86_64-$version.run -O driver.run
    chmod +x driver.run
    ./driver.run --no-kernel-module --silent
    sed -i 's/^#\\?no-cgroups.*/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
  "

  if [[ "$FORCE" == true ]]; then
    start_compose "$vmid"
  fi
}

main() {
  upgrade_host

  for vmid in $(find_gpu_containers); do
    upgrade_container "$vmid" "$TARGET_VERSION"
  done

  log "Done"
}

main "$@"