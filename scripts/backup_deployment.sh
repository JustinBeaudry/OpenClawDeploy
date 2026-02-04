#!/bin/bash
set -e

# Configuration
BACKUP_DIR="backups"
PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project)}"
ZONE="${GCP_ZONE:-us-central1-a}"
ENCRYPT_BACKUP="${ENCRYPT_BACKUP:-true}"  # Enable encryption by default

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Error: No GCP Project ID found. Please set GCP_PROJECT_ID or configure gcloud."
    exit 1
fi

VM_NAME=""
NO_ENCRYPT=false

usage() {
    echo "Usage: $0 [OPTIONS] <vm_name>"
    echo ""
    echo "Backs up OpenClaw configurations, sessions, and installed software lists."
    echo ""
    echo "Options:"
    echo "  --no-encrypt    Skip GPG encryption (NOT RECOMMENDED - backup will contain SSH keys)"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  ENCRYPT_BACKUP=false    Disable encryption (same as --no-encrypt)"
    echo "  BACKUP_PASSPHRASE       Passphrase for encryption (will prompt if not set)"
    echo ""
    echo "Backups are stored in: $BACKUP_DIR/<vm_name>/"
    echo ""
    echo "Examples:"
    echo "  $0 my-bot                    # Create encrypted backup"
    echo "  $0 --no-encrypt my-bot       # Create unencrypted backup (not recommended)"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-encrypt)
            NO_ENCRYPT=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "❌ Error: Unknown option $1"
            usage
            ;;
        *)
            VM_NAME="$1"
            shift
            ;;
    esac
done

if [ -z "$VM_NAME" ]; then
    usage
fi

# Determine encryption setting
if [ "$ENCRYPT_BACKUP" = "false" ] || [ "$NO_ENCRYPT" = "true" ]; then
    USE_ENCRYPTION=false
    echo "⚠️  WARNING: Backup will NOT be encrypted. It may contain SSH keys and credentials."
    read -p "Are you sure you want to continue without encryption? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted. Run without --no-encrypt for encrypted backup."
        exit 1
    fi
else
    USE_ENCRYPTION=true
    # Check if gpg is available
    if ! command -v gpg &> /dev/null; then
        echo "❌ Error: gpg is required for encrypted backups. Install it or use --no-encrypt."
        exit 1
    fi
fi

VM_BACKUP_DIR="$BACKUP_DIR/$VM_NAME"
mkdir -p "$VM_BACKUP_DIR"

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
DIRS_TO_BACKUP=(".openclaw" ".local/share/signal-cli" ".ssh" ".config/systemd")

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
SYSTEM_FILES=("/etc/systemd/system/openclaw.service")
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
gcloud compute scp "${VM_NAME}:$REMOTE_ARCHIVE_PATH" "$VM_BACKUP_DIR/$REMOTE_ARCHIVE_NAME" --project="$PROJECT_ID" --zone="$ZONE"

# Cleanup remote
echo "🧹 Cleaning up remote files..."
gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --command="rm /tmp/create_backup.sh $REMOTE_ARCHIVE_PATH"

# Cleanup local temp script
rm "$LOCAL_SCRIPT_NAME"

# Encrypt backup if enabled
if [ "$USE_ENCRYPTION" = "true" ]; then
    echo "🔐 Encrypting backup..."
    ENCRYPTED_NAME="${REMOTE_ARCHIVE_NAME}.gpg"

    if [ -n "$BACKUP_PASSPHRASE" ]; then
        # Use passphrase from environment
        gpg --batch --yes --passphrase "$BACKUP_PASSPHRASE" \
            --symmetric --cipher-algo AES256 \
            -o "$VM_BACKUP_DIR/$ENCRYPTED_NAME" \
            "$VM_BACKUP_DIR/$REMOTE_ARCHIVE_NAME"
    else
        # Prompt for passphrase
        echo "Enter a passphrase for backup encryption (you'll need this to restore):"
        gpg --symmetric --cipher-algo AES256 \
            -o "$VM_BACKUP_DIR/$ENCRYPTED_NAME" \
            "$VM_BACKUP_DIR/$REMOTE_ARCHIVE_NAME"
    fi

    # Securely delete unencrypted backup
    if [ -f "$VM_BACKUP_DIR/$ENCRYPTED_NAME" ]; then
        echo "🗑️  Removing unencrypted backup..."
        rm -f "$VM_BACKUP_DIR/$REMOTE_ARCHIVE_NAME"
        echo "✅ Encrypted backup saved to $VM_BACKUP_DIR/$ENCRYPTED_NAME"
        echo ""
        echo "To decrypt: gpg -d $VM_BACKUP_DIR/$ENCRYPTED_NAME | tar xzf -"
    else
        echo "❌ Error: Encryption failed. Unencrypted backup retained at $VM_BACKUP_DIR/$REMOTE_ARCHIVE_NAME"
        exit 1
    fi
else
    echo "✅ Backup saved to $VM_BACKUP_DIR/$REMOTE_ARCHIVE_NAME"
    echo "⚠️  WARNING: This backup is NOT encrypted and may contain sensitive data."
fi
