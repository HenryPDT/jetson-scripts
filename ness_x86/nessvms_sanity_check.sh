#!/bin/bash
#
# NessVMS Sanity Check Script (x86)
# Performs comprehensive system checks and configuration for NessVMS x86 devices.
#
# Usage:
#   ./nessvms_sanity_check.sh [--help]
#
# Requirements:
#   - Sudo access
#   - .secrets file OR environment variables for Remote.it registration
#
set -o pipefail

# --- Cleanup Trap ---
TEMP_FILES=()
cleanup() {
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null
    done
}
trap cleanup EXIT

# --- Usage ---
show_usage() {
    echo "Usage: $0 [--help]"
    echo ""
    echo "Performs comprehensive system checks and configuration for NessVMS x86 devices."
    echo ""
    echo "Options:"
    echo "  --help    Show this help message and exit"
    echo ""
    echo "Secrets can be provided via environment variable or .secrets file:"
    echo "  REMOTEIT_REGISTRATION_CODE"
    exit 0
}

# Handle --help
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    show_usage
fi

# --- Script Directory ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || echo ".")"

# --- Load Secrets ---
# Priority: 1) Environment variables, 2) .secrets file
# This enables curl | bash with inline env vars:
#   REMOTEIT_REGISTRATION_CODE="xxx" curl -sL URL | bash

SECRETS_FILE="${SCRIPT_DIR}/.secrets"

# Only source .secrets if it exists AND we're missing required env vars
if [[ -z "${REMOTEIT_REGISTRATION_CODE:-}" ]]; then
    if [[ -f "$SECRETS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$SECRETS_FILE"
    fi
fi

# Note: REMOTEIT_REGISTRATION_CODE is optional - script will warn but continue

# --- Configuration ---
# Minimum acceptable free space on the detected ~1TB drive in Gigabytes (GB)
MIN_SSD_FREE_GB=100 # Default: 100GB

# NX Witness specific version
NX_INSTALLER_DEB="nxwitness-server-5.1.1.37512-linux_x64.deb"
NX_INSTALLER_URL="https://updates.networkoptix.com/default/5.1.1.37512/linux/${NX_INSTALLER_DEB}"
NX_SERVICE_NAME="networkoptix-mediaserver.service"
NX_PACKAGE_NAME="nxwitness-server"

# Remote.it Configuration (already loaded from env/secrets)
REMOTEIT_DEVICE_NAME=""  # Will prompt user if empty

# --- Helper Functions ---
Color_Off='\033[0m'       # Text Reset
BRed='\033[1;31m'         # Red
BGreen='\033[1;32m'       # Green
BYellow='\033[1;33m'      # Yellow
BBlue='\033[1;34m'        # Blue
BPurple='\033[1;35m'      # Purple

print_info() {
  echo -e "${BBlue}[INFO]${Color_Off} $1"
}

print_success() {
  echo -e "${BGreen}[SUCCESS]${Color_Off} $1"
}

print_warning() {
  echo -e "${BYellow}[WARNING]${Color_Off} $1"
}

print_error() {
  echo -e "${BRed}[ERROR]${Color_Off} $1"
}

print_action() {
  echo -e "${BPurple}[ACTION REQUIRED]${Color_Off} $1"
}

# --- Result Tracking ---
CHECK_NAMES=()
CHECK_RESULTS=()
SUCCESS_COUNT=0
FAILURE_COUNT=0

record_result() {
    local name="$1"
    local status="$2" # 0 for success, 1 for failure, 2 for warning/action needed
    CHECK_NAMES+=("$name")
    CHECK_RESULTS+=("$status")
    if [ "$status" -eq 0 ]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
    fi
}

preflight_checks() {
    print_info "Running Preflight Checks..."
    local errors=0

    # 1. Sudo Check
    print_info "Verifying sudo access..."
    if ! sudo -v &> /dev/null; then
        print_error "Sudo access required for many checks."
        errors=$((errors + 1))
    else
        print_success "Sudo access verified."
    fi

    # 2. Internet Check
    print_info "Verifying internet connectivity..."
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        print_warning "No internet connectivity detected. Some downloads/installations may fail."
    else
        print_success "Internet connectivity verified."
    fi
    # 3. Essential Tools
    print_info "Ensuring essential tools (nano, wget, curl) are installed..."
    install_required_tools nano wget curl

    if [ $errors -gt 0 ]; then
        print_error "Preflight checks failed. Please ensure you have sudo privileges."
        exit 1
    fi
}

print_summary() {
    echo ""
    echo "========================================"
    echo -e "${BBlue}      SANITY CHECK SUMMARY${Color_Off}"
    echo "========================================"
    
    for i in "${!CHECK_NAMES[@]}"; do
        local name="${CHECK_NAMES[$i]}"
        local res="${CHECK_RESULTS[$i]}"
        local status_text=""
        
        case "$res" in
            0) status_text="${BGreen}[PASS]${Color_Off}" ;;
            1) status_text="${BRed}[FAIL]${Color_Off}" ;;
            *) status_text="${BYellow}[WARN]${Color_Off}" ;;
        esac
        
        printf "%-35s %b\n" "$name" "$status_text"
    done
    
    echo "----------------------------------------"
    echo -e "Total Checks: ${#CHECK_NAMES[@]}"
    echo -e "${BGreen}Passed:       $SUCCESS_COUNT${Color_Off}"
    echo -e "${BRed}Failed/Warn:  $FAILURE_COUNT${Color_Off}"
    echo "========================================"
    
    if [ $FAILURE_COUNT -gt 0 ]; then
        print_warning "One or more checks failed or required action. Review logs above."
    else
        print_success "All checks passed successfully!"
    fi
}

