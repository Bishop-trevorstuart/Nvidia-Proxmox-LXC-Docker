#!/bin/bash
# NVIDIA Driver Upgrade Script for Proxmox + LXC (NO REBOOT)
set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

NEW_VERSION="${1:-}"
NVIDIA_API_URL="https://download.nvidia.com/XFree86/Linux-x86_64"
DRIVER_FILE=""
LOG_FILE="/var/log/nvidia-upgrade-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN="${DRY_RUN:-false}"
AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-true}"
LXC_CONTAINERS="${LXC_CONTAINERS:-}"
NEEDS_REBOOT_HOST=0
NEEDS_REBOOT_CONTAINERS=()

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }

section() {
  echo ""
  echo -e "${CYAN}====== $1 ======${NC}"
  echo ""
}

check_root() { [[ $EUID -ne 0 ]] && error "Must run as root"; }

check_deps() {
  local deps=("wget" "curl" "pct" "nvidia-smi" "dkms")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      error "Missing: $dep"
    fi
  done
  log "✓ Dependencies OK"
}

check_proxmox() {
  if ! systemctl is-active --quiet pve 2>/dev/null; then
    error "Proxmox not running"
  fi
  log "✓ Proxmox OK"
}

check_nvidia() {
  if ! nvidia-smi &>/dev/null; then
    error "NVIDIA driver not installed"
  fi
  log "✓ NVIDIA driver OK"
}

get_current_version() {
  nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown"
}

get_latest_version() {
  log "Checking NVIDIA for latest version..."
  local latest
  latest=$(curl -s --max-time 5 "${NVIDIA_API_URL}/latest.txt" 2>/dev/null | head -1 | grep -oP '^\d+\.\d+\.\d+' || echo "")
  [[ -n "$latest" ]] && echo "$latest" && return 0
  
  info "Using directory listing..."
  local versions
  versions=$(curl -s --max-time 10 "${NVIDIA_API_URL}/" 2>/dev/null | grep -oP 'href="\K\d+\.\d+\.\d+' | sort -V | tail -1)
  [[ -n "$versions" ]] && echo "$versions" && return 0
  
  error "Failed to get NVIDIA version"
}

compare_versions() {
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]] && return 1 || return 2
}

download_driver() {
    local version="$1"
    local filename="NVIDIA-Linux-x86_64-${version}.run"
    local url="${NVIDIA_API_URL}/${version}/${filename}"
    local target_file="/root/${filename}"
    
    if [[ -f "$target_file" ]]; then
        log "Driver file already exists: $target_file"
        
        # Verify it's a valid file (> 100MB)
        local file_size
        file_size=$(stat -c%s "$target_file" 2>/dev/null || echo 0)
        if [[ $file_size -gt 100000000 ]]; then
            DRIVER_FILE="$target_file"
            return 0
        else
            warn "Existing file appears corrupted (too small). Re-downloading..."
            rm -f "$target_file"
        fi
    fi
    
    log "Downloading NVIDIA driver ${version}..."
    info "URL: $url"
    info "Target: $target_file"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would download: $url"
        DRIVER_FILE="$target_file"
        return 0
    fi
    
    # Download with progress bar
    if wget --show-progress -O "$target_file" "$url" 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Download complete"
        chmod +x "$target_file"
        DRIVER_FILE="$target_file"
    else
        error "Failed to download driver from: $url"
    fi
}

validate_inputs() {
    if [[ -z "$NEW_VERSION" ]]; then
        # Auto-detect mode
        NEW_VERSION=$(get_latest_nvidia_version)
        
        local current_version
        current_version=$(get_current_driver_version)
        
        echo ""
        highlight "╔════════════════════════════════════════════════════════════════╗"
        highlight "║              NVIDIA Driver Version Information                 ║"
        highlight "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        echo -e "  Current installed version: ${YELLOW}${current_version}${NC}"
        echo -e "  Latest available version:  ${GREEN}${NEW_VERSION}${NC}"
        echo ""
        
        if [[ "$current_version" == "$NEW_VERSION" ]]; then
            highlight "✓ You are already running the latest driver version!"
            read -p "Continue with reinstallation anyway? (yes/no): " -r
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                log "Upgrade cancelled - already on latest version"
                exit 0
            fi
        elif [[ "$current_version" != "none" ]]; then
            compare_versions "$NEW_VERSION" "$current_version"
            case $? in
                1) echo -e "  ${GREEN}⬆ Upgrade available${NC}" ;;
                2) echo -e "  ${YELLOW}⬇ Downgrade (not recommended)${NC}" ;;
            esac
        fi
        
        echo ""
        read -p "Proceed with driver version ${NEW_VERSION}? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            error "Upgrade cancelled by user"
        fi
        
        # Download driver
        if [[ "$AUTO_DOWNLOAD" == "true" ]]; then
            download_driver "$NEW_VERSION"
        fi
    else
        # Manual version specified
        DRIVER_FILE="/root/NVIDIA-Linux-x86_64-${NEW_VERSION}.run"
    fi
    
    if [[ -z "$DRIVER_FILE" ]] || [[ ! -f "$DRIVER_FILE" ]]; then
        error "Driver file not found: $DRIVER_FILE\nDownload it with:\nwget ${NVIDIA_DOWNLOAD_BASE}/${NEW_VERSION}/NVIDIA-Linux-x86_64-${NEW_VERSION}.run"
    fi
    
    if [[ ! -x "$DRIVER_FILE" ]]; then
        log "Making driver file executable..."
        chmod +x "$DRIVER_FILE"
    fi
}

