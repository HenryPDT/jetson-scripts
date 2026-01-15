#!/bin/bash

# Configuration
VERSION="5.1.5"
TARGET="JETSON_ORIN_NX"

echo "------------------------------------------"
echo " Jetson SDK Manager Automation (Combined)"
echo "------------------------------------------"

# Use -r to ensure the password is taken literally as a string
# Use -s to hide the input for security
read -rs -p "Enter Host Sudo Password: " SUDO_PASS
echo ""  # New line after hidden input

echo "Select Use Case:"
echo "1) Download Only (All Components)"
echo "2) Flash Linux OS Only"
echo "3) Install SDK Components Only"
read -p "Selection [1-3]: " CHOICE

# Create a temporary file for the .ini response
TEMP_INI=$(mktemp /tmp/jetson_XXXXXX.ini)

case $CHOICE in
    1)
        cat <<EOF > "$TEMP_INI"
[client_arguments]
sudo-password = "$SUDO_PASS"
action = downloadonly
login-type = devzone
product = Jetson
version = $VERSION
target-os = Linux
host = false
target = JETSON_ORIN_NX_TARGETS
flash = true
license = accept
;; Components: Everything selected for download
select[] = Jetson Linux
select[] = Jetson Runtime Components
select[] = Jetson SDK Components
EOF
        ;;
    2)
        cat <<EOF > "$TEMP_INI"
[client_arguments]
sudo-password = "$SUDO_PASS"
action = install
login-type = devzone
product = Jetson
version = $VERSION
target-os = Linux
host = false
target = JETSON_ORIN_NX_TARGETS
flash = true
license = accept
;; Components: OS Only
select[] = Jetson Linux
deselect[] = Jetson Runtime Components
deselect[] = Jetson SDK Components

[pre-flash-settings]
recovery = manual
oem-configuration = Pre-Config
oem-username = "conducive"
oem-password = "Conducive231@#!x"

[post-flash-settings]
post-flash = skip
EOF
        ;;
    3)
        cat <<EOF > "$TEMP_INI"
[client_arguments]
sudo-password = "$SUDO_PASS"
action = install
login-type = devzone
product = Jetson
version = $VERSION
target-os = Linux
host = false
target = JETSON_ORIN_NX_TARGETS
flash = false
license = accept
;; Components: SDKs Only
deselect[] = Jetson Linux
select[] = Jetson Runtime Components
select[] = Jetson SDK Components

[post-flash-settings]
post-flash = install
ip-type = ipv4
ip = 192.168.55.1
user = "conducive"
password = "Conducive231@#!x"
retries = 2
EOF
        ;;
    *)
        echo "Invalid selection"
        rm -f "$TEMP_INI"
        exit 1
        ;;
esac

# Optional: Prompt to verify/update IP if doing SDK install (Choice 3 only now)
if [[ "$CHOICE" == "3" ]]; then
    CURRENT_IP=$(grep '^ip =' "$TEMP_INI" | awk '{print $3}' | tr -d '"')
    echo "Current IP is: $CURRENT_IP"
    read -p "Enter new Jetson IP (or press Enter to keep $CURRENT_IP): " NEW_IP
    if [[ -n "$NEW_IP" ]]; then
        sed -i "s/^ip = .*/ip = \"$NEW_IP\"/" "$TEMP_INI"
    fi
fi

echo "Starting SDK Manager with temporary config..."
sdkmanager --cli --action install --response-file "$TEMP_INI"

# Clean up
rm -f "$TEMP_INI"
