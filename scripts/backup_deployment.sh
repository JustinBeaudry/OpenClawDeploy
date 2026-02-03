#!/bin/bash
set -e

# Configuration
DEPLOYMENTS_DIR="deployments"
PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project)}"
ZONE="${GCP_ZONE:-us-east5-a}"

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Error: No GCP Project ID found. Please set GCP_PROJECT_ID or configure gcloud."
    exit 1
fi

VM_NAME=$1

usage() {
    echo "Usage: $0 <vm_name>"
    echo "Backs up .clawdbot, clawd, .openclaw, and other legacy configurations, plus installed software lists."
    exit 1
}

if [ -z "$VM_NAME" ]; then
    usage
fi

VM_DIR="$DEPLOYMENTS_DIR/$VM_NAME"
BACKUP_DIR="$VM_DIR/backups"
mkdir -p "$BACKUP_DIR"

echo "🚀 Backing up VM '$VM_NAME' in project '$PROJECT_ID' (Zone: $ZONE)..."

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ARCHIVE_NAME="backup_${VM_NAME}_${TIMESTAMP}.tar.gz"
LOCAL_SCRIPT_NAME="create_backup_temp_${TIMESTAMP}.sh"

# Create the remote script locally
# We use a quoted EOF ("EOF") to prevent local variable expansion entirely.
# This makes writing the script much safer/cleaner (no need to escape $).
cat << "EOF" > "$LOCAL_SCRIPT_NAME"
#!/bin/bash
set -e

BACKUP_ROOT="/tmp/backup_staging_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_ROOT"
mkdir -p "$BACKUP_ROOT/files"

# 1. Export installed software
echo "📦 Exporting installed software list..."
if command -v dpkg >/dev/null; then
    dpkg --get-selections > "$BACKUP_ROOT/installed_software_dpkg.txt"
fi
if command -v npm >/dev/null; then
    npm list -g --depth=0 > "$BACKUP_ROOT/installed_npm_global.txt" 2>/dev/null || true
fi

# 2. Identify Target Directories
FILES_TO_BACKUP=(".bashrc")
DIRS_TO_BACKUP=(".clawdbot" "clawd" ".openclaw" ".molty" ".moltbot" "molty" "moltbot" "openclaw" ".local/share/signal-cli" ".ssh" ".config/systemd")

# Helper to check and copy
backup_path() {
    local base_dir=$1
    local name=$2
    local use_sudo=$3
    
    local path="$base_dir/$name"
    
    # Check existence
    if [ "$use_sudo" = "true" ]; then
        if sudo test -e "$path"; then
            echo "Found $path (sudo)"
            # Handle nested paths (e.g. .local/share/signal-cli)
            # We need to recreate the parent directory structure relative to base_dir
            local relative_parent=$(dirname "$name")
            local dest_dir="$BACKUP_ROOT/files$base_dir/$relative_parent"
            
            mkdir -p "$dest_dir"
            # Copy with sudo, then chown to current user so we can tar it
            sudo cp -rp "$path" "$dest_dir/"
            sudo chown -R $(whoami) "$BACKUP_ROOT/files$base_dir/$name"
        fi
    else
        if [ -e "$path" ]; then
            echo "Found $path"
            local relative_parent=$(dirname "$name")
            local dest_dir="$BACKUP_ROOT/files$base_dir/$relative_parent"
            mkdir -p "$dest_dir"
            cp -rp "$path" "$dest_dir/"
        fi
    fi
    # Always return true so set -e doesn't kill the script if a file is missing
    return 0
}

echo "🔍 Searching for files to backup..."

# Backup system-level service files
SYSTEM_FILES=("/etc/systemd/system/clawdbot.service" "/etc/systemd/system/openclaw.service")
echo "Checking system files..."
for file in "${SYSTEM_FILES[@]}"; do
    if sudo test -e "$file"; then
        echo "Found system file: $file"
        dest_dir="$BACKUP_ROOT/system_files"
        mkdir -p "$dest_dir"
        sudo cp "$file" "$dest_dir/"
        sudo chown $(whoami) "$dest_dir/$(basename "$file")"
    fi
done

# Check current user home
CURRENT_USER_HOME=$HOME
echo "Checking current user home: $CURRENT_USER_HOME"
for item in "${FILES_TO_BACKUP[@]}" "${DIRS_TO_BACKUP[@]}"; do
    backup_path "$CURRENT_USER_HOME" "$item" "false"
done

# Check openclaw user home if it exists
if id "openclaw" &>/dev/null; then
    OPENCLAW_HOME=$(getent passwd openclaw | cut -d: -f6)
    # Only check if it's different from current user
    if [ "$OPENCLAW_HOME" != "$CURRENT_USER_HOME" ]; then
        echo "Checking openclaw user home: $OPENCLAW_HOME"
        for item in "${FILES_TO_BACKUP[@]}" "${DIRS_TO_BACKUP[@]}"; do
            backup_path "$OPENCLAW_HOME" "$item" "true"
        done
    fi
fi

# Check clawdbot user home if it exists
if id "clawdbot" &>/dev/null; then
    CLAWDBOT_HOME=$(getent passwd clawdbot | cut -d: -f6)
    # Only check if it's different from current user
    if [ "$CLAWDBOT_HOME" != "$CURRENT_USER_HOME" ]; then
        echo "Checking clawdbot user home: $CLAWDBOT_HOME"
        for item in "${FILES_TO_BACKUP[@]}" "${DIRS_TO_BACKUP[@]}"; do
            backup_path "$CLAWDBOT_HOME" "$item" "true"
        done
    fi
fi

# 3. Create Archive
echo "📦 Packing backup..."
cd "$BACKUP_ROOT"
# Use timestamp from directory name for consistency
ARCHIVE_NAME="backup_$(basename $BACKUP_ROOT).tar.gz"
tar -czf "/tmp/${ARCHIVE_NAME}" .
echo "✅ Backup created at /tmp/${ARCHIVE_NAME}"

# Cleanup staging
rm -rf "$BACKUP_ROOT"
EOF

# Copy script to VM
echo "📤 Uploading backup script..."
gcloud compute scp "$LOCAL_SCRIPT_NAME" "${VM_NAME}:/tmp/create_backup.sh" --project="$PROJECT_ID" --zone="$ZONE"

# Execute script
echo "▶️  Running backup script on VM..."
gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --command="bash /tmp/create_backup.sh"

# Find the archive name that was created (since we generate timestamp remotely now)
# We grep the output log for the filename
REMOTE_ARCHIVE_PATH=$(gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --command="ls /tmp/backup_*.tar.gz | head -n 1")
REMOTE_ARCHIVE_NAME=$(basename "$REMOTE_ARCHIVE_PATH")

if [ -z "$REMOTE_ARCHIVE_PATH" ]; then
    echo "❌ Error: Could not find created backup on remote VM."
    rm "$LOCAL_SCRIPT_NAME"
    exit 1
fi

# Download backup
echo "📥 Downloading backup $REMOTE_ARCHIVE_NAME..."
gcloud compute scp "${VM_NAME}:$REMOTE_ARCHIVE_PATH" "$BACKUP_DIR/$REMOTE_ARCHIVE_NAME" --project="$PROJECT_ID" --zone="$ZONE"

# Cleanup remote
echo "🧹 Cleaning up remote files..."
gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --command="rm /tmp/create_backup.sh $REMOTE_ARCHIVE_PATH"

# Cleanup local temp script
rm "$LOCAL_SCRIPT_NAME"

echo "✅ Backup saved to $BACKUP_DIR/$REMOTE_ARCHIVE_NAME"