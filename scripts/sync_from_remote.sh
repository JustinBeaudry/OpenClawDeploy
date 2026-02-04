#!/bin/bash
set -e

# Configuration
PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project)}"
ZONE="${GCP_ZONE:-us-central1-a}"
REMOTE_USER="${REMOTE_USER:-clawdbot}"

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Error: No GCP Project ID found. Please set GCP_PROJECT_ID or configure gcloud."
    exit 1
fi

VM_NAME=$1

usage() {
    echo "Usage: $0 <vm_name>"
    echo "Syncs session data and workspace from a remote VM to local."
    exit 1
}

if [ -z "$VM_NAME" ]; then
    usage
fi

# Local destinations (Adjust these to match your local setup)
LOCAL_HOME="$HOME"
LOCAL_CLAWD_DIR="$LOCAL_HOME/clawd"
LOCAL_CONFIG_DIR="$LOCAL_HOME/.clawdbot"

echo "🔄 Syncing Context from Remote ($VM_NAME)..."

# 1. Create a remote backup bundle
echo "📦 Packaging remote data (this requires sudo privileges on remote)..."
REMOTE_CMD='
    # Create temp dir
    TMP_DIR=$(mktemp -d)
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    ARCHIVE_NAME="context_sync_$TIMESTAMP.tar.gz"
    ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_NAME"

    # Tar the important directories (using sudo to access user files)
    # We exclude large/node_modules directories to keep it fast
    # Adjust paths based on expectation of standard openclaw install
    sudo tar -czf "$ARCHIVE_PATH" \
        --exclude="node_modules" \
        --exclude="logs" \
        -C /home/'"$REMOTE_USER"' .clawdbot/sessions .clawdbot/memory .clawdbot/data \
        -C /home/'"$REMOTE_USER"' clawd 2>/dev/null || echo "Warning: Some paths not found"

    # Change owner to the current user (connected via SSH) so we can download it
    sudo chown $USER:$USER "$ARCHIVE_PATH"
    
    echo "$ARCHIVE_PATH"
'

# Run the command and capture the path
ARCHIVE_PATH=$(gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --command="$REMOTE_CMD")
# Trim whitespace
ARCHIVE_PATH=$(echo "$ARCHIVE_PATH" | tr -d '[:space:]')

if [ -z "$ARCHIVE_PATH" ]; then
    echo "❌ Error: Failed to generate remote archive."
    exit 1
fi

echo "⬇️  Downloading bundle: $ARCHIVE_PATH..."
gcloud compute scp --project="$PROJECT_ID" --zone="$ZONE" "${VM_NAME}:$ARCHIVE_PATH" /tmp/context_sync.tar.gz

# 2. Extract locally
echo "📂 Extracting to local environment..."

# Ensure local dirs exist
mkdir -p "$LOCAL_CONFIG_DIR"
mkdir -p "$LOCAL_CLAWD_DIR"

# Extract
# The tar structure is relative: .clawdbot/... and clawd/...
tar -xzf /tmp/context_sync.tar.gz -C "$LOCAL_HOME"

echo "🧹 Cleaning up remote..."
gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --command="rm -rf $(dirname "$ARCHIVE_PATH")"

echo "✅ Sync Complete!"
echo "   • Sessions/Memory: $LOCAL_CONFIG_DIR"
echo "   • Workspace:       $LOCAL_CLAWD_DIR"
