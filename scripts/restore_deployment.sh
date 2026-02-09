#!/bin/bash
set -e

# Configuration
BACKUP_DIR="backups"
PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project)}"
ZONE="${GCP_ZONE:-us-central1-a}"

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Error: No GCP Project ID found. Please set GCP_PROJECT_ID or configure gcloud."
    exit 1
fi

VM_NAME=""
BACKUP_FILE=""
CLI_ZONE=""

usage() {
    echo "Usage: $0 [OPTIONS] <vm_name> <backup_file_path>"
    echo ""
    echo "Restores a deployment from a backup archive."
    echo ""
    echo "Options:"
    echo "  --zone ZONE         GCP zone (default: $ZONE)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 my-bot backups/my-bot/backup_my-bot_20260130.tar.gz"
    echo "  $0 --zone us-east5-a my-bot backups/my-bot/backup_my-bot_20260130.tar.gz.gpg"
    echo ""
    echo "For encrypted backups (.gpg), you'll be prompted for the passphrase."
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --zone)
            CLI_ZONE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "❌ Error: Unknown option $1"
            usage
            ;;
        *)
            # Positional arguments: VM_NAME then BACKUP_FILE
            if [ -z "$VM_NAME" ]; then
                VM_NAME="$1"
            elif [ -z "$BACKUP_FILE" ]; then
                BACKUP_FILE="$1"
            else
                echo "❌ Error: Too many arguments"
                usage
            fi
            shift
            ;;
    esac
done

# Apply CLI overrides
[ -n "$CLI_ZONE" ] && ZONE="$CLI_ZONE"

if [ -z "$VM_NAME" ] || [ -z "$BACKUP_FILE" ]; then
    usage
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "❌ Error: Backup file not found: $BACKUP_FILE"
    echo ""
    echo "Available backups for $VM_NAME:"
    ls -1 "$BACKUP_DIR/$VM_NAME/" 2>/dev/null || echo "  (none found)"
    exit 1
fi

# Check if encrypted and decrypt if needed
ACTUAL_BACKUP="$BACKUP_FILE"
TEMP_DECRYPTED=""

if [[ "$BACKUP_FILE" == *.gpg ]]; then
    echo "🔐 Encrypted backup detected. Decrypting..."
    TEMP_DECRYPTED="/tmp/restore_decrypted_$(date +%s).tar.gz"
    gpg -d "$BACKUP_FILE" > "$TEMP_DECRYPTED"
    ACTUAL_BACKUP="$TEMP_DECRYPTED"
    echo "✅ Decryption successful."
fi

echo "🚀 Restoring VM '$VM_NAME' from '$BACKUP_FILE'..."
echo "Project: $PROJECT_ID | Zone: $ZONE"

RESTORE_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REMOTE_BACKUP_PATH="/tmp/restore_archive_${RESTORE_TIMESTAMP}.tar.gz"
LOCAL_RESTORE_SCRIPT="restore_script_temp_${RESTORE_TIMESTAMP}.sh"

# 1. Generate Remote Restore Script
cat << "EOF" > "$LOCAL_RESTORE_SCRIPT"
#!/bin/bash
set -e

ARCHIVE_PATH=$1
STAGING_DIR="/tmp/restore_staging_$(date +%s)"

echo "📦 Extracting archive..."
mkdir -p "$STAGING_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$STAGING_DIR"

# 1. Restore User Home Directories
# We infer users from the directories present in files/home/
if [ -d "$STAGING_DIR/files/home" ]; then
    echo "👥 Restoring user data..."
    for user_dir in "$STAGING_DIR/files/home"/*; do
        username=$(basename "$user_dir")

        # Skip if not a directory
        [ -d "$user_dir" ] || continue

        echo "   Processing user: $username"

        # Check if user exists, create if missing
        if ! id "$username" &>/dev/null; then
            echo "   ⚠️  User '$username' not found. Creating..."
            sudo useradd -m -s /bin/bash "$username"
        fi

        # Restore files
        # We use rsync to merge, preserving permissions and ownership
        # We map ownership to the user on the current system (in case UIDs differ)
        echo "   Restoring files to /home/$username..."
        sudo rsync -a --chown="$username:$username" "$user_dir/" "/home/$username/"
    done
fi

# 2. Restore System Files (Systemd Services)
if [ -d "$STAGING_DIR/system_files" ]; then
    echo "⚙️  Restoring system service files..."
    for service_file in "$STAGING_DIR/system_files"/*; do
        [ -f "$service_file" ] || continue
        filename=$(basename "$service_file")

        echo "   Restoring /etc/systemd/system/$filename"
        sudo cp "$service_file" "/etc/systemd/system/$filename"
        sudo chown root:root "/etc/systemd/system/$filename"
        sudo chmod 644 "/etc/systemd/system/$filename"
    done

    echo "   Reloading systemd daemon..."
    sudo systemctl daemon-reload
fi

# 3. Attempt to restore installed global npm packages (Best Effort)
if [ -f "$STAGING_DIR/installed_npm_global.txt" ]; then
    echo "📦 Attempting to restore global npm packages..."
    # Parse the output of npm list -g --depth=0
    # This is a bit rough, but tries to install packages found in the list
    # Format usually: package@version
    # We grep for lines that look like packages and install latest (safest) or specific if parsed
    # For now, we'll log them for manual review as automated reinstall can be risky
    echo "   ℹ️  Global npm packages found in backup. See installed_npm_global.txt."
    cat "$STAGING_DIR/installed_npm_global.txt"
fi

# Cleanup
echo "🧹 Cleaning up staging..."
rm -rf "$STAGING_DIR"
echo "✅ Restore operations complete."
EOF

# 2. Upload Backup and Script
echo "📤 Uploading backup archive (this may take time)..."
gcloud compute scp "$ACTUAL_BACKUP" "${VM_NAME}:${REMOTE_BACKUP_PATH}" --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap

echo "📤 Uploading restore script..."
gcloud compute scp "$LOCAL_RESTORE_SCRIPT" "${VM_NAME}:/tmp/restore_script.sh" --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap

# 3. Execute Restore
echo "▶️  Running restore on remote VM..."
gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap --command="bash /tmp/restore_script.sh ${REMOTE_BACKUP_PATH}"

# 4. Cleanup Remote
echo "🧹 Cleaning up remote artifacts..."
gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap --command="rm /tmp/restore_script.sh ${REMOTE_BACKUP_PATH}"

# 5. Cleanup Local
rm "$LOCAL_RESTORE_SCRIPT"
[ -n "$TEMP_DECRYPTED" ] && rm -f "$TEMP_DECRYPTED"

echo "✅ Restore process finished."
echo "⚠️  Recommendation: Run './scripts/manage_deployment.sh update $VM_NAME' next to enforce security hardening and base configuration."