# --- Utility Function: Install Required Tools ---
install_required_tools() {
    local tools=("$@")
    local missing_tools=()
    
    # Check which tools are missing
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    # If no tools are missing, return success
    if [ ${#missing_tools[@]} -eq 0 ]; then
        return 0
    fi
    
    # Try to install missing tools
    print_info "Installing missing tools: ${missing_tools[*]}"
    
    # Update package list first
    if ! sudo apt update; then
        print_error "Failed to update package list."
        return 1
    fi
    
    # Install missing tools
    if ! sudo apt install -y "${missing_tools[@]}"; then
        print_error "Failed to install required tools: ${missing_tools[*]}"
        print_action "Please install manually: ${BYellow}sudo apt update && sudo apt install ${missing_tools[*]}${Color_Off}"
        return 1
    fi
    
    print_success "Successfully installed: ${missing_tools[*]}"
    return 0
}

# --- Check Functions ---

check_system_time() {
    print_info "Checking System Date & Time..."
    local current_system_time=$(date)
    if [ -n "$current_system_time" ]; then
        print_success "Current System Time: ${current_system_time}"
    else
        print_error "Failed to get current system time using 'date'."
        return 1
    fi
    return 0
}

check_system_info() {
  print_info "Checking System Information..."
  local errors=0

  # Get OS information
  if [ -f /etc/os-release ]; then
    local os_name=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
    print_success "Operating System: ${os_name}"
  else
    print_warning "Could not determine OS information."
    errors=$((errors + 1))
  fi

  # Get kernel version
  local kernel_version=$(uname -r)
  print_success "Kernel Version: ${kernel_version}"

  # Get CPU information
  local cpu_model=$(grep 'model name' /proc/cpuinfo | head -n1 | cut -d: -f2 | sed 's/^ *//')
  local cpu_cores=$(grep -c '^processor' /proc/cpuinfo)
  if [ -n "$cpu_model" ]; then
    print_success "CPU: ${cpu_model} (${cpu_cores} cores)"
  else
    print_success "CPU Cores: ${cpu_cores}"
  fi

  # Get memory information
  local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local total_mem_gb=$(awk -v k="$total_mem_kb" 'BEGIN { printf "%.2f", k / (1024*1024) }')
  print_success "Total Memory: ${total_mem_gb} GB"

  # Get hostname
  local hostname=$(hostname)
  print_success "Hostname: ${hostname}"

  return $errors
}

check_gpu_info() {
    print_info "Checking GPU Information..."
    if command -v nvidia-smi &> /dev/null; then
        local gpu_info=$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits)
        print_success "NVIDIA GPU Detected: ${gpu_info}"
        return 0
    else
        # Check for any PCI VGA controller
        local vga_info=$(lspci | grep -i vga)
        if [ -n "$vga_info" ]; then
            print_info "VGA Controller: ${vga_info}"
            print_warning "Non-NVIDIA or driver-less GPU detected."
            return 2
        else
            print_warning "No dedicated GPU detected via lspci."
            return 2
        fi
    fi
}

check_htop() {
  print_info "Checking HTOP (system monitoring tool)..."
  if command -v htop &> /dev/null; then
    print_success "HTOP command found."
    return 0
  else
    print_warning "HTOP command not found."
    if install_required_tools htop; then
      return 0
    else
      return 1
    fi
  fi
}

check_ssd() {
    print_info "Checking for ~1TB SSD..."
    local min_bytes=$((900 * 1024 * 1024 * 1024))
    local max_bytes=$((1100 * 1024 * 1024 * 1024))
    local target_device=""
    local target_mountpoint=""
    local errors=0

    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size_bytes=$(echo "$line" | awk '{print $2}')
        if [[ "$size_bytes" -ge "$min_bytes" ]] && [[ "$size_bytes" -le "$max_bytes" ]]; then
            target_device="$name"
            local size_gib=$(awk -v size="$size_bytes" 'BEGIN { printf "%.1f GiB", size / (1024*1024*1024) }')
            print_success "Found potential ~1TB disk: /dev/${target_device} (${size_gib})"
            break
        fi
    done < <(lsblk -bndo NAME,SIZE)

    if [ -z "$target_device" ]; then
        print_error "No disk device found with size between 900GiB and 1100GiB."
        print_action "Ensure a ~1TB drive is connected and recognized (check 'lsblk')."
        return 1
    fi

    target_mountpoint=""
    # Check partitions for the target device
    while IFS= read -r line; do
        local part_name=$(echo "$line" | awk '{print $1}')
        local mp=$(echo "$line" | awk '{print $2}')
        if [ -n "$mp" ] && [ "$mp" != "[SWAP]" ]; then
            target_mountpoint="$mp"
            print_info "Found mounted partition ${part_name} at ${target_mountpoint}"
            break
        fi
    done < <(lsblk -lno NAME,MOUNTPOINT "/dev/${target_device}")

    if [ -z "$target_mountpoint" ]; then
        print_error "Could not find a mounted partition for disk /dev/${target_device}."
        print_action "Ensure the drive is partitioned, formatted, and mounted."
        return 1
    fi

    if ! mountpoint -q "$target_mountpoint"; then
        print_error "Path ${target_mountpoint} is not currently a valid mount point."
        return 1
    fi

    local test_file="${target_mountpoint}/.sanity_check_$(date +%s)"
    print_info "Performing basic write test on ${target_mountpoint} (using sudo)..."
    if sudo touch "$test_file" &> /dev/null; then
        print_success "Basic health check (write permission) passed."
        sudo rm "$test_file" &> /dev/null
    else
        print_error "Basic health check (write permission) failed for ${target_mountpoint}."
        errors=$((errors + 1))
    fi

    local available_gb=$(df -BG "$target_mountpoint" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ "$available_gb" =~ ^[0-9]+$ ]]; then
        print_info "Available space on ${target_mountpoint}: ${available_gb} GB."
        if [ "$available_gb" -lt "$MIN_SSD_FREE_GB" ]; then
            print_warning "Available space (${available_gb}GB) < minimum ${MIN_SSD_FREE_GB}GB."
            errors=$((errors + 1))
        else
            print_success "Sufficient free space available (${available_gb}GB >= ${MIN_SSD_FREE_GB}GB)."
        fi
    else
        print_error "Could not determine available space on ${target_mountpoint}."
        errors=$((errors + 1))
    fi

    return $errors
}

