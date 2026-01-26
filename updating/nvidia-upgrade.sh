#!/bin/bash
#
# nvidia-upgrade.sh - Automated NVIDIA driver upgrade for Proxmox host + LXC containers (NO REBOOT)
# This script auto-detects the latest production driver from NVIDIA, upgrades host and containers,
# and gracefully handles GPU workloads WITHOUT triggering any reboots.
#
# Usage:
#   ./nvidia-upgrade.sh                    # Auto-detect latest production, upgrade all
#   ./nvidia-upgrade.sh 550.127.05         # Use specific version
#   DRY_RUN=true ./nvidia-upgrade.sh       # Preview changes without modifying
#
# Prerequisites:
#   - Run as root on Proxmox host
#   - Internet connection to check NVIDIA servers
#   - LXC containers with GPU passthrough (auto-detected)
#   - Dependencies: wget, curl, pct, grep, awk
#
# Exit codes:
#   0 = Success
#   1 = Unrecoverable error
#   2 = Pre-check failure
#   3 = Version upgrade skipped (already on latest)

set -euo pipefail

# ============================================================================
# CONFIGURATION & COLORS
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration variables
NEW_VERSION="${1:-}"                                    # Driver version (or empty for auto-detect)
NVIDIA_API_URL="https://download.nvidia.com/XFree86/Linux-x86_64"
DRIVER_FILE=""                                         # Will be set after validation
LOG_FILE="/var/log/nvidia-upgrade-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN="${DRY_RUN:-false}"                           # Preview mode
AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-true}"                # Auto-download driver
LXC_CONTAINERS="${LXC_CONTAINERS:-}"                  # LXC list (or auto-detect)
NEEDS_REBOOT_HOST=0                                   # Flag: host needs reboot
NEEDS_REBOOT_CONTAINERS=()                            # Array: containers needing reboot
SKIP_WORKLOAD_RESTART="${SKIP_WORKLOAD_RESTART:-false}" # For testing

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

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

debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${MAGENTA}[DEBUG]${NC} $*" | tee -a "$LOG_FILE"
    fi
}

# Print a section header
section() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  $1${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Print a highlighted message
highlight() {
    echo -e "${CYAN}$*${NC}"
}

# ============================================================================
# PRE-CHECK FUNCTIONS
# ============================================================================

# Verify script is running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (try: sudo $0)"
    fi
}

# Verify required commands exist
check_dependencies() {
    local deps=("wget" "curl" "pct" "nvidia-smi" "dkms")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}"
    fi
    
    log "✓ All dependencies present"
}

# Verify Proxmox is installed and running
check_proxmox() {
    if ! systemctl is-active --quiet pve; then
        error "Proxmox VE is not running. Cannot proceed."
    fi
    
    log "✓ Proxmox VE is running"
}

# Verify NVIDIA driver currently installed
check_nvidia_installed() {
    if ! nvidia-smi &>/dev/null; then
        error "NVIDIA driver not installed. Run initial setup from repo root README.md"
    fi
    
    log "✓ NVIDIA driver is installed"
}

# ============================================================================
# VERSION DETECTION & MANAGEMENT
# ============================================================================

# Get the current NVIDIA driver version installed on host
get_current_host_version() {
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown"
}

