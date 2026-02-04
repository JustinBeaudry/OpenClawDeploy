#!/bin/bash
set -e

# OpenClaw Deploy - Deployment Manager
# Provisions and manages OpenClaw instances on GCP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Default Configuration
INVENTORY_DIR="inventory"
PROJECT_ID="${GCP_PROJECT_ID:-}"
ZONE="${GCP_ZONE:-us-central1-a}"
MACHINE_TYPE="${GCP_MACHINE_TYPE:-t2a-standard-2}"
DISK_SIZE="${GCP_DISK_SIZE:-50GB}"
DISK_TYPE="${GCP_DISK_TYPE:-pd-ssd}"
IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"

# Network & Security Configuration
VPC_NAME="openclaw-vpc"
SUBNET_NAME="openclaw-subnet"
SUBNET_RANGE="10.0.0.0/24"
SERVICE_ACCOUNT_NAME="openclaw-sa"

# CLI Options (can override defaults)
CLI_ZONE=""
CLI_MACHINE_TYPE=""
CLI_DISK_SIZE=""
CLI_DISK_TYPE=""
CLI_TAILSCALE_KEY=""
CLI_INSTALL_MODE=""
DRY_RUN=false
SKIP_PREREQ_CHECK=false
VERBOSE=false

# Script arguments
COMMAND=""
VM_NAME=""

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "[DEBUG] $1"
    fi
}

# Derive region from zone (us-central1-a -> us-central1)
get_region() {
    echo "${ZONE%-*}"
}

# Setup custom VPC with subnet for network isolation
setup_vpc() {
    local REGION=$(get_region)

    log_msg "🌐 Setting up isolated VPC network..."

    # Create custom VPC (if not exists)
    if ! gcloud compute networks describe "$VPC_NAME" --project="$PROJECT_ID" &>/dev/null; then
        log_msg "   Creating VPC: $VPC_NAME..."
        gcloud compute networks create "$VPC_NAME" \
            --project="$PROJECT_ID" \
            --subnet-mode=custom
    else
        log_verbose "VPC $VPC_NAME already exists"
    fi

    # Create subnet (if not exists)
    if ! gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        log_msg "   Creating subnet: $SUBNET_NAME ($SUBNET_RANGE)..."
        gcloud compute networks subnets create "$SUBNET_NAME" \
            --project="$PROJECT_ID" \
            --network="$VPC_NAME" \
            --region="$REGION" \
            --range="$SUBNET_RANGE"
    else
        log_verbose "Subnet $SUBNET_NAME already exists"
    fi

    log_msg "✅ VPC network ready"
}

# Setup network infrastructure for private VMs (Cloud NAT + IAP firewall)
setup_network_infrastructure() {
    local REGION=$(get_region)

    log_msg "🔒 Setting up network infrastructure for private VM access..."

    # Create Cloud Router (if not exists)
    if ! gcloud compute routers describe openclaw-router --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        log_msg "   Creating Cloud Router..."
        gcloud compute routers create openclaw-router \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --network="$VPC_NAME"
    else
        log_verbose "Cloud Router already exists"
    fi

    # Create Cloud NAT (if not exists)
    if ! gcloud compute routers nats describe openclaw-nat --router=openclaw-router --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        log_msg "   Creating Cloud NAT for outbound connectivity..."
        gcloud compute routers nats create openclaw-nat \
            --project="$PROJECT_ID" \
            --router=openclaw-router \
            --region="$REGION" \
            --auto-allocate-nat-external-ips \
            --nat-all-subnet-ip-ranges
    else
        log_verbose "Cloud NAT already exists"
    fi

    # Create IAP firewall rule (if not exists)
    if ! gcloud compute firewall-rules describe allow-iap-ssh-$VPC_NAME --project="$PROJECT_ID" &>/dev/null; then
        log_msg "   Creating IAP SSH firewall rule..."
        gcloud compute firewall-rules create allow-iap-ssh-$VPC_NAME \
            --project="$PROJECT_ID" \
            --direction=INGRESS \
            --priority=1000 \
            --network="$VPC_NAME" \
            --action=ALLOW \
            --rules=tcp:22 \
            --source-ranges=35.235.240.0/20
    else
        log_verbose "IAP firewall rule already exists"
    fi

    log_msg "✅ Network infrastructure ready"
}