check_nx_witness() {
    print_info "Checking NX Witness Media Server..."

    if sudo systemctl status "$NX_SERVICE_NAME" &> /dev/null; then
        print_info "NX Witness service unit found. Ensuring it is running..."

        if ! systemctl is-active --quiet "$NX_SERVICE_NAME"; then
            print_info "Service is not running. Attempting to start..."
            sudo systemctl start "$NX_SERVICE_NAME"
            sleep 3
        fi

        if systemctl is-active --quiet "$NX_SERVICE_NAME"; then
            print_success "NX Witness service (${NX_SERVICE_NAME}) is active and running."
            return 0
        else
            print_error "NX Witness service (${NX_SERVICE_NAME}) failed to become active."
            return 1
        fi
    else
        print_warning "NX Witness service (${NX_SERVICE_NAME}) unit file not found."
        
        # Check for installer
        if [ -f "$NX_INSTALLER_DEB" ]; then
            print_info "Installer found: ${NX_INSTALLER_DEB}. Installing..."
            if sudo apt install -y "./${NX_INSTALLER_DEB}"; then
                print_success "NX Witness installed successfully."
                sudo systemctl start "$NX_SERVICE_NAME"
                return 0
            else
                print_error "Failed to install NX Witness package."
                return 1
            fi
        else
            print_warning "Installer ${NX_INSTALLER_DEB} not found locally. Attempting download..."
            if wget --quiet --show-progress "$NX_INSTALLER_URL"; then
                print_success "Successfully downloaded ${NX_INSTALLER_DEB}."
                if sudo apt install -y "./${NX_INSTALLER_DEB}"; then
                    print_success "NX Witness installed successfully."
                    sudo systemctl start "$NX_SERVICE_NAME"
                    return 0
                else
                    print_error "Failed to install NX Witness."
                    return 1
                fi
            else
                print_error "Failed to download installer from ${NX_INSTALLER_URL}."
                return 1
            fi
        fi
    fi
}

