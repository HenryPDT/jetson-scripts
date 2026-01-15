#!/bin/bash

# Jetson EEPROM Checksum Tool
I2C_BUS=0
I2C_ADDR=0x50

# Handle auto-fix flag
AUTO_FIX=false
[[ "$1" == "-f" ]] && AUTO_FIX=true

# 1. Capture EEPROM Data
HEX_DATA=$(sudo i2cdump -y -f $I2C_BUS $I2C_ADDR b 2>/dev/null | \
           grep -E '^[0-9a-f]0:' | \
           cut -d' ' -f2-17 | \
           tr -d ' \n')

if [ -z "$HEX_DATA" ] || [ ${#HEX_DATA} -lt 512 ]; then
    echo "[-] Error: Could not communicate with I2C bus $I2C_BUS at $I2C_ADDR."
    exit 1
fi

# 2. Extract Values
DATA_PART=${HEX_DATA:0:510}
STORED_CRC="0x${HEX_DATA:510:2}"

# 3. Calculate CRC8 (Python logic unchanged)
CALCULATED_CRC=$(python3 -c "
data = bytes.fromhex('$DATA_PART')
crc = 0
for byte in data:
    crc ^= byte
    for _ in range(8):
        if crc & 0x01:
            crc = (crc >> 1) ^ 0x8C
        else:
            crc >>= 1
    crc &= 0xFF
print(f'0x{crc:02x}')
")

echo "[+] Stored:     $STORED_CRC"
echo "[+] Calculated: $CALCULATED_CRC"

# 4. Verification and Fix
if [ "$STORED_CRC" == "$CALCULATED_CRC" ]; then
    echo "[✓] Checksum is correct."
else
    echo "[!] MISMATCH DETECTED!"
    
    if [ "$AUTO_FIX" = false ]; then
        read -p "[?] Apply fix (write $CALCULATED_CRC to 0xFF)? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && AUTO_FIX=true
    fi

    if [ "$AUTO_FIX" = true ]; then
        echo "[*] Writing $CALCULATED_CRC to EEPROM..."
        sudo i2cset -y -f $I2C_BUS $I2C_ADDR 0xff $CALCULATED_CRC
        echo "[✓] Fix applied. Run again to verify."
    else
        echo "[!] No changes made."
    fi
fi