# Setup dedicated service account with minimal permissions
setup_service_account() {
    local SA_EMAIL="$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com"

    log_msg "👤 Setting up dedicated service account..."

    # Create service account (if not exists)
    if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
        log_msg "   Creating service account: $SERVICE_ACCOUNT_NAME..."
        gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
            --project="$PROJECT_ID" \
            --display-name="OpenClaw VM Service Account"

        # Grant minimal permissions
        log_msg "   Granting logging.logWriter role..."
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:$SA_EMAIL" \
            --role="roles/logging.logWriter" \
            --quiet

        log_msg "   Granting monitoring.metricWriter role..."
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:$SA_EMAIL" \
            --role="roles/monitoring.metricWriter" \
            --quiet
    else
        log_verbose "Service account $SERVICE_ACCOUNT_NAME already exists"
    fi

    log_msg "✅ Service account ready: $SA_EMAIL"
}

# Configure SSH for IAP tunnel access
configure_ssh_for_iap() {
    local HOST_ALIAS="$1"
    local SSH_CONFIG="$HOME/.ssh/config"
    local SSH_CONFIG_DIR="$HOME/.ssh"

    log_msg "🔑 Configuring SSH for IAP tunnel access..."

    # Ensure .ssh directory exists
    mkdir -p "$SSH_CONFIG_DIR"
    chmod 700 "$SSH_CONFIG_DIR"

    # Remove existing entry if present
    if [ -f "$SSH_CONFIG" ]; then
        # Create temp file without the old entry
        sed -i.bak "/^Host $HOST_ALIAS$/,/^Host /{ /^Host $HOST_ALIAS$/d; /^Host /!d; }" "$SSH_CONFIG"
        # Clean up any empty lines at end
        sed -i.bak -e :a -e '/^\s*$/d;N;ba' "$SSH_CONFIG" 2>/dev/null || true
        rm -f "$SSH_CONFIG.bak"
    fi

    # Append new IAP-based SSH config
    cat >> "$SSH_CONFIG" <<EOF

# OpenClaw VM - IAP Tunnel (auto-generated)
Host $HOST_ALIAS
    HostName compute.$VM_NAME
    ProxyCommand gcloud compute start-iap-tunnel $VM_NAME %p --listen-on-stdin --project=$PROJECT_ID --zone=$ZONE
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

    chmod 600 "$SSH_CONFIG"
    log_msg "✅ SSH configured for: $HOST_ALIAS"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS] {create|update} <vm_name>

Commands:
  create    Provision a new VM and deploy OpenClaw
  update    Re-run the deployment playbook on an existing VM

Options:
  --zone ZONE              GCP zone (default: $ZONE)
  --machine-type TYPE      Machine type (default: $MACHINE_TYPE)
  --disk-size SIZE         Boot disk size (default: $DISK_SIZE)
  --disk-type TYPE         Boot disk type: pd-ssd or pd-standard (default: $DISK_TYPE)
  --tailscale-key KEY      Tailscale auth key for auto-connect
  --install-mode MODE      Installation mode: release or development (default: release)
  --dry-run                Show what would be done without making changes
  --skip-prereq-check      Skip prerequisite verification
  --verbose, -v            Enable verbose output
  --help, -h               Show this help message

Environment Variables:
  GCP_PROJECT_ID           Google Cloud project ID (required)
  GCP_ZONE                 Default zone (overridden by --zone)
  GCP_MACHINE_TYPE         Default machine type (overridden by --machine-type)
  GCP_DISK_SIZE            Default disk size (overridden by --disk-size)
  GCP_DISK_TYPE            Default disk type (overridden by --disk-type)