check_docker_group() {
    print_info "Checking Docker group membership..."
    
    if ! getent group docker > /dev/null 2>&1; then
        print_warning "Docker group does not exist. Docker may not be installed."
        return 2
    fi
    
    if groups | grep -q "\bdocker\b"; then
        print_success "User ${USER} is already in the docker group."
        return 0
    else
        print_warning "User ${USER} is not in the docker group. Adding..."
        if sudo usermod -aG docker "$USER"; then
            print_success "Added ${USER} to docker group. Note: Log out/in required."
            return 0
        else
            print_error "Failed to add user to docker group."
            return 1
        fi
    fi
}

register_with_remoteit() {
    print_info "Checking Remote.it integration..."
    local registration_code="${REMOTEIT_REGISTRATION_CODE}"
    local remoteit_config="/etc/remoteit/config.json"
    
    if [ -z "$registration_code" ]; then
        print_warning "Remote.it registration code not configured."
        return 2
    fi
    
    if [ -f "$remoteit_config" ] || sudo systemctl --quiet is-active 'remoteit@*.service'; then
        print_success "Remote.it is already configured/running."
        return 0
    fi
    
    print_info "Remote.it is not configured. Proceeding with registration..."
    
    local device_name="${REMOTEIT_DEVICE_NAME}"
    if [ -z "$device_name" ]; then
        local default_name="$(hostname)-$(uname -m)"
        echo -ne "${BPurple}[INPUT REQUIRED]${Color_Off} Enter Remote.it device name (default: ${default_name}): "
        read -r device_name
        device_name="${device_name:-$default_name}"
    fi
    
    # Download and run the Remote.it installer using temp file
    local installer_file
    installer_file=$(mktemp)
    TEMP_FILES+=("$installer_file")  # Add to cleanup list
    
    if curl -L -o "$installer_file" https://downloads.remote.it/remoteit/install_agent.sh; then
        chmod +x "$installer_file"
        if sudo R3_REGISTRATION_CODE="$registration_code" R3_DEVICE_NAME="$device_name" "$installer_file"; then
            print_success "Remote.it registration successful."
            return 0
        else
            print_error "Remote.it registration failed."
            return 1
        fi
    else
        print_error "Failed to download Remote.it installer."
        return 1
    fi
}

# --- Main Script Execution ---
print_info "Starting NESSVMS Sanity Check Script (x86)..."
echo "----------------------------------------"

preflight_checks

echo "----------------------------------------"
check_system_info
record_result "System Information" $?

echo "----------------------------------------"
check_gpu_info
record_result "GPU Check" $?

echo "----------------------------------------"
check_htop
record_result "HTOP Installation" $?

echo "----------------------------------------"
check_ssd
record_result "SSD/Storage Check" $?

echo "----------------------------------------"
check_system_time
record_result "System Time" $?

echo "----------------------------------------"
check_nx_witness
record_result "NX Witness Service" $?

echo "----------------------------------------"
check_docker_group
record_result "Docker Group" $?

echo "----------------------------------------"
register_with_remoteit
record_result "Remote.it Registration" $?

echo "----------------------------------------"
print_summary

exit 0
