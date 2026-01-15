#!/bin/bash

# Define the target installation path
INSTALL_PATH="/usr/local/bin/up"
TEMP_FILE="/tmp/up_script_source"

echo "Starting installation of 'up' utility..."

# Create the content of the up script
cat << 'EOF' > "$TEMP_FILE"
#!/bin/bash
HIST_FILE="$HOME/.up_last"

execute_rsync() {
    rsync -avzP $4 -e "ssh -p $1" "$2" "$3"
}

if [ "$#" -eq 3 ]; then
    echo "$1 $3" > "$HIST_FILE"
    execute_rsync "$1" "$2" "$3"
    exit $?
fi

if [ -f "$HIST_FILE" ]; then read -r L_PORT L_DEST < "$HIST_FILE"; fi

echo "--- File Transfer Utility (up) ---"
read -p "Port [${L_PORT:-22}]: " PORT
PORT=${PORT:-${L_PORT:-22}}

read -e -p "Source: " SRC
[ -z "$SRC" ] && { echo "Error: Source required."; exit 1; }

read -e -p "Destination [${L_DEST}]: " DEST
DEST=${DEST:-$L_DEST}

echo "$PORT $DEST" > "$HIST_FILE"

read -p "Dry run? (y/n): " DO_DRY
if [[ "$DO_DRY" =~ ^[Yy]$ ]]; then
    execute_rsync "$PORT" "$SRC" "$DEST" "--dry-run"
    read -p "Proceed? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
fi

execute_rsync "$PORT" "$SRC" "$DEST"
EOF

# Set permissions and move to bin
chmod +x "$TEMP_FILE"
sudo mv "$TEMP_FILE" "$INSTALL_PATH"

if [ $? -eq 0 ]; then
    echo "Installation successful. You can now use the command 'up'."
else
    echo "Installation failed. Please check your sudo permissions."
    exit 1
fi