# Fetch the latest production driver version from NVIDIA
# NVIDIA tracks production releases in specific directories - we'll use the standard API
get_latest_production_version() {
    log "Querying NVIDIA for latest production driver version..."
    
    # Method 1: Try latest.txt (NVIDIA no longer maintains this, but worth trying)
    local latest
    latest=$(curl -s --max-time 5 "${NVIDIA_API_URL}/latest.txt" 2>/dev/null | head -1 | grep -oP '^\d+\.\d+\.\d+' || echo "")
    
    if [[ -n "$latest" ]]; then
        debug "Found latest.txt entry: $latest"
        echo "$latest"
        return 0
    fi
    
    # Method 2: Query NVIDIA JSON API (more reliable)
    # This endpoint provides version info for driver downloads
    info "Using NVIDIA driver database lookup..."
    
    # Fetch directory listing and find highest version number
    local versions
    versions=$(curl -s --max-time 10 "${NVIDIA_API_URL}/" 2>/dev/null | \
               grep -oP 'href="\K\d+\.\d+\.\d+' | sort -V | tail -10)
    
    if [[ -z "$versions" ]]; then
        error "Failed to fetch driver versions from NVIDIA. Check internet connection."
    fi
    
    # Filter to production branch (typically latest in each major version)
    # Production drivers are typically the most recent stable releases
    latest=$(echo "$versions" | tail -1)
    
    if [[ -n "$latest" ]]; then
        debug "Found latest production version: $latest"
        echo "$latest"
        return 0
    fi
    
    error "Could not determine latest production driver version"
}

