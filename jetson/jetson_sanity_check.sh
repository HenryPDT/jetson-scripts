#!/bin/bash
#
# Jetson Sanity Check Script
# Performs comprehensive system checks and configuration for Jetson devices.
#
# Usage:
#   ./jetson_sanity_check.sh [--help]
#
# Requirements:
#   - Sudo access
#   - .secrets file in the same directory (see .secrets.example)
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
    echo "Performs comprehensive system checks and configuration for Jetson devices."
    echo ""
    echo "Options:"
    echo "  --help    Show this help message and exit"
    echo ""
    echo "Requirements:"
    echo "  - Sudo access"
    echo "  - .secrets file in the same directory containing:"
    echo "      CONDUCIVE_GIT_PAT, DOCKER_USER, DOCKER_PASS, REMOTEIT_REGISTRATION_CODE"
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
#   CONDUCIVE_GIT_PAT="xxx" DOCKER_PASS="yyy" ... curl -sL URL | bash

SECRETS_FILE="${SCRIPT_DIR}/.secrets"

# Only source .secrets if it exists AND we're missing required env vars
if [[ -z "${CONDUCIVE_GIT_PAT:-}" || -z "${DOCKER_USER:-}" || -z "${DOCKER_PASS:-}" || -z "${REMOTEIT_REGISTRATION_CODE:-}" ]]; then
    if [[ -f "$SECRETS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$SECRETS_FILE"
    fi
fi

# Validate required secrets (must be set via env vars OR .secrets file)
MISSING_SECRETS=0
for var in CONDUCIVE_GIT_PAT DOCKER_USER DOCKER_PASS REMOTEIT_REGISTRATION_CODE; do
    if [[ -z "${!var:-}" ]]; then
        echo "[ERROR] Missing required secret: $var"
        MISSING_SECRETS=1
    fi
done
if [[ $MISSING_SECRETS -eq 1 ]]; then
    echo ""
    echo "Secrets can be provided via:"
    echo "  1. Environment variables (for curl|bash):"
    echo "     CONDUCIVE_GIT_PAT=\"...\" DOCKER_USER=\"...\" DOCKER_PASS=\"...\" REMOTEIT_REGISTRATION_CODE=\"...\" \\"
    echo "       curl -sL https://your-url/jetson_sanity_check.sh | bash"
    echo ""
    echo "  2. A .secrets file in the script directory: $SECRETS_FILE"
    exit 1
fi

# --- Configuration ---
# Minimum acceptable free space on the detected ~1TB drive in Gigabytes (GB)
MIN_SSD_FREE_GB=100 # Default: 100GB

# NX Witness specific version
NX_INSTALLER_DEB="nxwitness-server-5.1.1.37512-linux_arm64.deb"
NX_INSTALLER_URL="https://updates.networkoptix.com/default/5.1.1.37512/arm/${NX_INSTALLER_DEB}"
NX_SERVICE_NAME="networkoptix-mediaserver.service"
NX_PACKAGE_NAME="nxwitness-server"

# Conducive Analytics Git Repo Info
CONDUCIVE_REPO_NAME="ConduciveAnalytics"
CONDUCIVE_REPO_URL="https://${CONDUCIVE_GIT_PAT}@dev.azure.com/CTTier1/ConduciveAnalytics/_git/ConduciveAnalytics"

# Docker Registry Configuration
DOCKER_REGISTRY="ctanalyticstest.azurecr.io"

# Remote.it Configuration
REMOTEIT_DEVICE_NAME=""  # Will prompt user if empty

# JTOP Helper Configuration
# When running via curl|bash, the helper will be downloaded automatically
PYTHON_HELPER_URL="${PYTHON_HELPER_URL:-https://raw.githubusercontent.com/HenryPDT/jetson-scripts/main/jetson/jetson_jtop_helper.py}"
PYTHON_HELPER="${SCRIPT_DIR}/jetson_jtop_helper.py"
JTOP_DATA=""
JTOP_INSTALLED=0
# PENDING_POWER_MODE_ID and NAME are used for interactive changes
PENDING_POWER_MODE_ID="-1"
PENDING_POWER_MODE_NAME=""

# --- Ensure Python Helper is Available ---
# If running via curl|bash, download the helper to a temp file
ensure_python_helper() {
    if [[ -f "$PYTHON_HELPER" ]]; then
        return 0  # Already exists locally
    fi
    
    # Download to temp file
    print_info "Downloading Python helper from GitHub..."
    local temp_helper
    temp_helper=$(mktemp --suffix=.py)
    TEMP_FILES+=("$temp_helper")
    
    if curl -sL "$PYTHON_HELPER_URL" -o "$temp_helper" && [[ -s "$temp_helper" ]]; then
        PYTHON_HELPER="$temp_helper"
        print_success "Python helper downloaded successfully."
        return 0
    else
        print_warning "Failed to download Python helper. Some jtop features will be unavailable."
        return 1
    fi
}

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
    print_info "Ensuring essential tools (nano) are installed..."
    install_required_tools nano

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

check_sdk_libraries() {
  print_info "Checking SDK Libraries..."
  if [ -z "$JTOP_DATA" ]; then
    print_warning "No jtop data available for SDK checks."
    return 1
  fi

  local libs=$(echo "$JTOP_DATA" | jq -r '.libraries')
  if [ "$libs" == "null" ] || [ -z "$libs" ]; then
    print_warning "No library information found in jtop data."
    return 1
  fi

  # Filter and display key libraries
  local keys=("CUDA" "TensorRT" "cuDNN" "OpenCV" "VPI" "Vulkan")
  for key in "${keys[@]}"; do
    local val=$(echo "$libs" | jq -r ".\"$key\" // \"Not Found\"")
    if [ "$val" != "Not Found" ]; then
      print_success "${key} Version: ${val}"
    else
      print_warning "${key}: Not Found"
    fi
  done
  return 0
}


check_jetson_info() {
  print_info "Checking Jetson Device Info..."
  local model="Unknown"
  local l4t_version="Unknown"
  local jetpack_version="Unknown"
  local serial="Unknown"

  if [ -n "$JTOP_DATA" ]; then
    model=$(echo "$JTOP_DATA" | jq -r '.board.model // "Unknown"')
    serial=$(echo "$JTOP_DATA" | jq -r '.board.serial // "Unknown"')
    l4t_version=$(echo "$JTOP_DATA" | jq -r '.board.l4t // "Unknown"')
    jetpack_version=$(echo "$JTOP_DATA" | jq -r '.board.jetpack // "Unknown"')
    
    [ "$model" != "Unknown" ] && print_success "Device Model: ${model}"
    [ "$serial" != "Unknown" ] && print_success "Serial Number: ${serial}"
    [ "$l4t_version" != "Unknown" ] && print_success "L4T Version: ${l4t_version}"
    [ "$jetpack_version" != "Unknown" ] && print_success "JetPack Version: ${jetpack_version}"
    return 0
  fi

  # Fallback to legacy methods
  if [ -f /proc/device-tree/model ]; then
    model=$(tr -d '\0' < /proc/device-tree/model)
    print_success "Device Model: ${model} (Fallback)"
  fi

  if [ -f /proc/device-tree/serial-number ]; then
    serial=$(tr -d '\0' < /proc/device-tree/serial-number)
    print_success "Serial Number: ${serial} (Fallback)"
  fi

  if [ -f /etc/nv_tegra_release ]; then
    l4t_version=$(head -n 1 /etc/nv_tegra_release)
    print_success "L4T Version Info: ${l4t_version} (Fallback)"
  fi

  if jetpack_version=$(dpkg-query -W -f='${Version}' nvidia-jetpack 2>/dev/null) && [ -n "$jetpack_version" ]; then
      print_success "JetPack Version: ${jetpack_version} (Fallback)"
  fi
  
  return 0
}


check_jtop() {
  print_info "Checking JTOP (jetson-stats) and dependencies..."
  
  # 1. Ensure jq is installed
  if ! command -v jq &> /dev/null; then
    print_info "jq not found. Installing..."
    if ! install_required_tools jq; then
      print_error "Failed to install jq. JSON parsing will fail."
      return 1
    fi
  fi

  # 2. Ensure jetson-stats is installed
  if ! command -v jtop &> /dev/null; then
    print_warning "JTOP command not found."
    if ! command -v pip3 &> /dev/null; then
      if ! install_required_tools python3-pip; then
        print_error "Failed to install pip3."
        return 1
      fi
    fi

    print_info "Installing jetson-stats..."
    # Try standard install first, fall back to --break-system-packages for newer Ubuntu
    if sudo pip3 install -U jetson-stats 2>/dev/null || sudo pip3 install -U --break-system-packages jetson-stats; then
      print_success "jetson-stats installed successfully."
      JTOP_INSTALLED=1
      # Ensure user is in the jtop group
      if getent group jtop > /dev/null; then
          sudo usermod -aG jtop "$USER"
      fi
    else
      print_error "Failed to install jetson-stats."
      return 1
    fi
  fi

  # 3. Ensure jtop service is running
  if ! systemctl is-active --quiet jtop.service; then
    print_info "jtop service not running. Attempting to start..."
    sudo systemctl enable jtop.service
    sudo systemctl start jtop.service
    sleep 2
  fi

  if systemctl is-active --quiet jtop.service; then
    print_success "jtop service is running."
  else
    print_error "jtop service failed to start. API calls may fail."
    return 1
  fi

  # 4. Ensure Python helper is available (download if missing)
  ensure_python_helper

  # 5. Fetch data using Python helper
  if [[ -f "$PYTHON_HELPER" ]]; then
    print_info "Fetching system data from jtop API..."
    # Execute with jtop group privileges
    local jtop_result
    jtop_result=$(sg jtop -c "python3 \"$PYTHON_HELPER\"" 2>/dev/null)
    local jtop_exit=$?
    if [[ $jtop_exit -eq 0 ]] && [[ -n "$jtop_result" ]] && ! echo "$jtop_result" | jq -e '.error' &>/dev/null; then
      JTOP_DATA="$jtop_result"
      print_success "Successfully fetched data from jtop API."
      return 0
    else
      local err=$(echo "$jtop_result" | jq -r '.error' 2>/dev/null || echo "Unknown error")
      print_warning "Failed to fetch data from jtop API: $err"
      JTOP_DATA=""
      return 1
    fi
  else
    print_warning "Python helper script not available. Some stats will be missing."
    return 1
  fi
}

check_power_mode() {
  print_info "Checking Jetson Power Mode..."
  
  if [ -z "$JTOP_DATA" ]; then
    print_warning "No jtop data available. Cannot check power mode."
    return 1
  fi

  local current_name=$(echo "$JTOP_DATA" | jq -r '.nvpmodel.name // "Unknown"')
  local current_id=$(echo "$JTOP_DATA" | jq -r '.nvpmodel.id // "-1"')
  local num_models=$(echo "$JTOP_DATA" | jq -r '.nvpmodel.models | length')
  local available_models=$(echo "$JTOP_DATA" | jq -r '.nvpmodel.models | join(", ")')
  local last_index=$((num_models - 1))
  local target_name=$(echo "$JTOP_DATA" | jq -r ".nvpmodel.models[$last_index]")

  print_info "Available Power Modes: ${available_models}"
  print_success "Current Power Mode: ${current_name} (ID: ${current_id})"

  if [ "$current_id" != "$last_index" ]; then
    print_warning "Device is NOT in highest available power mode."
    print_info "Target Mode: ${target_name} (ID: ${last_index})"
    PENDING_POWER_MODE_ID="$last_index"
    PENDING_POWER_MODE_NAME="$target_name"
    return 2 # Warning/Action needed
  else
    print_success "Device is already in highest available power mode: ${current_name} (ID: ${current_id})."
    return 0
  fi
}

check_resource_stats() {
  print_info "Checking Resource & Hardware Stats..."
  if [ -z "$JTOP_DATA" ]; then
    print_warning "No jtop data available for resource stats."
    return 1
  fi

  local gpu_load=$(echo "$JTOP_DATA" | jq -r '.gpu.load // 0')
  local cpu_user=$(echo "$JTOP_DATA" | jq -r '.cpu.total_user // 0')
  local ram_used_kb=$(echo "$JTOP_DATA" | jq -r '.ram.used // 0')
  local ram_total_kb=$(echo "$JTOP_DATA" | jq -r '.ram.total // 0')
  local fan_speed=$(echo "$JTOP_DATA" | jq -r '.fan.speed // 0')
  local fan_profile=$(echo "$JTOP_DATA" | jq -r '.fan.profile // "Unknown"')

  # RAM in GB
  local ram_used_gb=$(awk -v k="$ram_used_kb" 'BEGIN { printf "%.2f", k / (1024*1024) }')
  local ram_total_gb=$(awk -v k="$ram_total_kb" 'BEGIN { printf "%.2f", k / (1024*1024) }')

  print_info "GPU Load: ${gpu_load}%"
  print_info "CPU User: ${cpu_user}%"
  print_info "RAM Usage: ${ram_used_gb}GB / ${ram_total_gb}GB"
  print_info "Fan: ${fan_speed}% (Profile: ${fan_profile})"

  # Temperatures
  echo -ne "${BBlue}[INFO]${Color_Off} Temperatures: "
  echo "$JTOP_DATA" | jq -r '.temperature | to_entries | .[] | "\(.key): \(.value)°C"' | tr '\n' ' ' | sed 's/ $//'
  echo ""

  return 0
}

check_engines() {
  print_info "Checking Hardware Engines (DLA, NVDEC, NVENC)..."
  if [ -z "$JTOP_DATA" ]; then
    print_warning "No jtop data available for engine checks."
    return 1
  fi

  local engines=$(echo "$JTOP_DATA" | jq -r '.engines')
  if [ "$engines" == "null" ] || [ -z "$engines" ]; then
    print_warning "No engine information found."
    return 1
  fi

  # Dynamically iterate over all groups (DLA, NVDEC, NVENC, etc.)
  local groups=$(echo "$engines" | jq -r 'keys | .[]')
  for group in $groups; do
    local group_data=$(echo "$engines" | jq -r ".\"$group\"")
    echo -ne "  ${BPurple}${group}:${Color_Off} "
    
    local keys=($(echo "$group_data" | jq -r 'keys | .[]'))
    if [ "${#keys[@]}" -eq 1 ] && [ "${keys[0]}" == "$group" ]; then
        local status=$(echo "$group_data" | jq -r ".\"$group\".online | if . then \"ON\" else \"OFF\" end")
        echo "$status"
    else
        echo "$group_data" | jq -r 'to_entries | .[] | "\(.key): \(.value.online | if . then "ON" else "OFF" end)"' | tr '\n' ' ' | sed 's/ $//'
        echo ""
    fi
  done
  
  return 0
}

check_gpu_processes() {
  print_info "Checking GPU Processes..."
  if [ -z "$JTOP_DATA" ]; then
    print_warning "No jtop data available for process checks."
    return 1
  fi

  local procs=$(echo "$JTOP_DATA" | jq -c '.processes[]?')
  if [ -z "$procs" ]; then
    print_success "No active GPU processes found."
    return 0
  fi

  printf "  %-8s %-15s %-10s %-20s\n" "PID" "User" "GPU Mem" "Name"
  while read -r p; do
    local pid=$(echo "$p" | jq -r '.pid')
    local user=$(echo "$p" | jq -r '.user')
    local mem_kb=$(echo "$p" | jq -r '.gpu_mem')
    local mem_mb=$(awk -v k="$mem_kb" 'BEGIN { printf "%.0f", k / 1024 }')
    local name=$(echo "$p" | jq -r '.name')
    printf "  %-8s %-15s %-10s %-20s\n" "$pid" "$user" "${mem_mb}MB" "$name"
  done <<< "$procs"

  return 0
}

check_jetson_clocks() {
  print_info "Checking Jetson Clocks Service..."
  if [ -z "$JTOP_DATA" ]; then
    print_warning "No jtop data available for clocks check."
    return 1
  fi

  local active=$(echo "$JTOP_DATA" | jq -r '.jetson_clocks.active')
  local boot=$(echo "$JTOP_DATA" | jq -r '.jetson_clocks.boot')
  local status=$(echo "$JTOP_DATA" | jq -r '.jetson_clocks.status')

  if [ "$active" == "true" ] && [ "$boot" == "true" ]; then
    print_success "Jetson Clocks is running and enabled on boot (Status: $status)."
    return 0
  fi

  print_warning "Jetson Clocks is NOT fully configured (Active: $active, Boot: $boot)."
  print_info "Attempting to enable Jetson Clocks and set to boot..."
  
  # Call helper with --enable-clocks using jtop group
  local action_result
  action_result=$(sg jtop -c "python3 \"$PYTHON_HELPER\" --enable-clocks" 2>/dev/null)
  local clocks_exit=$?
  if [ $clocks_exit -eq 0 ]; then
     local action_msg=$(echo "$action_result" | jq -r '.clocks_action // "Unknown action"')
     local action_err=$(echo "$action_result" | jq -r '.clocks_action_error // "None"')
     
     if [ "$action_err" == "None" ]; then
        print_success "Action: $action_msg"
        # Refresh JTOP_DATA
        JTOP_DATA="$action_result"
        return 0
     else
        print_error "Failed to enable clocks: $action_err"
        return 1
     fi
  else
     print_error "Failed to call Python helper for clocks enablement."
     return 1
  fi
}


# --- NVMe SSD Setup Configuration ---
NVME_MOUNT_POINT="/mnt/1tb"
NVME_MIN_SIZE_GB=800
NVME_MAX_SIZE_GB=1100
NVME_FILESYSTEM="ext4"

setup_nvme_ssd() {
    print_info "Checking NVMe SSD Setup..."
    
    local target_device=""
    local target_partition=""
    local fstab_entry=""
    
    # --- STAGE 1: Check if already configured and working ---
    if mountpoint -q "$NVME_MOUNT_POINT" 2>/dev/null; then
        print_success "$NVME_MOUNT_POINT is already mounted."
        
        # Verify it's writable
        local test_file="${NVME_MOUNT_POINT}/.nvme_setup_test_$(date +%s)"
        if sudo touch "$test_file" 2>/dev/null; then
            sudo rm -f "$test_file"
            print_success "Mount point is healthy and writable."
            
            # Check fstab entry exists
            if grep -q "$NVME_MOUNT_POINT" /etc/fstab; then
                print_success "fstab entry exists for $NVME_MOUNT_POINT."
                return 0
            else
                print_warning "Mount is active but no fstab entry found. Will add one."
                # Find what device is mounted there
                local mounted_dev=$(findmnt -n -o SOURCE "$NVME_MOUNT_POINT")
                if [ -n "$mounted_dev" ]; then
                    fstab_entry="${mounted_dev} ${NVME_MOUNT_POINT} ${NVME_FILESYSTEM} defaults 0 0"
                    echo "$fstab_entry" | sudo tee -a /etc/fstab > /dev/null
                    print_success "Added fstab entry: $fstab_entry"
                    return 0
                fi
            fi
        else
            print_warning "$NVME_MOUNT_POINT is mounted but not writable. May need attention."
        fi
    fi
    
    # Check if fstab entry exists but mount failed
    if grep -q "$NVME_MOUNT_POINT" /etc/fstab; then
        print_info "fstab entry exists. Attempting to mount..."
        if sudo mount -a && mountpoint -q "$NVME_MOUNT_POINT"; then
            print_success "Successfully mounted $NVME_MOUNT_POINT from existing fstab entry."
            return 0
        else
            print_warning "fstab entry exists but mount failed. Device may need setup."
        fi
    fi
    
    # --- STAGE 2: Detect NVMe devices ---
    print_info "Scanning for NVMe devices..."
    
    local nvme_devices=()
    local min_bytes=$((NVME_MIN_SIZE_GB * 1024 * 1024 * 1024))
    local max_bytes=$((NVME_MAX_SIZE_GB * 1024 * 1024 * 1024))
    
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size_bytes=$(echo "$line" | awk '{print $2}')
        local type=$(echo "$line" | awk '{print $3}')
        
        # Only consider disk-type devices (not partitions) that match NVMe pattern
        if [[ "$name" =~ ^nvme[0-9]+n[0-9]+$ ]] && [[ "$type" == "disk" ]]; then
            if [[ "$size_bytes" -ge "$min_bytes" ]] && [[ "$size_bytes" -le "$max_bytes" ]]; then
                nvme_devices+=("$name:$size_bytes")
            fi
        fi
    done < <(lsblk -bndo NAME,SIZE,TYPE 2>/dev/null)
    
    if [ ${#nvme_devices[@]} -eq 0 ]; then
        print_warning "No NVMe devices found in the ${NVME_MIN_SIZE_GB}GB-${NVME_MAX_SIZE_GB}GB range."
        print_info "Available block devices:"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
        print_action "Connect an NVMe SSD and re-run this script."
        return 1
    fi
    
    # --- STAGE 3: Select the target device ---
    if [ ${#nvme_devices[@]} -eq 1 ]; then
        local dev_info="${nvme_devices[0]}"
        target_device=$(echo "$dev_info" | cut -d: -f1)
        local size_bytes=$(echo "$dev_info" | cut -d: -f2)
        local size_gb=$(awk -v s="$size_bytes" 'BEGIN { printf "%.1f", s / (1024*1024*1024) }')
        print_info "Found NVMe device: /dev/${target_device} (${size_gb} GB)"
    else
        print_info "Multiple NVMe devices found:"
        for i in "${!nvme_devices[@]}"; do
            local dev_info="${nvme_devices[$i]}"
            local name=$(echo "$dev_info" | cut -d: -f1)
            local size_bytes=$(echo "$dev_info" | cut -d: -f2)
            local size_gb=$(awk -v s="$size_bytes" 'BEGIN { printf "%.1f", s / (1024*1024*1024) }')
            echo "  [$i] /dev/${name} (${size_gb} GB)"
        done
        echo -ne "${BPurple}[INPUT REQUIRED]${Color_Off} Select device number [0-$((${#nvme_devices[@]}-1))]: "
        read -r selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -lt ${#nvme_devices[@]} ]; then
            target_device=$(echo "${nvme_devices[$selection]}" | cut -d: -f1)
        else
            print_error "Invalid selection."
            return 1
        fi
    fi
    
    target_partition="${target_device}p1"
    
    # --- STAGE 4: Safety checks before destructive operations ---
    print_info "Performing safety checks on /dev/${target_device}..."
    
    # Check if any partition is mounted
    local mounted_parts=$(lsblk -lno NAME,MOUNTPOINT "/dev/${target_device}" 2>/dev/null | awk '$2 != "" {print $1 " -> " $2}')
    if [ -n "$mounted_parts" ]; then
        print_error "Device /dev/${target_device} has mounted partitions:"
        echo "$mounted_parts"
        print_error "Cannot proceed - device is in use. Unmount partitions first."
        return 1
    fi
    print_success "No mounted partitions on /dev/${target_device}."
    
    # Check for existing partitions
    local existing_parts=$(lsblk -lno NAME,SIZE,FSTYPE "/dev/${target_device}" 2>/dev/null | tail -n +2)
    if [ -n "$existing_parts" ]; then
        print_warning "Existing partitions found on /dev/${target_device}:"
        lsblk -o NAME,SIZE,FSTYPE,LABEL "/dev/${target_device}"
        echo ""
    else
        print_info "No existing partitions on /dev/${target_device}."
    fi
    
    # Get device details for confirmation
    local dev_model=$(cat /sys/block/${target_device}/device/model 2>/dev/null | tr -d '[:space:]' || echo "Unknown")
    local dev_serial=$(cat /sys/block/${target_device}/device/serial 2>/dev/null | tr -d '[:space:]' || echo "Unknown")
    local dev_size_bytes=$(cat /sys/block/${target_device}/size 2>/dev/null)
    local dev_size_gb="Unknown"
    if [ -n "$dev_size_bytes" ]; then
        dev_size_gb=$(awk -v s="$dev_size_bytes" 'BEGIN { printf "%.1f", (s * 512) / (1024*1024*1024) }')
    fi
    
    # --- STAGE 5: Final confirmation ---
    echo ""
    echo "========================================"
    echo -e "${BRed}    ⚠️  DESTRUCTIVE OPERATION WARNING ⚠️${Color_Off}"
    echo "========================================"
    echo ""
    echo "You are about to COMPLETELY WIPE the following device:"
    echo ""
    echo "  Device:  /dev/${target_device}"
    echo "  Model:   ${dev_model}"
    echo "  Serial:  ${dev_serial}"
    echo "  Size:    ${dev_size_gb} GB"
    echo ""
    echo "This will:"
    echo "  1. Remove ALL existing data on this device"
    echo "  2. Create a new partition table"
    echo "  3. Format with ${NVME_FILESYSTEM} filesystem"
    echo "  4. Mount at ${NVME_MOUNT_POINT}"
    echo ""
    echo -e "${BRed}ALL DATA ON THIS DEVICE WILL BE PERMANENTLY LOST!${Color_Off}"
    echo ""
    echo -ne "${BPurple}[CONFIRMATION REQUIRED]${Color_Off} Type ${BYellow}YES${Color_Off} (uppercase) to proceed: "
    read -r confirmation
    
    if [ "$confirmation" != "YES" ]; then
        print_info "Operation cancelled by user."
        return 1
    fi
    
    # --- STAGE 6: Perform the setup ---
    print_info "Proceeding with NVMe SSD setup..."
    
    # 6.1: Wipe existing signatures
    print_info "Wiping existing filesystem signatures..."
    if ! sudo wipefs -a "/dev/${target_device}"; then
        print_error "Failed to wipe filesystem signatures."
        return 1
    fi
    print_success "Filesystem signatures wiped."
    
    # 6.2: Create partition using sfdisk (non-interactive alternative to fdisk)
    print_info "Creating new partition..."
    if ! echo "type=83" | sudo sfdisk "/dev/${target_device}" --quiet; then
        print_error "Failed to create partition."
        return 1
    fi
    
    # Wait for partition to appear with polling instead of fixed sleep
    print_info "Waiting for partition to appear..."
    local timeout=10
    while [[ ! -b "/dev/${target_partition}" ]] && [[ $timeout -gt 0 ]]; do
        sleep 1
        sudo partprobe "/dev/${target_device}" 2>/dev/null
        timeout=$((timeout - 1))
    done
    
    if [[ ! -b "/dev/${target_partition}" ]]; then
        print_error "Partition /dev/${target_partition} not found after creation (timeout)."
        return 1
    fi
    print_success "Created partition /dev/${target_partition}."
    
    # 6.3: Format the partition
    print_info "Formatting partition with ${NVME_FILESYSTEM}..."
    if ! sudo mkfs.${NVME_FILESYSTEM} -F "/dev/${target_partition}"; then
        print_error "Failed to format partition."
        return 1
    fi
    print_success "Partition formatted with ${NVME_FILESYSTEM}."
    
    # 6.4: Create mount point
    print_info "Creating mount point ${NVME_MOUNT_POINT}..."
    if ! sudo mkdir -p "$NVME_MOUNT_POINT"; then
        print_error "Failed to create mount point."
        return 1
    fi
    print_success "Mount point created."
    
    # 6.5: Set ownership
    print_info "Setting ownership of mount point..."
    sudo chown -R "$USER:$USER" "$NVME_MOUNT_POINT"
    print_success "Ownership set to $USER."
    
    # 6.6: Add fstab entry (if not already present)
    fstab_entry="/dev/${target_partition} ${NVME_MOUNT_POINT} ${NVME_FILESYSTEM} defaults 0 0"
    if grep -q "${NVME_MOUNT_POINT}" /etc/fstab; then
        print_warning "fstab entry for ${NVME_MOUNT_POINT} already exists. Skipping."
    else
        print_info "Adding fstab entry..."
        echo "$fstab_entry" | sudo tee -a /etc/fstab > /dev/null
        print_success "Added to /etc/fstab: $fstab_entry"
    fi
    
    # 6.7: Mount the partition
    print_info "Mounting partition..."
    if ! sudo mount -a; then
        print_error "Failed to mount partition via 'mount -a'."
        return 1
    fi
    
    if mountpoint -q "$NVME_MOUNT_POINT"; then
        print_success "Successfully mounted /dev/${target_partition} at ${NVME_MOUNT_POINT}!"
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "/dev/${target_device}"
        return 0
    else
        print_error "Mount command succeeded but ${NVME_MOUNT_POINT} is not a mountpoint."
        return 1
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
        if ! sudo rm "$test_file" &> /dev/null; then
            print_warning "Could not remove test file ${test_file}. Manual cleanup needed."
        fi
    else
        local exit_code=$?
        print_error "Basic health check (write permission) failed for ${target_mountpoint}. Exit code: $exit_code"
        print_action "Check permissions ('ls -ld ${target_mountpoint}') and mount status ('mount | grep ${target_mountpoint}')."
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
        df -BG "$target_mountpoint"
        errors=$((errors + 1))
    fi

    return $errors
}


check_nx_witness() {
    print_info "Checking NX Witness Media Server..."

    # First, check if the service unit file exists at all (use sudo to ensure we can check it)
    if sudo systemctl status "$NX_SERVICE_NAME" &> /dev/null; then
        # Service unit file exists. Let's try to start/restart it.
        print_info "NX Witness service unit found. Attempting to start/restart..."

        # Check current status to decide whether to start or restart
        if systemctl is-active --quiet "$NX_SERVICE_NAME"; then
            print_info "Service is already running. Attempting to restart..."
            if sudo systemctl restart "$NX_SERVICE_NAME"; then
                print_success "NX Witness service restart command issued successfully."
            else
                print_error "Failed to issue restart command for NX Witness service (${NX_SERVICE_NAME})."
                print_action "Please check service status manually: ${BYellow}sudo systemctl status ${NX_SERVICE_NAME}${Color_Off}"
                return 1
            fi
        else
            print_info "Service is not running. Attempting to start..."
            if sudo systemctl start "$NX_SERVICE_NAME"; then
                print_success "NX Witness service start command issued successfully."
            else
                print_error "Failed to issue start command for NX Witness service (${NX_SERVICE_NAME})."
                print_action "Please check service status manually: ${BYellow}sudo systemctl status ${NX_SERVICE_NAME}${Color_Off}"
                return 1
            fi
        fi

        print_info "Waiting a few seconds for service to stabilize..."
        sleep 3 # Give the service a moment

        # Now check if it's actually active
        if systemctl is-active --quiet "$NX_SERVICE_NAME"; then
            print_success "NX Witness service (${NX_SERVICE_NAME}) is active and running."
            local status_output=$(sudo systemctl status "$NX_SERVICE_NAME")
            local active_line=$(echo "$status_output" | grep 'Active:')
            if [ -n "$active_line" ]; then
                 active_line=$(echo "$active_line" | sed 's/^[ \t]*//')
                 print_info "${active_line}"
            fi
            return 0 # Service is running
        else
            print_error "NX Witness service (${NX_SERVICE_NAME}) failed to become active."
            print_action "Please check service status manually: ${BYellow}sudo systemctl status ${NX_SERVICE_NAME}${Color_Off}"
            print_action "Also check logs: ${BYellow}sudo journalctl -u ${NX_SERVICE_NAME} -n 50 --no-pager${Color_Off}"
            return 1 # Service not running
        fi
    else
        # Service unit file does not exist - need to install
        print_warning "NX Witness service (${NX_SERVICE_NAME}) unit file not found."

        # Check if dpkg package is installed (maybe service file is just missing/disabled)
        if dpkg-query -W -f='${Status}' "$NX_PACKAGE_NAME" 2>/dev/null | grep -q "ok installed"; then
             print_warning "Package (${NX_PACKAGE_NAME}) is installed, but the service file seems missing or wasn't properly enabled."
             print_action "Try re-installing the .deb package (which should set up the service file), or enabling manually if you know how."
             # Fall through to check for installer, as re-installation might be needed
        fi

        # Proceed to check for installer
        print_info "Checking for NX Witness installer..."
        if [ -f "$NX_INSTALLER_DEB" ]; then
            print_info "Installer found: ${NX_INSTALLER_DEB}"
        else
            print_warning "Installer ${NX_INSTALLER_DEB} not found locally."
            print_action "Attempting to download the installer..."
            if command -v wget &> /dev/null; then
                wget --quiet --show-progress "$NX_INSTALLER_URL"
                if [ $? -eq 0 ]; then
                    print_success "Successfully downloaded ${NX_INSTALLER_DEB}."
                else
                    print_error "Failed to download ${NX_INSTALLER_DEB} from ${NX_INSTALLER_URL}."
                    print_action "Check internet connection or download manually."
                    return 1
                fi
            else
                 print_error "'wget' command not found. Cannot download installer."
                 print_action "Install wget (${BYellow}sudo apt install wget${Color_Off}) or download manually from:"
                 print_action "${NX_INSTALLER_URL}"
                 return 1
            fi
        fi

        if [ -f "$NX_INSTALLER_DEB" ]; then
             # Auto-install the NX Witness package
             print_info "Installing NX Witness package..."
             if sudo apt install -y "./${NX_INSTALLER_DEB}"; then
                 print_success "NX Witness installed successfully."
                 # Try to start the service
                 if sudo systemctl start "$NX_SERVICE_NAME"; then
                     print_success "NX Witness service started."
                     return 0
                 else
                     print_warning "NX Witness installed but failed to start service."
                     print_action "Check service status manually: ${BYellow}sudo systemctl status ${NX_SERVICE_NAME}${Color_Off}"
                     return 1
                 fi
             else
                 print_error "Failed to install NX Witness package."
                 return 1
             fi
        fi
        return 1 # Indicates action needed as service wasn't running and needed install steps
    fi
}


check_conducive_analytics() {
    print_info "Checking for ConduciveAnalytics Git repository..."
    print_info "Searching for '${CONDUCIVE_REPO_NAME}' in home directory..."
    local found_paths=()
    while IFS= read -r line; do
        found_paths+=("$line")
    done < <(find "$HOME" -maxdepth 4 -type d -name "$CONDUCIVE_REPO_NAME" -print 2>/dev/null)

    # If not found in home within reasonable depth, search root (excluding home)
    if [ ${#found_paths[@]} -eq 0 ]; then
        print_info "Not found in $HOME (maxdepth 4). Searching entire filesystem (this may take a moment)..."
        while IFS= read -r line; do
            found_paths+=("$line")
        done < <(find / -path "$HOME" -prune -o -type d -name "$CONDUCIVE_REPO_NAME" -print 2>/dev/null)
    fi

    local num_found=${#found_paths[@]}
    case $num_found in
        0)
            print_warning "ConduciveAnalytics repository directory not found."
            if ! command -v git &> /dev/null; then
                 print_error "'git' command not found."
                 print_action "Installing git..."
                 if ! install_required_tools git; then
                     print_error "Failed to install git."
                     print_action "Install git manually: ${BYellow}sudo apt update && sudo apt install git${Color_Off}"
                     return 1
                 fi
            fi
            
            # Determine clone destination
            local clone_destination=""
            local documents_dir="$HOME/Documents"
            if [ -d "$documents_dir" ]; then
                clone_destination="$documents_dir"
                print_info "Documents folder found. Cloning to: ${clone_destination}"
            else
                clone_destination="$HOME"
                print_info "Documents folder not found. Cloning to home directory: ${clone_destination}"
            fi
            
            # Clone the repository
            print_info "Cloning repository to ${clone_destination}/${CONDUCIVE_REPO_NAME}..."
            if git clone "$CONDUCIVE_REPO_URL" "${clone_destination}/${CONDUCIVE_REPO_NAME}"; then
                print_success "Successfully cloned ConduciveAnalytics repository to ${clone_destination}/${CONDUCIVE_REPO_NAME}"
                return 0
            else
                print_error "Failed to clone repository."
                print_action "Please clone manually: ${BYellow}git clone ${CONDUCIVE_REPO_URL}${Color_Off}"
                print_info "(Update placeholder URL in script if needed)"
                return 1
            fi
            ;;
        1)
            print_success "Found ConduciveAnalytics repository at: ${found_paths[0]}"
            return 0
            ;;
        *)
            print_warning "Found multiple directories named '${CONDUCIVE_REPO_NAME}':"
            for path in "${found_paths[@]}"; do echo -e "  - ${path}"; done
            print_action "Verify correct repository and clean up duplicates."
            return 1
            ;;
    esac
}


check_docker_login() {
    print_info "Checking Docker Registry Authentication: ${DOCKER_REGISTRY}..."
    
    # Check if docker is installed first
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Cannot login."
        return 1
    fi

    # Optimization: Check if already logged in by inspecting Docker's config
    # We check both the user's and root's config since the script uses 'sudo docker'
    local auth_found=1
    for config in "$HOME/.docker/config.json" "/root/.docker/config.json"; do
        if [ -f "$config" ] || sudo [ -f "$config" ] 2>/dev/null; then
            if sudo jq -e ".auths | has(\"${DOCKER_REGISTRY}\")" "$config" &> /dev/null; then
                auth_found=0
                break
            fi
        fi
    done

    if [ "$auth_found" -eq 0 ]; then
        print_success "Already authenticated with ${DOCKER_REGISTRY}. Skipping login."
        return 0
    fi

    print_info "Not authenticated. Attempting login..."
    if echo "${DOCKER_PASS}" | sudo docker login "${DOCKER_REGISTRY}" --username "${DOCKER_USER}" --password-stdin &> /dev/null; then
        print_success "Successfully logged into Docker Registry."
        return 0
    else
        print_error "Failed to login to Docker Registry."
        return 1
    fi
}


check_docker_compose() {
    print_info "Checking Docker Compose..."
    
    # 1. Check if 'docker compose' (modern plugin) or 'docker-compose' (standalone) works
    # Use sudo to ensure we check the same environment used for docker operations
    local compose_cmd=""
    if sudo docker compose version &> /dev/null 2>&1; then
        compose_cmd="sudo docker compose"
    elif sudo docker-compose version &> /dev/null 2>&1; then
        compose_cmd="sudo docker-compose"
    elif docker compose version &> /dev/null 2>&1; then
        compose_cmd="docker compose"
    elif docker-compose version &> /dev/null 2>&1; then
        compose_cmd="docker-compose"
    fi

    if [ -n "$compose_cmd" ]; then
        local version=$($compose_cmd version --short 2>/dev/null || $compose_cmd version)
        print_success "Docker Compose is installed: $version"
        return 0
    fi

    print_warning "Docker Compose not found."
    print_info "Attempting manual installation of Docker Compose v5.0.1 (aarch64)..."
    
    # 1. Ensure curl is installed
    if ! install_required_tools curl; then
        print_error "Failed to ensure curl is installed. Cannot proceed with manual download."
        return 1
    fi

    # 2. Setup the local config directory
    DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
    mkdir -p "$DOCKER_CONFIG/cli-plugins"

    # 3. Download the v5.0.1 binary for Jetson (ARM 64-bit)
    print_info "Downloading Docker Compose v5.0.1 for linux-aarch64..."
    if curl -SL https://github.com/docker/compose/releases/download/v5.0.1/docker-compose-linux-aarch64 -o "$DOCKER_CONFIG/cli-plugins/docker-compose"; then
        # 4. Apply executable permissions
        chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"

        # 5. Install system-wide (allows all users and 'sudo' to use it)
        print_info "Installing system-wide to /usr/local/lib/docker/cli-plugins..."
        sudo mkdir -p /usr/local/lib/docker/cli-plugins
        sudo cp "$DOCKER_CONFIG/cli-plugins/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
        sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

        # 6. Verify the version
        if docker compose version &> /dev/null; then
            local version=$(docker compose version --short 2>/dev/null || docker compose version)
            print_success "Successfully installed Docker Compose: $version"
            return 0
        else
            print_error "Docker Compose installed but 'docker compose' command not working."
            return 1
        fi
    else
        print_error "Failed to download Docker Compose binary from GitHub."
        return 1
    fi
}


check_nvidia_runtime() {
    print_info "Checking NVIDIA Container Runtime..."
    
    # Check if 'nvidia' is a registered runtime
    if sudo docker info 2>/dev/null | grep -i "Runtimes:" | grep -q "nvidia"; then
        print_success "NVIDIA Container Runtime is correctly configured."
        return 0
    fi

    print_warning "NVIDIA Container Runtime is NOT configured for Docker."
    print_info "Attempting to configure NVIDIA runtime..."

    # 1. Ensure toolkit is installed
    if ! dpkg -l | grep -q "nvidia-container-toolkit"; then
        print_info "Installing nvidia-container-toolkit..."
        if ! sudo apt-get update || ! sudo apt-get install -y nvidia-container-toolkit; then
            print_error "Failed to install nvidia-container-toolkit."
            return 1
        fi
    fi

    # 2. Configure the runtime
    print_info "Configuring Docker to use NVIDIA runtime..."
    if sudo nvidia-ctk runtime configure --runtime=docker; then
        print_info "Restarting Docker service..."
        if sudo systemctl restart docker; then
            # Verify update
            sleep 2
            if sudo docker info 2>/dev/null | grep -i "Runtimes:" | grep -q "nvidia"; then
                print_success "NVIDIA Container Runtime successfully configured and verified."
                return 0
            else
                print_error "NVIDIA runtime configured but not appearing in 'docker info'."
                return 1
            fi
        else
            print_error "Failed to restart Docker service."
            return 1
        fi
    else
        print_error "Failed to configure NVIDIA runtime using 'nvidia-ctk'."
        return 1
    fi
}


check_docker_group() {
    print_info "Checking Docker group membership..."
    
    # Check if docker group exists
    if ! getent group docker > /dev/null 2>&1; then
        print_warning "Docker group does not exist. Docker may not be installed."
        print_info "Skipping docker group configuration."
        return 0
    fi
    
    # Check if current user is already in the docker group
    if groups | grep -q "\bdocker\b"; then
        print_success "User ${USER} is already in the docker group."
        
        # Verify docker command works without sudo (if docker is installed)
        if command -v docker &> /dev/null; then
            if docker ps &> /dev/null; then
                print_success "Docker commands work without sudo."
                return 0
            else
                print_warning "Docker group membership detected, but docker commands still require sudo."
                print_info "You may need to log out and back in for changes to take full effect."
                return 1
            fi
        fi
        return 0
    else
        print_warning "User ${USER} is not in the docker group."
        print_info "Adding user to docker group..."
        
        if sudo usermod -aG docker "$USER"; then
            print_success "Successfully added ${USER} to the docker group."
            print_warning "Group membership changes require you to log out and back in, or restart your terminal."
            print_action "To apply changes immediately in this session, run: ${BYellow}newgrp docker${Color_Off}"
            print_info "(Note: This command will start a new shell session with docker group privileges)"
            return 0
        else
            print_error "Failed to add user to docker group."
            print_action "Try manually: ${BYellow}sudo usermod -aG docker $USER${Color_Off}"
            return 1
        fi
    fi
}


# --- New Function: Register with Remote.it ---
register_with_remoteit() {
    print_info "Checking Remote.it integration..."
    
    # Configuration
    local registration_code="${REMOTEIT_REGISTRATION_CODE}"
    local remoteit_config="/etc/remoteit/config.json"
    
    # Check if registration code is configured
    if [ -z "$registration_code" ]; then
        print_warning "Remote.it registration code not configured."
        print_action "Set REMOTEIT_REGISTRATION_CODE to enable Remote.it integration."
        return 1
    fi
    
    # NEW: First, check for the existence of the final config file.
    # This is the fastest and most reliable sign of a completed registration.
    if [ -f "$remoteit_config" ]; then
        print_success "Remote.it is already configured ($remoteit_config exists)."
        local existing_device_name=$(sudo grep '"devicename"' "$remoteit_config" | cut -d'"' -f4)
        if [ -n "$existing_device_name" ]; then
            print_info "Device is registered as: ${existing_device_name}"
        fi
        return 0
    fi

    # Second, check if the service is somehow running without a config file.
    if sudo systemctl --quiet is-active 'remoteit@*.service'; then
        print_success "Remote.it service is already running."
        return 0
    fi
    
    # If neither is true, proceed with installation.
    print_info "Remote.it is not configured. Proceeding with registration."
    
    # Get device name from user if not set
    local device_name="${REMOTEIT_DEVICE_NAME}"
    if [ -z "$device_name" ]; then
        # Get device model and serial ID for default name
        local model_full="Unknown"
        local serial_full="Unknown"
        
        if [ -f /proc/device-tree/model ]; then
            model_full=$(tr -d '\0' < /proc/device-tree/model | tr -d '\n')
        elif [ -f /sys/firmware/devicetree/base/model ]; then
            model_full=$(tr -d '\0' < /sys/firmware/devicetree/base/model | tr -d '\n')
        fi
        
        if [ -f /proc/device-tree/serial-number ]; then
            serial_full=$(tr -d '\0' < /proc/device-tree/serial-number | tr -d '\n')
        elif [ -f /sys/firmware/devicetree/base/serial-number ]; then
            serial_full=$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number | tr -d '\n')
        fi
        
        # Extract a shorter model identifier (e.g., "Orin_Nano" or "Orin_NX")
        local model_short="Jetson"
        if echo "$model_full" | grep -qi "orin"; then
            if echo "$model_full" | grep -qi "nano"; then
                model_short="Orin_Nano"
            elif echo "$model_full" | grep -qi "nx"; then
                model_short="Orin_NX"
            elif echo "$model_full" | grep -qi "agx"; then
                model_short="Orin_AGX"
            else
                model_short="Orin"
            fi
        elif echo "$model_full" | grep -qi "xavier"; then
            if echo "$model_full" | grep -qi "nx"; then
                model_short="Xavier_NX"
            elif echo "$model_full" | grep -qi "agx"; then
                model_short="Xavier_AGX"
            else
                model_short="Xavier"
            fi
        fi
        
        # Use full serial number
        local serial="${serial_full}"
        if [ "$serial" = "Unknown" ] || [ -z "$serial" ]; then
            serial="00000000"
        fi
        
        # Create default device name: short_model-full_serial
        local default_device_name="${model_short}-${serial}"
        
        echo -ne "${BPurple}[INPUT REQUIRED]${Color_Off} Enter a name for this device in Remote.it (or press Enter for default: ${default_device_name}): "
        read -r device_name
        if [ -z "$device_name" ]; then
            device_name="${default_device_name}"
        fi
    fi
    
    # Ensure curl is installed
    if ! install_required_tools curl; then
        print_error "Failed to install required tools for Remote.it registration."
        return 1
    fi
    
    # Download and run the Remote.it installer using temp file
    print_info "Downloading Remote.it installer..."
    local installer_file
    installer_file=$(mktemp)
    TEMP_FILES+=("$installer_file")  # Add to cleanup list
    
    if curl -L -o "$installer_file" https://downloads.remote.it/remoteit/install_agent.sh; then
        chmod +x "$installer_file"
    else
        print_error "Failed to download Remote.it installer."
        return 1
    fi
    
    # Run the installer
    print_info "Running Remote.it installer..."
    if sudo R3_REGISTRATION_CODE="$registration_code" R3_DEVICE_NAME="$device_name" "$installer_file"; then
        print_success "Successfully ran Remote.it installer!"
        
        sleep 5 # Give service time to start
        if sudo systemctl --quiet is-active 'remoteit@*.service'; then
            print_success "Remote.it service is active and operational."
        else
            print_error "Installation ran, but service failed to start. Check logs."
            print_action "View logs: ${BYellow}sudo journalctl -u 'remoteit@*.service' -n 50 --no-pager${Color_Off}"
            return 1
        fi
        return 0
    else
        local exit_code=$?
        print_error "Failed to install/register device with Remote.it (exit code: $exit_code)."
        
        print_action "Troubleshooting steps:"
        print_action "- Verify your registration code is correct and has not expired"
        print_action "- Check network connectivity"
        print_action "- View logs: ${BYellow}sudo journalctl -u 'remoteit@*.service' -n 50 --no-pager${Color_Off}"
        return 1
    fi
}


# --- Main Script Execution ---
print_info "Starting Jetson Sanity Check Script..."
preflight_checks
echo "----------------------------------------"
check_jtop
record_result "JTOP (jetson-stats)" $?
echo "----------------------------------------"
check_jetson_info
record_result "Jetson Device Info" $?
echo "----------------------------------------"
check_jetson_clocks
record_result "Jetson Clocks" $?
echo "----------------------------------------"
check_power_mode
record_result "Power Mode" $?
echo "----------------------------------------"
check_sdk_libraries
record_result "SDK Libraries" $?
echo "----------------------------------------"
check_engines
record_result "Hardware Engines" $?
echo "----------------------------------------"
check_resource_stats
record_result "Hardware Stats" $?
echo "----------------------------------------"
check_gpu_processes
record_result "GPU Processes" $?
echo "----------------------------------------"
setup_nvme_ssd
record_result "NVMe SSD Setup" $?
echo "----------------------------------------"
check_ssd
record_result "SSD Storage Check" $?
echo "----------------------------------------"
check_system_time
record_result "System Date & Time" $?
echo "----------------------------------------"
check_nx_witness
record_result "NX Witness Service" $?
echo "----------------------------------------"
check_conducive_analytics
record_result "Conducive Analytics Repo" $?
echo "----------------------------------------"
check_docker_group
record_result "Docker Group Permissions" $?
echo "----------------------------------------"
check_docker_login
record_result "Docker Registry Login" $?
echo "----------------------------------------"
check_docker_compose
record_result "Docker Compose" $?
echo "----------------------------------------"
check_nvidia_runtime
record_result "NVIDIA Container Runtime" $?
echo "----------------------------------------"
register_with_remoteit
record_result "Remote.it Registration" $?
echo "----------------------------------------"
print_summary

# Post-Check Actions (Interactive)

# 1. Power Mode Change
if [ "$PENDING_POWER_MODE_ID" != "-1" ]; then
    echo ""
    print_action "POWER MODE CHANGE PENDING"
    print_info "Target Mode: ${PENDING_POWER_MODE_NAME} (ID: ${PENDING_POWER_MODE_ID})"
    print_warning "Applying this change now. If a reboot is required, you will be prompted by nvpmodel."
    
    # Invoke nvpmodel directly. It will handle the interactive reboot prompt if needed.
    sudo nvpmodel -m "$PENDING_POWER_MODE_ID"
fi

# 2. General Restart Notification (Fallback)
# We only show this if jtop was installed separately.
if [ "$JTOP_INSTALLED" -eq 1 ]; then
    echo ""
    print_action "RESTART RECOMMENDED: Actions were performed that require a system reboot."
    echo "  - jetson-stats (jtop) was installed/updated."
    print_action "Please run: ${BYellow}sudo reboot${Color_Off}"
fi

# Exit with 0 if all checks passed, 1 otherwise
if [ $FAILURE_COUNT -eq 0 ]; then
    exit 0
else
    exit 1
fi