Examples:
  # Create a new deployment with defaults
  $0 create my-bot

  # Create with custom configuration
  $0 create my-bot --zone us-central1-a --machine-type e2-medium

  # Create with Tailscale auto-connect
  $0 create my-bot --tailscale-key tskey-auth-xxxxx

  # Preview what would be done
  $0 create my-bot --dry-run

  # Update existing deployment
  $0 update my-bot

  # Update with development mode
  $0 update my-bot --install-mode development

For more information, see: README.md and QUICKSTART.md
EOF
    exit 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --zone)
                CLI_ZONE="$2"
                shift 2
                ;;
            --machine-type)
                CLI_MACHINE_TYPE="$2"
                shift 2
                ;;
            --disk-size)
                CLI_DISK_SIZE="$2"
                shift 2
                ;;
            --disk-type)
                CLI_DISK_TYPE="$2"
                if [[ "$CLI_DISK_TYPE" != "pd-ssd" && "$CLI_DISK_TYPE" != "pd-standard" ]]; then
                    echo "❌ Error: --disk-type must be 'pd-ssd' or 'pd-standard'"
                    exit 1
                fi
                shift 2
                ;;
            --tailscale-key)
                CLI_TAILSCALE_KEY="$2"
                shift 2
                ;;
            --install-mode)
                CLI_INSTALL_MODE="$2"
                if [[ "$CLI_INSTALL_MODE" != "release" && "$CLI_INSTALL_MODE" != "development" ]]; then
                    echo "❌ Error: --install-mode must be 'release' or 'development'"
                    exit 1
                fi
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-prereq-check)
                SKIP_PREREQ_CHECK=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            -*)
                echo "❌ Error: Unknown option $1"
                echo "Use --help for usage information."
                exit 1
                ;;
            *)
                # Positional arguments: COMMAND and VM_NAME
                if [ -z "$COMMAND" ]; then
                    COMMAND="$1"
                elif [ -z "$VM_NAME" ]; then
                    VM_NAME="$1"
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
    [ -n "$CLI_MACHINE_TYPE" ] && MACHINE_TYPE="$CLI_MACHINE_TYPE"
    [ -n "$CLI_DISK_SIZE" ] && DISK_SIZE="$CLI_DISK_SIZE"
    [ -n "$CLI_DISK_TYPE" ] && DISK_TYPE="$CLI_DISK_TYPE"

    # Get project ID (must be set)
    if [ -z "$PROJECT_ID" ]; then
        PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
    fi

    if [ -z "$PROJECT_ID" ]; then
        echo "❌ Error: No GCP Project ID found."
        echo "   Set GCP_PROJECT_ID environment variable or run: gcloud config set project <project-id>"
        exit 1
    fi
}