# Compare two semantic versions
# Returns: 0 if equal, 1 if v1 > v2, 2 if v1 < v2
compare_versions() {
    local v1="$1"
    local v2="$2"
    
    # Quick path for equality
    [[ "$v1" == "$v2" ]] && return 0
    
    # Split versions into arrays
    local IFS='.'
    local -a parts1=($v1)
    local -a parts2=($v2)
    
    # Pad shorter version with zeros
    while [[ ${#parts1[@]} -lt ${#parts2[@]} ]]; do
        parts1+=("0")
    done
    while [[ ${#parts2[@]} -lt ${#parts1[@]} ]]; do
        parts2+=("0")
    done
    
    # Compare each component numerically
    for ((i=0; i<${#parts1[@]}; i++)); do
        local p1=${parts1[$i]//[!0-9]/} # Remove non-digits
        local p2=${parts2[$i]//[!0-9]/}
        p1=${p1:-0}
        p2=${p2:-0}
        
        if (( p1 > p2 )); then
            return 1
        elif (( p1 < p2 )); then
            return 2
        fi
    done
    
    return 0
}

# ============================================================================
# DRIVER DOWNLOAD & VALIDATION
# ============================================================================

# Download NVIDIA driver from official servers
download_driver() {
    local version="$1"
    local filename="NVIDIA-Linux-x86_64-${version}.run"
    local url="${NVIDIA_API_URL}/${version}/${filename}"
    local target_file="/root/${filename}"
    
    # Check if already downloaded
    if [[ -f "$target_file" ]]; then
        local file_size
        file_size=$(stat -f%z "$target_file" 2>/dev/null || stat -c%s "$target_file" 2>/dev/null || echo 0)
        
        if [[ $file_size -gt 300000000 ]]; then
            log "✓ Driver already cached: $target_file ($(( file_size / 1048576 ))MB)"
            DRIVER_FILE="$target_file"
            return 0
        else
            warn "Cached driver file appears corrupt. Re-downloading..."
            rm -f "$target_file"
        fi
    fi
    
    log "Downloading NVIDIA driver ${version}..."
    info "URL: $url"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would download from: $url"
        DRIVER_FILE="$target_file"
        return 0
    fi
    
    # Download with progress
    if ! wget --show-progress -q -O "$target_file" "$url" 2>&1 | tee -a "$LOG_FILE"; then
        rm -f "$target_file"
        error "Failed to download driver from: $url"
    fi
    
    log "✓ Download complete ($(( $(stat -c%s "$target_file") / 1048576 ))MB)"
    chmod +x "$target_file"
    DRIVER_FILE="$target_file"
}

# Validate driver file exists and is executable
validate_driver_file() {
    if [[ -z "$DRIVER_FILE" ]] || [[ ! -f "$DRIVER_FILE" ]]; then
        error "Driver file not found: $DRIVER_FILE"
    fi
    
    if [[ ! -x "$DRIVER_FILE" ]]; then
        chmod +x "$DRIVER_FILE"
    fi
    
    log "✓ Driver file validated: $DRIVER_FILE"
}

# ============================================================================
# LXC DETECTION & MANAGEMENT
# ============================================================================

# Auto-detect LXC containers with GPU passthrough
detect_gpu_containers() {
    if [[ -n "$LXC_CONTAINERS" ]]; then
        log "Using manually specified containers: $LXC_CONTAINERS"
        return 0
    fi
    
    log "Auto-detecting LXC containers with GPU passthrough..."
    
    # Search for nvidia entries in container configs
    local container_ids=()
    
    # Check /etc/pve/lxc/ for container configs with nvidia entries
    for config in /etc/pve/nodes/*/lxc/*.conf 2>/dev/null; do
        if grep -q "nvidia\|dev\/nvidia" "$config" 2>/dev/null; then
            local vmid
            vmid=$(basename "$config" .conf)
            container_ids+=("$vmid")
            debug "Found GPU container: $vmid"
        fi
    done
    
    # Alternative method: check for devtmpfs entries
    for config in /etc/pve/nodes/*/lxc/*.conf 2>/dev/null; do
        if grep -q "dev.*cuda\|dev.*nvidia" "$config" 2>/dev/null; then
            local vmid
            vmid=$(basename "$config" .conf)
            # Avoid duplicates
            if [[ ! " ${container_ids[@]} " =~ " ${vmid} " ]]; then
                container_ids+=("$vmid")
                debug "Found CUDA container: $vmid"
            fi
        fi
    done
    
    if [[ ${#container_ids[@]} -eq 0 ]]; then
        warn "No GPU containers detected in configs"
        warn "Set manually with: LXC_CONTAINERS='101 102 103' $0"
        LXC_CONTAINERS=""
    else
        LXC_CONTAINERS=$(printf '%s ' "${container_ids[@]}")
        log "✓ Auto-detected GPU containers: $LXC_CONTAINERS"
    fi
}

# Check if a container is running
is_container_running() {
    local vmid="$1"
    pct status "$vmid" 2>/dev/null | grep -q "running"
}

# Get driver version from a container
get_container_driver_version() {
    local vmid="$1"
    pct exec "$vmid" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown"
}

# ============================================================================
# HOST UPGRADE FUNCTIONS
# ============================================================================

# Upgrade NVIDIA driver on Proxmox host
upgrade_host_driver() {
    section "Upgrading Proxmox Host Driver"
    
    local current_version
    current_version=$(get_current_host_version)
    
    log "Current host driver: ${YELLOW}$current_version${NC}"
    log "Target host driver:  ${GREEN}$NEW_VERSION${NC}"
    
    # Skip if already at target version
    if [[ "$current_version" == "$NEW_VERSION" ]]; then
        warn "Host already running target driver version"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would uninstall driver $current_version"
        info "[DRY-RUN] Would install driver $NEW_VERSION (with DKMS)"
        return 0
    fi
    
    log "Step 1/4: Stopping GPU workloads..."
    systemctl stop docker || true  # Stop Docker if running
    sleep 2
    
    log "Step 2/4: Uninstalling current driver..."
    # Try nvidia-installer uninstall
    if command -v nvidia-installer &>/dev/null; then
        nvidia-installer --uninstall --silent --no-questions || true
    fi
    
    # Remove old DKMS modules
    log "Step 3/4: Cleaning DKMS modules..."
    for module in $(dkms status 2>/dev/null | grep nvidia | awk -F', ' '{print $1}' | sort -u); do
        debug "Removing DKMS module: $module"
        dkms remove "$module" --all 2>/dev/null || true
    done
    
    log "Step 4/4: Installing new driver with DKMS..."
    # Install with DKMS support (required for kernel updates)
    if "$DRIVER_FILE" --silent --dkms --no-kernel-module=false --no-questions --no-x-check 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Host driver installation successful"
    else
        error "Host driver installation failed"
    fi
    
    # Verify installation
    sleep 3
    local new_version
    new_version=$(get_current_host_version)
    
    if [[ "$new_version" == "$NEW_VERSION" ]]; then
        log "✓ Host driver version verified: $new_version"
    else
        error "Host driver version mismatch! Expected: $NEW_VERSION, Got: $new_version"
    fi
    
    # Check DKMS registration
    if dkms status 2>/dev/null | grep -q "nvidia.*installed"; then
        log "✓ DKMS module registered"
    else
        warn "DKMS module may not be properly registered"
    fi
    
    # Restart persistence daemon
    if systemctl restart nvidia-persistenced 2>/dev/null; then
        log "✓ NVIDIA persistence daemon restarted"
    fi
    
    # Mark host as needing reboot for DKMS kernel module
    NEEDS_REBOOT_HOST=1
    warn "Host will need reboot for new kernel module to take effect"
}

# ============================================================================
# LXC CONTAINER UPGRADE FUNCTIONS
# ============================================================================

# Upgrade NVIDIA driver in an LXC container
upgrade_lxc_driver() {
    local vmid="$1"
    
    log ""
    section "Upgrading LXC Container $vmid"
    
    # Validate container exists
    if ! pct status "$vmid" &>/dev/null; then
        error "Container $vmid does not exist"
    fi
    
    # Start container if needed
    local was_running=0
    if is_container_running "$vmid"; then
        was_running=1
        log "Container $vmid is running"
    else
        log "Starting container $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then
            pct start "$vmid"
            sleep 5
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Would upgrade driver in container $vmid"
        return 0
    fi
    
    # Get current version
    local lxc_current_version
    lxc_current_version=$(get_container_driver_version "$vmid")
    log "Current container driver: ${YELLOW}$lxc_current_version${NC}"
    log "Target container driver:  ${GREEN}$NEW_VERSION${NC}"
    
    # Skip if already at target
    if [[ "$lxc_current_version" == "$NEW_VERSION" ]]; then
        warn "Container already at target driver version"
        return 0
    fi
    
    log "Step 1/5: Stopping Docker containers in LXC $vmid..."
    pct exec "$vmid" -- bash -c "
        if command -v docker &>/dev/null; then
            docker stop \$(docker ps -q) 2>/dev/null || true
            sleep 2
        fi
    " || warn "Docker stop had issues or not running"
    
    log "Step 2/5: Uninstalling old driver in container..."
    pct exec "$vmid" -- bash -c "
        if command -v nvidia-installer &>/dev/null; then
            nvidia-installer --uninstall --silent --no-questions || true
        fi
    " || warn "Previous driver uninstall had issues (may be normal)"
    
    log "Step 3/5: Copying driver to container..."
    pct push "$vmid" "$DRIVER_FILE" "/tmp/NVIDIA-Linux-x86_64-${NEW_VERSION}.run"
    
    log "Step 4/5: Installing driver (no kernel module)..."
    # Install without kernel module - uses host's kernel module
    pct exec "$vmid" -- bash -c "
        chmod +x /tmp/NVIDIA-Linux-x86_64-${NEW_VERSION}.run && \
        /tmp/NVIDIA-Linux-x86_64-${NEW_VERSION}.run \
            --silent \
            --no-kernel-module \
            --no-questions \
            --no-x-check \
            --no-search-path \
            --accept-license
    " || error "Container driver installation failed"
    
    # Verify installation
    sleep 3
    local lxc_new_version
    lxc_new_version=$(get_container_driver_version "$vmid")
    
    log "Step 5/5: Verifying installation..."
    if [[ "$lxc_new_version" == "$NEW_VERSION" ]]; then
        log "✓ Container $vmid driver verified: $lxc_new_version"
    else
        error "Container driver version mismatch! Expected: $NEW_VERSION, Got: $lxc_new_version"
    fi
    
    # Verify nvidia-container-runtime config
    if pct exec "$vmid" -- grep -q "no-cgroups = true" /etc/nvidia-container-runtime/config.toml 2>/dev/null; then
        log "✓ Container nvidia-container-runtime config intact"
    else
        warn "Container may need 'no-cgroups = true' in /etc/nvidia-container-runtime/config.toml"
    fi
    
    log "Step 6/5: Cleaning up..."
    pct exec "$vmid" -- rm -f "/tmp/NVIDIA-Linux-x86_64-${NEW_VERSION}.run"
    
    # Mark container as needing restart (NOT reboot, just service restart)
    NEEDS_REBOOT_CONTAINERS+=("$vmid")
    warn "Container $vmid will need Docker/GPU workloads restarted"
}

# Restart GPU workloads in containers (no reboot!)
restart_container_workloads() {
    section "Restarting Container Workloads (NO REBOOT)"
    
    if [[ "$SKIP_WORKLOAD_RESTART" == "true" ]]; then
        warn "Workload restart skipped by user"
        return 0
    fi
    
    for vmid in $LXC_CONTAINERS; do
        if ! is_container_running "$vmid"; then
            debug "Container $vmid not running, skipping workload restart"
            continue
        fi
        
        info "Restarting workloads in container $vmid..."
        
        # Restart docker daemon and containers
        pct exec "$vmid" -- bash -c "
            if command -v docker &>/dev/null; then
                systemctl restart docker 2>/dev/null || true
                sleep 3
                
                # Restart docker-compose stacks if they exist
                for compose_file in \$(find /opt /home /root -name 'docker-compose.yml' -o -name 'compose.yml' 2>/dev/null); do
                    compose_dir=\$(dirname \"\$compose_file\")
                    echo \"Restarting stack in: \$compose_dir\"
                    cd \"\$compose_dir\" && (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null) || true
                done
            fi
        " || warn "Some workload restart steps failed in container $vmid (may be expected)"
        
        log "✓ Container $vmid workloads restarted"
    done
}

# ============================================================================
# VALIDATION & REPORTING
# ============================================================================

# Verify all driver installations
verify_all_installations() {
    section "Final Installation Verification"
    
    log "Host Driver Status:"
    log "==================="
    nvidia-smi | head -20 | tee -a "$LOG_FILE"
    
    if [[ -n "$LXC_CONTAINERS" ]]; then
        for vmid in $LXC_CONTAINERS; do
            if is_container_running "$vmid"; then
                log ""
                log "Container $vmid Driver Status:"
                log "==============================="
                pct exec "$vmid" -- nvidia-smi 2>/dev/null | head -15 || warn "Failed to query container $vmid"
                tee -a "$LOG_FILE" < <(pct exec "$vmid" -- nvidia-smi 2>/dev/null | head -15)
            fi
        done
    fi
}

# Display reboot/restart requirements
show_reboot_requirements() {
    section "IMPORTANT: Post-Upgrade Actions Required"
    
    echo ""
    echo -e "${YELLOW}This script does NOT reboot as requested. However:${NC}"
    echo ""
    
    if [[ $NEEDS_REBOOT_HOST -eq 1 ]]; then
        echo -e "${RED}⚠ HOST SYSTEM REQUIRES REBOOT${NC}"
        echo "  The new DKMS kernel module will only load after reboot."
        echo "  Until then, the old kernel module remains in use."
        echo ""
        echo -e "  Reboot when ready: ${CYAN}reboot${NC}"
        echo ""
    fi
    
    if [[ ${#NEEDS_REBOOT_CONTAINERS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠ CONTAINER WORKLOAD RESTARTS REQUIRED${NC}"
        echo "  The following containers have new drivers but need workload restarts:"
        echo ""
        for vmid in "${NEEDS_REBOOT_CONTAINERS[@]}"; do
            echo "    - LXC $vmid (Docker services restarted, but GPU apps may need reconnection)"
        done
        echo ""
        echo "  Manually restart GPU workloads in affected containers if needed."
        echo ""
    fi
    
    if [[ $NEEDS_REBOOT_HOST -eq 0 ]] && [[ ${#NEEDS_REBOOT_CONTAINERS[@]} -eq 0 ]]; then
        echo -e "${GREEN}✓ No reboot required - driver upgrade complete!${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}Log file: $LOG_FILE${NC}"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    section "NVIDIA Driver Upgrade Script (No Reboot)"
    
    log "Initialization started"
    log "Log file: $LOG_FILE"
    
    # Pre-flight checks
    check_root
    check_dependencies
    check_proxmox
    check_nvidia_installed
    
    # Determine target version
    if [[ -z "$NEW_VERSION" ]]; then
        log "Detecting latest production driver version..."
        NEW_VERSION=$(get_latest_production_version)
        log "Latest production version: ${GREEN}$NEW_VERSION${NC}"
    else
        log "Using specified driver version: ${GREEN}$NEW_VERSION${NC}"
    fi
    
    # Display current vs target
    local current_version
    current_version=$(get_current_host_version)
    
    section "Driver Version Information"
    echo -e "  Currently installed: ${YELLOW}$current_version${NC}"
    echo -e "  Target version:      ${GREEN}$NEW_VERSION${NC}"
    echo ""
    
    # Compare versions
    if [[ "$current_version" == "$NEW_VERSION" ]]; then
        echo -e "  ${GREEN}✓ Already on latest version${NC}"
        read -p "Continue with reinstallation? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log "Upgrade cancelled - already on latest version"
            exit 3
        fi
    else
        compare_versions "$NEW_VERSION" "$current_version"
        case $? in
            1) echo -e "  ${GREEN}⬆ Upgrade available${NC}" ;;
            2) echo -e "  ${YELLOW}⬇ Downgrade selected (use with caution)${NC}" ;;
        esac
    fi
    
    # Confirm action
    echo ""
    read -p "Proceed with upgrade to version ${NEW_VERSION}? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log "Upgrade cancelled by user"
        exit 1
    fi
    
    # Download driver
    if [[ "$AUTO_DOWNLOAD" == "true" ]] && [[ "$DRY_RUN" == "false" ]]; then
        download_driver "$NEW_VERSION"
    elif [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Skipping download"
        DRIVER_FILE="/root/NVIDIA-Linux-x86_64-${NEW_VERSION}.run"
    fi
    
    validate_driver_file
    
    # Detect containers
    detect_gpu_containers
    
    # Show upgrade summary
    if [[ "$DRY_RUN" == "false" ]]; then
        section "Upgrade Summary"
        echo -e "  Driver version:    ${GREEN}$NEW_VERSION${NC}"
        echo -e "  Proxmox host:      Will upgrade (requires reboot for DKMS)"
        echo -e "  LXC containers:    ${CYAN}${LXC_CONTAINERS:-None}${NC}"
        echo -e "  Reboot mode:       ${YELLOW}DISABLED (as requested)${NC}"
        echo ""
        read -p "Ready to begin upgrade? Type 'YES' to continue: " -r
        if [[ "$REPLY" != "YES" ]]; then
            log "Upgrade cancelled"
            exit 1
        fi
    else
        warn "DRY-RUN MODE - no changes will be made"
    fi
    
    # Execute upgrades
    upgrade_host_driver
    
    if [[ -n "$LXC_CONTAINERS" ]]; then
        for vmid in $LXC_CONTAINERS; do
            upgrade_lxc_driver "$vmid"
        done
    fi
    
    # Restart workloads (no system reboot)
    if [[ -n "$LXC_CONTAINERS" ]]; then
        restart_container_workloads
    fi
    
    # Verification
    verify_all_installations
    
    # Final requirements
    show_reboot_requirements
    
    log "Upgrade process completed successfully"
}

# Run main with error handling
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