detect_lxc_containers() {
    if [[ -z "$LXC_CONTAINERS" ]]; then
        log "Auto-detecting LXC containers with GPU passthrough..."
        LXC_CONTAINERS=$(grep -l "nvidia" /etc/pve/nodes/*/lxc/*.conf 2>/dev/null | \
                         grep -oP 'lxc/\K[0-9]+' | sort -u | tr '\n' ' ')
        
        if [[ -z "$LXC_CONTAINERS" ]]; then
            warn "No LXC containers with GPU passthrough detected"
            warn "Set manually with: LXC_CONTAINERS='101 102' $0 $NEW_VERSION"
        else
            log "Detected LXC containers: $LXC_CONTAINERS"
        fi
    else
        log "Using manually specified LXC containers: $LXC_CONTAINERS"
    fi
}

is_running() { pct status "$1" 2>/dev/null | grep -q "running"; }

get_container_version() {
  pct exec "$1" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown"
}

upgrade_host() {
  section "Upgrading Host Driver"
  local curr
  curr=$(get_current_version)
  
  log "Current: ${YELLOW}$curr${NC}"
  log "Target:  ${GREEN}$NEW_VERSION${NC}"
  
  [[ "$curr" == "$NEW_VERSION" ]] && warn "Already at target" && return 0
  [[ "$DRY_RUN" == "true" ]] && info "[DRY-RUN] Would upgrade to $NEW_VERSION" && return 0
  
  log "Stopping services..."
  systemctl stop docker 2>/dev/null || true
  sleep 2
  
  log "Uninstalling old driver..."
  nvidia-installer --uninstall --silent --no-questions 2>/dev/null || true
  
  log "Cleaning DKMS..."
  for mod in $(dkms status 2>/dev/null | grep nvidia | awk -F', ' '{print $1}' | sort -u); do
    dkms remove "$mod" --all 2>/dev/null || true
  done
  
  log "Installing new driver..."
  "$DRIVER_FILE" --silent --dkms --no-kernel-module=false --no-questions --no-x-check || error "Install failed"
  
  sleep 3
  local new
  new=$(get_current_version)
  [[ "$new" == "$NEW_VERSION" ]] && log "✓ Host upgraded" || error "Version mismatch: $new vs $NEW_VERSION"
  
  NEEDS_REBOOT_HOST=1
  warn "Host needs reboot for DKMS module"
}

upgrade_container() {
  local vmid="$1"
  section "Upgrading Container $vmid"
  
  pct status "$vmid" &>/dev/null || error "Container $vmid not found"
  
  is_running "$vmid" || (log "Starting container..." && pct start "$vmid" && sleep 5)
  [[ "$DRY_RUN" == "true" ]] && info "[DRY-RUN] Would upgrade container $vmid" && return 0
  
  local curr
  curr=$(get_container_version "$vmid")
  log "Current: ${YELLOW}$curr${NC}"
  log "Target:  ${GREEN}$NEW_VERSION${NC}"
  
  [[ "$curr" == "$NEW_VERSION" ]] && warn "Already at target" && return 0
  
  log "Stopping Docker..."
  pct exec "$vmid" -- bash -c 'command -v docker >/dev/null && docker stop $(docker ps -q) 2>/dev/null || true' 2>/dev/null || true
  
  log "Uninstalling old driver..."
  pct exec "$vmid" -- bash -c 'command -v nvidia-installer >/dev/null && nvidia-installer --uninstall --silent --no-questions 2>/dev/null || true' 2>/dev/null || true
  
  log "Copying driver..."
  pct push "$vmid" "$DRIVER_FILE" "/tmp/NVIDIA-Linux-x86_64-${NEW_VERSION}.run"
  
  log "Installing driver..."
  pct exec "$vmid" -- bash -c "chmod +x /tmp/NVIDIA-Linux-x86_64-${NEW_VERSION}.run && /tmp/NVIDIA-Linux-x86_64-${NEW_VERSION}.run --silent --no-kernel-module --no-questions --no-x-check --no-search-path --accept-license" || error "Container install failed"
  
  sleep 3
  local new
  new=$(get_container_version "$vmid")
  [[ "$new" == "$NEW_VERSION" ]] && log "✓ Container upgraded" || error "Version mismatch: $new vs $NEW_VERSION"
  
  pct exec "$vmid" -- rm -f "/tmp/NVIDIA-Linux-x86_64-${NEW_VERSION}.run" 2>/dev/null || true
  NEEDS_REBOOT_CONTAINERS+=("$vmid")
  warn "Container needs workload restart"
}

restart_workloads() {
  section "Restarting Container Workloads"
  [[ -z "$LXC_CONTAINERS" ]] && return 0
  
  for vmid in $LXC_CONTAINERS; do
    is_running "$vmid" || continue
    info "Restarting $vmid..."
    pct exec "$vmid" -- bash -c 'command -v docker >/dev/null && systemctl restart docker 2>/dev/null; sleep 2' 2>/dev/null || true
    pct exec "$vmid" -- bash -c 'for f in $(find /opt /home /root -name docker-compose.yml 2>/dev/null); do cd $(dirname $f) && (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null) || true; done' 2>/dev/null || true
    log "✓ $vmid restarted"
  done
}

show_summary() {
  section "Post-Upgrade Status"
  echo ""
  
  if [[ $NEEDS_REBOOT_HOST -eq 1 ]]; then
    echo -e "${RED}⚠ HOST NEEDS REBOOT${NC}"
    echo "  New DKMS module requires reboot to load"
    echo "  Command: reboot"
    echo ""
  fi
  
  if [[ ${#NEEDS_REBOOT_CONTAINERS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}⚠ CONTAINERS NEED WORKLOAD RESTART${NC}"
    for vmid in "${NEEDS_REBOOT_CONTAINERS[@]}"; do
      echo "  - LXC $vmid (Docker restarted, GPU apps may need reconnect)"
    done
    echo ""
  fi
  
  [[ $NEEDS_REBOOT_HOST -eq 0 ]] && [[ ${#NEEDS_REBOOT_CONTAINERS[@]} -eq 0 ]] && echo -e "${GREEN}✓ No reboot required!${NC}" && echo ""
  
  echo -e "${CYAN}Log: $LOG_FILE${NC}"
}

main() {
  section "NVIDIA Driver Upgrade (No Reboot)"
  log "Started"
  echo ""
  
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY RUN MODE - No changes will be made"
    warn "Results will be logged to: $LOG_FILE"
    echo ""
  fi
  
  echo "[DEBUG] About to check root..."
  check_root
  echo "[DEBUG] Root check passed, checking deps..."
  check_deps
  echo "[DEBUG] Deps check passed, checking Proxmox..."
  check_proxmox
  echo "[DEBUG] Proxmox check passed, checking NVIDIA..."
  check_nvidia
  echo "[DEBUG] All checks passed!"
  
  [[ -z "$NEW_VERSION" ]] && NEW_VERSION=$(get_latest_version) && log "Auto-detected: $NEW_VERSION"
  
  local curr
  curr=$(get_current_version)
  
  section "Version Info"
  echo -e "  Current:  ${YELLOW}$curr${NC}"
  echo -e "  Target:   ${GREEN}$NEW_VERSION${NC}"
  echo ""
  
  [[ "$curr" == "$NEW_VERSION" ]] && echo -e "${GREEN}✓ Already on latest${NC}" || compare_versions "$NEW_VERSION" "$curr" && echo -e "${GREEN}⬆ Upgrade available${NC}" || echo -e "${YELLOW}⬇ Downgrade${NC}"
  echo ""
  
  read -p "Continue? (yes/no): " -r
  [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]] && log "Cancelled" && exit 0
  
  [[ "$AUTO_DOWNLOAD" == "true" ]] && [[ "$DRY_RUN" == "false" ]] && download_driver "$NEW_VERSION" || DRIVER_FILE="/root/NVIDIA-Linux-x86_64-${NEW_VERSION}.run"
  [[ ! -f "$DRIVER_FILE" ]] && error "Driver not found: $DRIVER_FILE"
  
  detect_lxc_containers
  
  upgrade_host
  
  [[ -n "$LXC_CONTAINERS" ]] && for vmid in $LXC_CONTAINERS; do upgrade_container "$vmid"; done
  
  [[ -n "$LXC_CONTAINERS" ]] && restart_workloads
  
  section "Host Status"
  nvidia-smi | head -15
  
  show_summary
  log "Complete"
}

main "$@"
