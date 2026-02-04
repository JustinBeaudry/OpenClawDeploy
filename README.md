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
- A GCP Project with Compute Engine API enabled

**Verify your setup:**

```bash
./scripts/check-prerequisites.sh
```

## Quick Start

```bash
# 1. Authenticate with GCP
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# 2. Create a deployment
./scripts/manage_deployment.sh create my-bot

# 3. SSH in and run onboarding
gcloud compute ssh my-bot
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

## Backup & Restore

```bash
# Create encrypted backup (default)
./scripts/backup_deployment.sh my-bot

# Create unencrypted backup (not recommended)
./scripts/backup_deployment.sh --no-encrypt my-bot

# Restore from backup
./scripts/restore_deployment.sh my-bot backups/backup_my-bot_20260203.tar.gz.gpg
```

## Configuration

Deployments are stored in `deployments/<vm-name>/`:

```
deployments/
└── my-bot/
    ├── inventory.ini   # Generated Ansible inventory
    └── vars.yml        # Customizable variables
```

Edit `vars.yml` to customize your deployment:

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

## Security & Access (Tailscale)

OpenClaw Deploy enforces a **Zero Trust** network model using [Tailscale](https://tailscale.com/).

### Hardened Security Model

- **Public Firewall**: Only SSH (22) open; all other ports blocked
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

Default configuration: **t2a-standard-2** (ARM) in US region.

| Resource | Specification | Est. Monthly Cost |
| :--- | :--- | :--- |
| **Compute** | t2a-standard-2 (2 vCPU, 8GB RAM) | ~$56 |
| **Storage** | 50GB Standard Persistent Disk | ~$2 |
| **Network** | Egress (varies) | ~$0-10 |
| **Total** | | **~$58/month** |

## Troubleshooting

| Issue | Solution |
| :--- | :--- |
| SSH connection failed | Run `gcloud compute config-ssh` to refresh SSH config |
| Permission denied | Ensure your GCP user has `Compute Instance Admin` role |
| Ansible unreachable | Wait 1-2 minutes for VM to initialize, then retry `update` |
| Tailscale not connecting | SSH in and run `sudo tailscale up` manually |

Run the prerequisite checker to diagnose issues:

```bash
./scripts/check-prerequisites.sh
```

## Documentation

- [QUICKSTART.md](QUICKSTART.md) - 5-minute getting started guide
- [CLAUDE.md](CLAUDE.md) - Guide for AI assistants working with this codebase
- [deployment/README.md](deployment/README.md) - Detailed Ansible documentation

## License

MIT