validate_args() {
    if [ -z "$COMMAND" ] || [ -z "$VM_NAME" ]; then
        echo "❌ Error: Missing required arguments"
        echo ""
        usage
    fi

    # Validate VM_NAME
    if [[ ! "$VM_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
        echo "❌ Error: Invalid VM name '$VM_NAME'"
        echo "   Only alphanumeric characters and hyphens are allowed."
        exit 1
    fi

    # Validate COMMAND
    if [[ "$COMMAND" != "create" && "$COMMAND" != "update" ]]; then
        echo "❌ Error: Unknown command '$COMMAND'"
        echo "   Use 'create' or 'update'."
        exit 1
    fi
}

show_config() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                  Deployment Configuration                ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Command:       $COMMAND"
    echo "  VM Name:       $VM_NAME"
    echo "  Project:       $PROJECT_ID"
    echo "  Zone:          $ZONE"
    echo "  Machine Type:  $MACHINE_TYPE"
    echo "  Disk:          $DISK_SIZE ($DISK_TYPE)"
    echo "  Network:       $VPC_NAME / $SUBNET_NAME"
    echo "  Image:         $IMAGE_FAMILY ($IMAGE_PROJECT)"
    [ -n "$CLI_INSTALL_MODE" ] && echo "  Install Mode:  $CLI_INSTALL_MODE"
    [ -n "$CLI_TAILSCALE_KEY" ] && echo "  Tailscale:     (key provided)"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "  ℹ️  DRY RUN MODE - No changes will be made"
        echo ""
    fi
}

run_prereq_check() {
    if [ "$SKIP_PREREQ_CHECK" = true ]; then
        log_verbose "Skipping prerequisite check (--skip-prereq-check)"
        return 0
    fi

    if [ -x "$SCRIPT_DIR/check-prerequisites.sh" ]; then
        log_msg "🔍 Running prerequisite check..."
        if ! "$SCRIPT_DIR/check-prerequisites.sh"; then
            echo ""
            echo "❌ Prerequisite check failed. Fix issues above or use --skip-prereq-check to bypass."
            exit 1
        fi
        echo ""
    fi
}

create_vm() {
    HOST_ALIAS="$VM_NAME.$ZONE.$PROJECT_ID"
    INVENTORY_FILE="$INVENTORY_DIR/$HOST_ALIAS.ini"
    VARS_FILE="$INVENTORY_DIR/$HOST_ALIAS.yml"

    if [ -f "$INVENTORY_FILE" ]; then
        echo "⚠️  Inventory for '$VM_NAME' already exists: $INVENTORY_FILE"
        if [ "$DRY_RUN" = true ]; then
            echo "   [DRY RUN] Would prompt for overwrite confirmation"
            return
        fi
        read -p "Do you want to re-provision/overwrite? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        local SA_EMAIL="$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com"
        echo "[DRY RUN] Would create directory: $INVENTORY_DIR"
        echo "[DRY RUN] Would setup VPC: $VPC_NAME with subnet $SUBNET_NAME ($SUBNET_RANGE)"
        echo "[DRY RUN] Would setup service account: $SA_EMAIL (logging + monitoring only)"
        echo "[DRY RUN] Would setup network infrastructure (Cloud Router, NAT, IAP firewall)"
        echo "[DRY RUN] Would execute: gcloud compute instances create $VM_NAME \\"
        echo "            --project=$PROJECT_ID \\"
        echo "            --zone=$ZONE \\"
        echo "            --machine-type=$MACHINE_TYPE \\"
        echo "            --image-family=$IMAGE_FAMILY \\"
        echo "            --image-project=$IMAGE_PROJECT \\"
        echo "            --boot-disk-size=$DISK_SIZE \\"
        echo "            --boot-disk-type=$DISK_TYPE \\"
        echo "            --network=$VPC_NAME \\"
        echo "            --subnet=$SUBNET_NAME \\"
        echo "            --no-address \\"
        echo "            --service-account=$SA_EMAIL \\"
        echo "            --scopes=logging-write,monitoring-write \\"
        echo "            --metadata=enable-oslogin=TRUE"
        echo "[DRY RUN] Would configure SSH for IAP tunnel access"
        echo "[DRY RUN] Would generate $INVENTORY_FILE and $VARS_FILE"
        return
    fi

    mkdir -p "$INVENTORY_DIR"

    local SA_EMAIL="$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com"

    # Setup isolated VPC network
    setup_vpc

    # Setup dedicated service account with minimal permissions
    setup_service_account

    # Setup network infrastructure (Cloud NAT for egress, IAP for SSH)
    setup_network_infrastructure

    log_msg "🚀 Creating VM '$VM_NAME' in project '$PROJECT_ID' (Zone: $ZONE)..."
    log_verbose "Machine type: $MACHINE_TYPE, Disk: $DISK_SIZE ($DISK_TYPE)"

    gcloud compute instances create "$VM_NAME" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --image-family="$IMAGE_FAMILY" \
        --image-project="$IMAGE_PROJECT" \
        --boot-disk-size="$DISK_SIZE" \
        --boot-disk-type="$DISK_TYPE" \
        --network="$VPC_NAME" \
        --subnet="$SUBNET_NAME" \
        --no-address \
        --service-account="$SA_EMAIL" \
        --scopes=logging-write,monitoring-write \
        --metadata=enable-oslogin=TRUE

    log_msg "⏳ Waiting for VM to initialize..."
    sleep 20

    log_msg "✅ VM Created (private IP only - no public exposure)"

    # Configure SSH for IAP tunnel
    configure_ssh_for_iap "$HOST_ALIAS"

    # Create Inventory File
    log_msg "📝 Generating inventory file: $INVENTORY_FILE"
    cat > "$INVENTORY_FILE" <<EOF
[openclaw_hosts]
$HOST_ALIAS
EOF

    # Create vars.yml with comprehensive template
    generate_vars_file "$VARS_FILE"

    log_msg "📂 Instance configuration saved to $INVENTORY_DIR/"
}

generate_vars_file() {
    local VARS_FILE="$1"

    # Only generate if it doesn't exist (preserve user edits)
    if [ -f "$VARS_FILE" ]; then
        log_msg "📝 $VARS_FILE already exists, preserving existing configuration"

        # But apply CLI overrides if provided
        if [ -n "$CLI_INSTALL_MODE" ]; then
            log_msg "   Updating openclaw_install_mode to: $CLI_INSTALL_MODE"
            sed -i.bak "s/^openclaw_install_mode:.*/openclaw_install_mode: \"$CLI_INSTALL_MODE\"/" "$VARS_FILE"
            rm -f "$VARS_FILE.bak"
        fi
        if [ -n "$CLI_TAILSCALE_KEY" ]; then
            log_msg "   Updating tailscale_authkey"
            sed -i.bak "s/^tailscale_authkey:.*/tailscale_authkey: \"$CLI_TAILSCALE_KEY\"/" "$VARS_FILE"
            rm -f "$VARS_FILE.bak"
        fi
        return
    fi

    log_msg "📝 Generating variables file: $VARS_FILE"

    # Determine values (CLI overrides or defaults)
    local INSTALL_MODE="${CLI_INSTALL_MODE:-release}"
    local TAILSCALE_KEY="${CLI_TAILSCALE_KEY:-}"

    cat > "$VARS_FILE" << 'VARS_TEMPLATE'
# OpenClaw Deployment Variables
# ═══════════════════════════════════════════════════════════════════
# Edit this file to customize your deployment, then run:
#   ./scripts/manage_deployment.sh update <vm-name>
#
# For secrets (tailscale_authkey), consider using ansible-vault:
#   ansible-vault encrypt this_file.yml
#
# Documentation: https://github.com/openclaw/openclaw-deploy
# ═══════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────
# INSTALLATION MODE
# ─────────────────────────────────────────────────────────────────────
# 'release'     - Install from npm (recommended for production)
#                 Uses: pnpm install -g openclaw@latest
#
# 'development' - Build from source (for development/testing)
#                 Clones repo, runs pnpm build, symlinks binary
#                 Adds aliases: openclaw-rebuild, openclaw-dev, openclaw-pull
VARS_TEMPLATE

    echo "openclaw_install_mode: \"$INSTALL_MODE\"" >> "$VARS_FILE"

    cat >> "$VARS_FILE" << 'VARS_TEMPLATE'

# ─────────────────────────────────────────────────────────────────────
# TAILSCALE VPN (Zero Trust Access)
# ─────────────────────────────────────────────────────────────────────
# Tailscale provides secure remote access without exposing ports publicly.
#
# Get your auth key from: https://login.tailscale.com/admin/settings/keys
# - Use "Reusable" keys if you plan to recreate VMs often
# - Leave empty to configure Tailscale manually after deployment
#
# After deployment, access OpenClaw via Tailscale IP:
#   http://100.x.y.z:3000
VARS_TEMPLATE

    echo "tailscale_authkey: \"$TAILSCALE_KEY\"" >> "$VARS_FILE"

    cat >> "$VARS_FILE" << 'VARS_TEMPLATE'

# ─────────────────────────────────────────────────────────────────────
# SSH ACCESS
# ─────────────────────────────────────────────────────────────────────
# Add your SSH public keys here to enable SSH access as the 'openclaw' user.
# This is in addition to gcloud OS Login which uses your Google identity.
#
# Generate a key: ssh-keygen -t ed25519 -f ~/.ssh/openclaw-key
# Get public key: cat ~/.ssh/openclaw-key.pub
#
# Example:
# openclaw_ssh_keys:
#   - "ssh-ed25519 AAAAC3... user@laptop"
#   - "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... user@desktop"
openclaw_ssh_keys: []

# ─────────────────────────────────────────────────────────────────────
# DEVELOPMENT MODE SETTINGS
# ─────────────────────────────────────────────────────────────────────
# Only used when openclaw_install_mode: "development"
#
# Customize these to use your own fork or a specific branch:
# openclaw_repo_url: "https://github.com/YOUR_USERNAME/openclaw.git"
# openclaw_repo_branch: "feature-branch"

# ─────────────────────────────────────────────────────────────────────
# ADVANCED SETTINGS (usually don't need to change)
# ─────────────────────────────────────────────────────────────────────
# Node.js version (must be 20.x or higher)
# nodejs_version: "22.x"

# OpenClaw port (change if 3000 conflicts with other services)
# openclaw_port: 3000

# OpenClaw user account (change only if you have specific requirements)
# openclaw_user: openclaw
# openclaw_home: /home/openclaw
VARS_TEMPLATE

    log_msg "✅ Generated $VARS_FILE with full documentation"
}

run_ansible() {
    HOST_ALIAS="$VM_NAME.$ZONE.$PROJECT_ID"
    INVENTORY_FILE="$INVENTORY_DIR/$HOST_ALIAS.ini"
    VARS_FILE="$INVENTORY_DIR/$HOST_ALIAS.yml"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would run: ansible-playbook -i $INVENTORY_FILE ansible/playbook.yml -e @$VARS_FILE"
        return
    fi

    log_msg "🔄 Starting Ansible Deployment..."

    if [ ! -f "$INVENTORY_FILE" ]; then
        log_msg "❌ Error: Inventory file not found: $INVENTORY_FILE"
        echo ""
        echo "This can happen if:"
        echo "  1. The deployment was never created (run 'create' first)"
        echo "  2. The inventory/ directory was deleted"
        echo ""
        echo "To fix: ./scripts/manage_deployment.sh create $VM_NAME"
        exit 1
    fi

    # Apply any CLI overrides to vars.yml before running
    if [ -n "$CLI_INSTALL_MODE" ] || [ -n "$CLI_TAILSCALE_KEY" ]; then
        generate_vars_file "$VARS_FILE"
    fi

    # Ensure requirements are installed
    if [ -f "ansible/requirements.yml" ]; then
        log_msg "📦 Installing Ansible requirements..."
        ansible-galaxy collection install -r ansible/requirements.yml
    fi

    log_msg "▶️  Running Playbook..."
    ansible-playbook -i "$INVENTORY_FILE" ansible/playbook.yml -e "@$VARS_FILE"
}

# Main execution
main() {
    parse_args "$@"
    validate_args
    show_config

    case "$COMMAND" in
        create)
            run_prereq_check
            create_vm
            if [ "$DRY_RUN" != true ]; then
                run_ansible
            fi
            ;;
        update)
            HOST_ALIAS="$VM_NAME.$ZONE.$PROJECT_ID"
            INVENTORY_FILE="$INVENTORY_DIR/$HOST_ALIAS.ini"

            if [ ! -f "$INVENTORY_FILE" ]; then
                log_msg "❌ Inventory for '$VM_NAME' not found: $INVENTORY_FILE"
                echo ""
                echo "Available inventories:"
                ls -1 "$INVENTORY_DIR"/*.ini 2>/dev/null | sed 's|.*/||; s|\.ini$||' || echo "  (none)"
                echo ""
                echo "To create a new deployment: ./scripts/manage_deployment.sh create $VM_NAME"
                exit 1
            fi

            if [ "$DRY_RUN" != true ]; then
                # Ensure SSH config is set for IAP tunnel
                configure_ssh_for_iap "$HOST_ALIAS"
            fi
            run_ansible
            ;;
    esac

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  DRY RUN COMPLETE - No changes were made"
        echo "  Remove --dry-run to execute these operations"
        echo "═══════════════════════════════════════════════════════════"
    fi
}

main "$@"
