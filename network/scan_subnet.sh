#!/bin/bash
# find_jetson.sh

# Check integrity
if ! command -v nmap &> /dev/null; then
    echo "nmap not found. Installing..."
    sudo apt update && sudo apt install -y nmap
    
    # Verify installation
    if ! command -v nmap &> /dev/null; then
        echo "Error: Failed to install nmap automatically. Please install it manually."
        exit 1
    fi
fi

# Get local subnet
SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1)

if [ -z "$SUBNET" ]; then
    echo "Could not determine local subnet."
    exit 1
fi

echo "--- Configuration ---"
echo "Enter SSH credentials to verify devices:"
read -p "Username: " SSH_USER
read -s -p "Password: " SSH_PASS
echo -e "\n"

echo "Select Scan Mode:"
echo "1) Identify New Device (Baseline -> Plug in -> Discover)"
echo "2) Scan Existing Devices (Verify everything currently on network)"
read -p "Choice [1/2]: " SCAN_MODE

# Function to verify SSH access
verify_ssh() {
    local ip=$1
    echo -n " >> $ip (SSH active) - Verifying credentials... "
    if sshpass -p "$SSH_PASS" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER@$ip" "exit 0" 2>/dev/null; then
        echo "SUCCESS: Logged in!"
        return 0
    else
        echo "FAILED: Could not login."
        return 1
    fi
}

echo -e "\n--- Jetson Discovery: SSH Port 22 Scan ---"
echo "This will only detect devices with SSH enabled."

if [ "$SCAN_MODE" == "2" ]; then
    echo "Scanning $SUBNET for all SSH-enabled devices..."
    FOUND_IPS=$(nmap -p 22 --open "$SUBNET" | awk '/Nmap scan report for/ { ip=$NF; gsub(/[()]/,"",ip); print " >> Found: " ip > "/dev/stderr"; print ip }')
    
    if [ -n "$FOUND_IPS" ]; then
        echo -e "\nVerifying all found devices..."
        for ip in $FOUND_IPS; do
            verify_ssh "$ip"
        done
    else
        echo "No SSH-enabled devices found on the network."
    fi
    exit 0
fi

# Mode 1: Identify New Device
echo "Ensure the Jetson is UNPLUGGED from the network."
read -p "Press Enter to start the baseline scan..."

echo "Scanning $SUBNET for baseline (existing SSH devices)..."
BASELINE_IPS=$(nmap -p 22 --open "$SUBNET" | awk '/Nmap scan report for/ { ip=$NF; gsub(/[()]/,"",ip); print " >> Found: " ip > "/dev/stderr"; print ip }')

echo -e "\nBaseline captured. Now, PLUG IN the Jetson."
read -p "Wait a few seconds for it to boot/connect, then press Enter to rescan..."

echo "Scanning $SUBNET again for new SSH-enabled devices..."
CURRENT_IPS=$(nmap -p 22 --open "$SUBNET" | awk '/Nmap scan report for/ { ip=$NF; gsub(/[()]/,"",ip); print " >> Found: " ip > "/dev/stderr"; print ip }')

echo "------------------------------------------------------------"
echo "Comparing scans..."

# Find IPs in CURRENT_IPS that are NOT in BASELINE_IPS
NEW_IP=""
for ip in $CURRENT_IPS; do
    if ! echo "$BASELINE_IPS" | grep -q "$ip"; then
        NEW_IP="$NEW_IP $ip"
    fi
done

if [ -n "$NEW_IP" ]; then
    echo "Success! New device(s) found:"
    for ip in $NEW_IP; do
        verify_ssh "$ip"
    done
else
    echo "No new devices detected. Possible reasons:"
    echo "1. Jetson didn't get an IP yet (wait longer)."
    echo "2. Jetson's SSH service is not running or port 22 is blocked."
    echo "3. Jetson's IP was already active in the baseline."
    echo "4. Network connectivity issues."
fi