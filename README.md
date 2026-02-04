# OpenClaw Deploy

**OpenClaw Deploy** is a command-line tool designed to simplify the provisioning and management of [OpenClaw](https://github.com/openclaw/openclaw) instances on Google Cloud Platform (GCP). It automates infrastructure creation using `gcloud` and application deployment using `ansible`.

> **New to OpenClaw Deploy?** Check out the [QUICKSTART.md](QUICKSTART.md) for a 5-minute setup guide.

## Features

- **One-Command Provisioning**: Creates a VM, configures SSH, and deploys OpenClaw in a single step
- **CLI Flags**: Configure zone, machine type, Tailscale key, and more directly from the command line
- **Dry-Run Mode**: Preview what will happen before making any changes
- **Prerequisite Checker**: Validates your environment before deployment
- **Encrypted Backups**: GPG-encrypted backups by default to protect SSH keys and credentials
- **Secure Defaults**: Limited sudo access, Docker hardening, UFW firewall, Tailscale VPN
- **Idempotent Updates**: Safely re-run deployments to converge to desired state

## Prerequisites

- [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed and authenticated
- [Ansible 2.14+](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) installed locally
- A GCP Project with Compute Engine API and IAP API enabled

**Verify your setup:**

```bash
./scripts/check-prerequisites.sh
```

## Quick Start

```bash
# 1. Authenticate with GCP
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# 2. Enable required APIs
gcloud services enable compute.googleapis.com iap.googleapis.com

# 3. Create a deployment
./scripts/manage_deployment.sh create my-bot

# 4. SSH in via IAP tunnel and run onboarding
gcloud compute ssh my-bot --zone=us-central1-a --tunnel-through-iap
sudo su - openclaw
openclaw onboard --install-daemon
```

## Usage

### Create a New Deployment

```bash
# Basic (uses defaults)
./scripts/manage_deployment.sh create my-bot

# With custom options
./scripts/manage_deployment.sh create my-bot \
    --zone us-central1-a \
    --machine-type e2-medium \
    --tailscale-key tskey-auth-xxxxx

# Preview without making changes
./scripts/manage_deployment.sh create my-bot --dry-run
```

### Update an Existing Deployment

```bash
# Re-run playbook with current vars.yml
./scripts/manage_deployment.sh update my-bot

# Update with CLI overrides
./scripts/manage_deployment.sh update my-bot --install-mode development
```

### CLI Options

| Option | Description |
| :--- | :--- |
| `--zone ZONE` | GCP zone (default: us-central1-a) |
| `--machine-type TYPE` | Machine type (default: t2a-standard-2) |
| `--disk-size SIZE` | Boot disk size (default: 50GB) |
| `--disk-type TYPE` | Boot disk type: pd-ssd or pd-standard (default: pd-ssd) |
| `--tailscale-key KEY` | Tailscale auth key for auto-connect |
| `--install-mode MODE` | `release` (npm) or `development` (source) |
| `--dry-run` | Preview without making changes |
| `--help` | Show all options |

### Environment Variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `GCP_PROJECT_ID` | `(gcloud config)` | Google Cloud project ID |
| `GCP_ZONE` | `us-central1-a` | The GCP zone to deploy in |
| `GCP_MACHINE_TYPE` | `t2a-standard-2` | The machine type (CPU/RAM) |
| `GCP_DISK_SIZE` | `50GB` | The size of the boot disk |
| `GCP_DISK_TYPE` | `pd-ssd` | Boot disk type (pd-ssd or pd-standard) |

## Backup & Restore

```bash
# Create encrypted backup (default)
./scripts/backup_deployment.sh my-bot

# Create unencrypted backup (not recommended)
./scripts/backup_deployment.sh --no-encrypt my-bot

# Restore from backup
./scripts/restore_deployment.sh my-bot backups/my-bot/backup_my-bot_20260203.tar.gz.gpg
```

## Configuration

Instance configurations are stored in `inventory/`:

```
inventory/
├── my-bot.us-central1-a.my-project.ini   # Ansible inventory
└── my-bot.us-central1-a.my-project.yml   # Instance variables
```

Backups are stored separately in `backups/<vm-name>/`.

Edit the `.yml` file to customize your deployment:

```yaml
# Installation mode
openclaw_install_mode: "release"  # or "development"

# Tailscale VPN
tailscale_authkey: "tskey-auth-xxxxx"

# SSH keys for openclaw user
openclaw_ssh_keys:
  - "ssh-ed25519 AAAAC3... user@laptop"

# Development mode settings
# openclaw_repo_url: "https://github.com/YOUR_USER/openclaw.git"
# openclaw_repo_branch: "feature-branch"
```

## Security & Access

OpenClaw Deploy enforces a **Zero Trust** network model with private VMs and [Tailscale](https://tailscale.com/) VPN.

### Connecting to Your VM

VMs are private by default (no public IP) for security. Connect via IAP tunnel:

```bash
# SSH via IAP (recommended)
gcloud compute ssh <vm-name> --zone=<zone> --tunnel-through-iap

# Or use the configured SSH alias
ssh <vm-name>.<zone>.<project-id>
```

### Hardened Security Model

- **Isolated VPC**: Dedicated `openclaw-vpc` network isolates workloads from other projects
- **No Public IP**: VMs have no external IP address, not discoverable via Shodan or port scanners
- **Cloud NAT**: Outbound connectivity via Cloud NAT for package updates and external APIs
- **IAP SSH**: SSH access via Identity-Aware Proxy with Google authentication
- **Least-Privilege Service Account**: Dedicated `openclaw-sa` with only logging and monitoring permissions
- **SSD Storage**: Fast pd-ssd boot disks by default for better performance
- **Limited Sudo**: openclaw user has NOPASSWD only for specific commands (tailscale, systemctl)
- **Docker Hardening**: User namespace remapping, no-new-privileges, IPv6 iptables
- **Encrypted Backups**: GPG encryption by default

### Setup Tailscale

1. Get an auth key from [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
2. Deploy with the key:
   ```bash
   ./scripts/manage_deployment.sh create my-bot --tailscale-key tskey-auth-xxxxx
   ```
3. Access via Tailscale IP: `http://100.x.y.z:3000`

## Using AI Assistants with OpenClaw

OpenClaw works with any LLM provider, but you can maximize value by using CLI-based AI assistants that leverage your existing subscriptions—avoiding per-token API fees entirely.

### Recommended Setup

| Tool | Use Case | Subscription |
| :--- | :--- | :--- |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | General reasoning, research, planning | [Google AI Ultra](https://one.google.com/explore-plan/gemini-advanced) ($125/mo intro, then $250/mo) |
| [Claude Code](https://claude.ai/code) | Programming, code generation, debugging | [Claude Max](https://claude.ai/pricing) ($100-200/mo) |

### Why This Approach?

- **No API fees**: Use your subscription's included tokens instead of pay-per-use APIs
- **Higher limits**: Subscription plans typically offer more generous rate limits
- **Better models**: Access to latest models (Gemini 2.5 Pro, Claude Opus 4.5) included in subscription

### Example Configuration

Configure OpenClaw to use Gemini CLI as the default brain for general tasks:

```bash
# Install Gemini CLI
npm install -g @anthropic-ai/gemini-cli

# Configure as default
openclaw config set default_model gemini-2.5-pro
```

For programming-heavy workloads, use Claude Code:

```bash
# Claude Code handles code generation, refactoring, debugging
# Run from your project directory
claude
```

### Author's Setup

This project uses **Gemini CLI** (Gemini 2.5 Pro) as the primary reasoning engine for research, planning, and general tasks, with **Claude Code** (Claude Opus 4.5) for programming-specific work. This combination provides excellent coverage without API costs beyond the monthly subscriptions.

## Parallel Development

Run a local OpenClaw instance while using remote infrastructure (Signal/WhatsApp gateway):

```bash
# Create SSH tunnel to remote gateway
gcloud compute ssh my-bot -- -L 8080:localhost:8080 -N

# Configure local instance to use tunnel
# In openclaw.json:
# "channels": { "signal": { "httpUrl": "http://127.0.0.1:8080" } }
```

**Important:** Stop the remote service first: `systemctl --user stop openclaw`

## Cost Estimates

Default configuration: **t2a-standard-2** (ARM) in US region with SSD storage.

| Resource | Specification | Est. Monthly Cost |
| :--- | :--- | :--- |
| **Compute** | t2a-standard-2 (2 vCPU, 8GB RAM) | ~$56 |
| **Storage** | 50GB SSD Persistent Disk (pd-ssd) | ~$8.50 |
| **Cloud NAT** | NAT gateway + data processing | ~$1-5 |
| **Network** | Egress (varies) | ~$0-10 |
| **Total** | | **~$66-80/month** |

*Use `--disk-type pd-standard` for lower storage costs (~$2/month for 50GB).*

## Troubleshooting

| Issue | Solution |
| :--- | :--- |
| SSH connection failed | Use `gcloud compute ssh <vm> --tunnel-through-iap` |
| Permission denied | Ensure your GCP user has `Compute Instance Admin` and `IAP-secured Tunnel User` roles |
| Ansible unreachable | Wait 1-2 minutes for VM to initialize, then retry `update` |
| Tailscale not connecting | SSH in via IAP and run `sudo tailscale up` manually |
| IAP API not enabled | Run `gcloud services enable iap.googleapis.com` |

Run the prerequisite checker to diagnose issues:

```bash
./scripts/check-prerequisites.sh
```

## Documentation

- [QUICKSTART.md](QUICKSTART.md) - 5-minute getting started guide
- [CLAUDE.md](CLAUDE.md) - Guide for AI assistants working with this codebase
- [ansible/README.md](ansible/README.md) - Detailed Ansible documentation

## License

MIT
