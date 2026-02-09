#!/bin/bash
set -e

# Configuration
PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project)}"
ZONE="${GCP_ZONE:-us-central1-a}"
REMOTE_USER="${REMOTE_USER:-openclaw}"

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Error: No GCP Project ID found. Please set GCP_PROJECT_ID or configure gcloud."
    exit 1
fi

VM_NAME=""
CLI_ZONE=""

usage() {
    echo "Usage: $0 [OPTIONS] <vm_name>"
    echo ""
    echo "Syncs session data and workspace from a remote VM to local."
    echo ""
    echo "Options:"
    echo "  --zone ZONE         GCP zone (default: $ZONE)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 my-bot"
    echo "  $0 --zone us-east5-a my-bot"
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
            VM_NAME="$1"
            shift
            ;;
    esac
done

# Apply CLI overrides
[ -n "$CLI_ZONE" ] && ZONE="$CLI_ZONE"

if [ -z "$VM_NAME" ]; then
    usage
fi

# Local destinations (Adjust these to match your local setup)
LOCAL_HOME="$HOME"
LOCAL_WORKSPACE_DIR="$LOCAL_HOME/openclaw"
LOCAL_CONFIG_DIR="$LOCAL_HOME/.openclaw"

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
        -C /home/'"$REMOTE_USER"' .openclaw/sessions .openclaw/memory .openclaw/data \
        -C /home/'"$REMOTE_USER"' openclaw 2>/dev/null || echo "Warning: Some paths not found"

    # Change owner to the current user (connected via SSH) so we can download it
    sudo chown $USER:$USER "$ARCHIVE_PATH"

    echo "$ARCHIVE_PATH"
'

# Run the command and capture the path
ARCHIVE_PATH=$(gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap --command="$REMOTE_CMD")
# Trim whitespace
ARCHIVE_PATH=$(echo "$ARCHIVE_PATH" | tr -d '[:space:]')

if [ -z "$ARCHIVE_PATH" ]; then
    echo "❌ Error: Failed to generate remote archive."
    exit 1
fi

echo "⬇️  Downloading bundle: $ARCHIVE_PATH..."
gcloud compute scp --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap "${VM_NAME}:$ARCHIVE_PATH" /tmp/context_sync.tar.gz

# 2. Extract locally
echo "📂 Extracting to local environment..."

# Ensure local dirs exist
mkdir -p "$LOCAL_CONFIG_DIR"
mkdir -p "$LOCAL_WORKSPACE_DIR"

# Extract
# The tar structure is relative: .openclaw/... and openclaw/...
tar -xzf /tmp/context_sync.tar.gz -C "$LOCAL_HOME"

echo "🧹 Cleaning up remote..."
gcloud compute ssh "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --tunnel-through-iap --command="rm -rf $(dirname "$ARCHIVE_PATH")"

echo "✅ Sync Complete!"
echo "   • Sessions/Memory: $LOCAL_CONFIG_DIR"
echo "   • Workspace:       $LOCAL_WORKSPACE_DIR"
