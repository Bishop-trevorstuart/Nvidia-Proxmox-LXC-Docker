#!/bin/bash
#
# nvidia-upgrade.sh - Automated NVIDIA driver upgrade for Proxmox host + LXC containers
# Usage: ./nvidia-upgrade.sh [driver-version]
# Example: ./nvidia-upgrade.sh 580.105.08
#          ./nvidia-upgrade.sh  (auto-detects latest version)
#
# Prerequisites:
# - Run as root on Proxmox host
# - Internet connection to check NVIDIA servers
# - LXC containers configured with GPU passthrough
#

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
NEW_VERSION="${1:-}"
NVIDIA_DOWNLOAD_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"
DRIVER_FILE=""
LOG_FILE="/var/log/nvidia-upgrade-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN="${DRY_RUN:-false}"
AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-true}"

# LXC containers with GPU passthrough (auto-detect or manual override)
LXC_CONTAINERS="${LXC_CONTAINERS:-}"

#=============================================================================
# Helper Functions
#=============================================================================

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
    exit 1
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

highlight() {
    echo -e "${CYAN}$*${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

check_dependencies() {
    local deps=("wget" "curl" "pct")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}\nInstall with: apt install ${missing[*]}"
    fi
}

get_latest_nvidia_version() {
    log "Checking NVIDIA servers for latest driver version..."
    
    local latest_version
    
    # Try method 1: latest.txt file
    latest_version=$(curl -s "${NVIDIA_DOWNLOAD_BASE}/latest.txt" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+$' | head -1)
    
    if [[ -z "$latest_version" ]]; then
        # Fallback method 2: Scrape directory listing
        info "Trying alternate method to find latest version..."
        latest_version=$(curl -s "${NVIDIA_DOWNLOAD_BASE}/" | \
                        grep -oP 'href="\K\d+\.\d+\.\d+(?=/)' | \
                        sort -V | tail -1)
    fi
    
    if [[ -z "$latest_version" ]]; then
        error "Failed to detect latest NVIDIA driver version from servers"
    fi
    
    echo "$latest_version"
}

get_current_driver_version() {
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "none"
}

compare_versions() {
    # Returns: 0 if equal, 1 if $1 > $2, 2 if $1 < $2
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    
    local IFS=.
    local i ver1=($1) ver2=($2)
    
    # Fill empty positions with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    
    return 0
}

download_driver() {
    local version="$1"
    local filename="NVIDIA-Linux-x86_64-${version}.run"
    local url="${NVIDIA_DOWNLOAD_BASE}/${version}/${filename}"
    local target_file="/root/${filename}"
    
    if [[ -f "$target_file" ]]; then
        log "Driver file already exists: $target_file"
        
        # Verify it's a valid file (> 100MB)
        local file_size
        file_size=$(stat -f%z "$target_file" 2>/dev/null || stat -c%s "$target_file" 2>/dev/null || echo 0)
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

stop_gpu_workloads() {
    log "Stopping GPU workloads in LXC containers..."
    
    for vmid in $LXC_CONTAINERS; do
        if pct status "$vmid" 2>/dev/null | grep -q "running"; then
            info "Stopping Docker containers in LXC $vmid..."
            if [[ "$DRY_RUN" == "false" ]]; then
                pct exec "$vmid" -- bash -c "command -v docker &>/dev/null && docker stop \$(docker ps -q) 2>/dev/null || true" || warn "Failed to stop Docker in LXC $vmid"
            fi
        fi
    done
}

verify_driver_version() {
    local expected="$1"
    local actual
    actual=$(get_current_driver_version)
    
    if [[ "$actual" == "$expected" ]]; then
        log "✓ Driver version verified: $actual"
        return 0
    else
        error "✗ Driver version mismatch! Expected: $expected, Got: $actual"
    fi
}

#=============================================================================
# Host Upgrade Functions
#=============================================================================

upgrade_host_driver() {
    log "=== UPGRADING PROXMOX HOST DRIVER ==="
    
    local current_version
    current_version=$(get_current_driver_version)
    log "Current driver version: $current_version"
    log "Target driver version: $NEW_VERSION"
    
    if [[ "$current_version" == "$NEW_VERSION" ]]; then
        warn "Host already running target driver version. Skipping host upgrade."
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would uninstall driver: $current_version"
        info "[DRY RUN] Would install driver: $NEW_VERSION"
        return 0
    fi
    
    # Uninstall old driver
    log "Uninstalling old driver..."
    if command -v nvidia-installer &>/dev/null; then
        nvidia-installer --uninstall --silent || warn "nvidia-installer uninstall had issues (may be normal)"
    fi
    
    # Remove old DKMS modules
    log "Cleaning up old DKMS modules..."
    for module in $(dkms status | grep nvidia | awk -F', ' '{print $1"/"$2}'); do
        info "Removing DKMS module: $module"
        dkms remove -m "${module%/*}" -v "${module#*/}" --all 2>/dev/null || true
    done
    
    # Install new driver
    log "Installing new driver with DKMS support..."
    "$DRIVER_FILE" --silent --dkms --no-questions || error "Driver installation failed!"
    
    # Verify installation
    log "Verifying host installation..."
    sleep 2
    verify_driver_version "$NEW_VERSION"
    
    # Check DKMS status
    if dkms status | grep -q "nvidia.*${NEW_VERSION}.*installed"; then
        log "✓ DKMS module registered successfully"
    else
        warn "DKMS module may not be properly registered. Check: dkms status"
    fi
    
    # Verify persistence daemon
    if systemctl is-active --quiet nvidia-persistenced; then
        log "✓ NVIDIA persistence daemon running"
    else
        warn "NVIDIA persistence daemon not running. Starting..."
        systemctl start nvidia-persistenced || warn "Failed to start persistence daemon"
    fi
}

#=============================================================================
# LXC Upgrade Functions
#=============================================================================

upgrade_lxc_driver() {
    local vmid="$1"
    
    log "=== UPGRADING LXC $vmid ==="
    
    # Check if container exists
    if ! pct status "$vmid" &>/dev/null; then
        error "LXC $vmid does not exist"
    fi
    
    # Start container if stopped
    if ! pct status "$vmid" | grep -q "running"; then
        log "Starting LXC $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then
            pct start "$vmid"
            sleep 5
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would upgrade driver in LXC $vmid"
        return 0
    fi
    
    # Get current version in LXC
    local lxc_version
    lxc_version=$(pct exec "$vmid" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    log "Current LXC $vmid driver: $lxc_version"
    
    if [[ "$lxc_version" == "$NEW_VERSION" ]]; then
        warn "LXC $vmid already running target driver. Skipping."
        return 0
    fi
    
    # Uninstall old driver in LXC
    log "Uninstalling old driver in LXC $vmid..."
    pct exec "$vmid" -- bash -c "command -v nvidia-installer &>/dev/null && nvidia-installer --uninstall --silent || true"
    
    # Copy new driver to LXC
    log "Copying driver to LXC $vmid..."
    pct push "$vmid" "$DRIVER_FILE" "/root/NVIDIA-Linux-x86_64-${NEW_VERSION}.run"
    
    # Install driver without kernel module
    log "Installing driver in LXC $vmid..."
    pct exec "$vmid" -- bash -c "chmod +x /root/NVIDIA-Linux-x86_64-${NEW_VERSION}.run && \
                                  /root/NVIDIA-Linux-x86_64-${NEW_VERSION}.run --silent --no-kernel-module --no-questions"
    
    # Verify installation
    sleep 2
    local new_version
    new_version=$(pct exec "$vmid" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    
    if [[ "$new_version" == "$NEW_VERSION" ]]; then
        log "✓ LXC $vmid driver upgraded successfully"
    else
        error "✗ LXC $vmid driver upgrade failed. Expected: $NEW_VERSION, Got: $new_version"
    fi
    
    # Verify no-cgroups setting
    if pct exec "$vmid" -- grep -q "no-cgroups = true" /etc/nvidia-container-runtime/config.toml 2>/dev/null; then
        log "✓ LXC $vmid no-cgroups setting intact"
    else
        warn "LXC $vmid no-cgroups setting may be incorrect!"
    fi
    
    # Test Docker GPU access
    log "Testing Docker GPU access in LXC $vmid..."
    if pct exec "$vmid" -- bash -c "command -v docker &>/dev/null"; then
        if pct exec "$vmid" -- docker run --rm --gpus all nvidia/cuda:12.6.1-base-ubuntu24.04 nvidia-smi &>>"$LOG_FILE"; then
            log "✓ LXC $vmid Docker GPU access verified"
        else
            error "✗ LXC $vmid Docker GPU access test failed!"
        fi
    else
        warn "Docker not found in LXC $vmid, skipping GPU test"
    fi
    
    # Cleanup
    log "Cleaning up LXC $vmid..."
    pct exec "$vmid" -- rm -f "/root/NVIDIA-Linux-x86_64-${NEW_VERSION}.run"
}

restart_lxc_workloads() {
    log "=== RESTARTING LXC WORKLOADS ==="
    
    for vmid in $LXC_CONTAINERS; do
        if pct status "$vmid" | grep -q "running"; then
            info "Restarting Docker Compose stacks in LXC $vmid..."
            if [[ "$DRY_RUN" == "false" ]]; then
                # Find and restart docker-compose stacks
                pct exec "$vmid" -- bash -c "
                    for compose_file in \$(find /opt /home -name 'docker-compose.yml' -o -name 'compose.yml' 2>/dev/null); do
                        compose_dir=\$(dirname \"\$compose_file\")
                        echo \"Restarting stack in: \$compose_dir\"
                        cd \"\$compose_dir\" && docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null || true
                    done
                " || warn "Failed to restart some Docker Compose stacks in LXC $vmid"
            fi
        fi
    done
}

#=============================================================================
# Verification Functions
#=============================================================================

final_verification() {
    log "=== FINAL VERIFICATION ==="
    
    echo ""
    highlight "╔════════════════════════════════════════════════════════════════╗"
    highlight "║                    Host Driver Status                          ║"
    highlight "╚════════════════════════════════════════════════════════════════╝"
    nvidia-smi | tee -a "$LOG_FILE"
    
    for vmid in $LXC_CONTAINERS; do
        if pct status "$vmid" | grep -q "running"; then
            echo ""
            highlight "╔════════════════════════════════════════════════════════════════╗"
            highlight "║                LXC $vmid Driver Status                          "
            highlight "╚════════════════════════════════════════════════════════════════╝"
            pct exec "$vmid" -- nvidia-smi | tee -a "$LOG_FILE"
        fi
    done
    
    echo ""
    log "✓ Upgrade complete! Log saved to: $LOG_FILE"
}

#=============================================================================
# Main Execution
#=============================================================================

main() {
    echo ""
    highlight "╔════════════════════════════════════════════════════════════════╗"
    highlight "║         NVIDIA Driver Upgrade Script for Proxmox + LXC        ║"
    highlight "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    
    log "Starting NVIDIA driver upgrade process"
    log "Log file: $LOG_FILE"
    
    check_root
    check_dependencies
    validate_inputs
    detect_lxc_containers
    
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN MODE - No changes will be made"
    fi
    
    # Final confirmation prompt
    if [[ "$DRY_RUN" == "false" ]]; then
        echo ""
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║                    UPGRADE SUMMARY                             ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  Target driver version: ${GREEN}$NEW_VERSION${NC}"
        echo -e "  Proxmox host:          ${GREEN}Will be upgraded${NC}"
        echo -e "  LXC containers:        ${GREEN}$LXC_CONTAINERS${NC}"
        echo -e "  Driver file:           ${BLUE}$DRIVER_FILE${NC}"
        echo ""
        read -p "Continue with upgrade? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            error "Upgrade cancelled by user"
        fi
    fi
    
    stop_gpu_workloads
    upgrade_host_driver
    
    for vmid in $LXC_CONTAINERS; do
        upgrade_lxc_driver "$vmid"
    done
    
    restart_lxc_workloads
    final_verification
}

# Run main function
main "$@"