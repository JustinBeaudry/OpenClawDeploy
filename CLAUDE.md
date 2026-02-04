# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenClaw Deploy is an Infrastructure-as-Code (IaC) toolset that automates provisioning and deployment of OpenClaw instances on Google Cloud Platform. It combines:
- **Shell scripts** (`gcloud` CLI wrappers) for VM provisioning
- **Ansible playbooks** for configuration management and application deployment
- **Tailscale VPN** for zero-trust secure access

## Architecture

```
scripts/manage_deployment.sh  →  GCP VM Creation  →  Ansible Playbook
                                 (gcloud CLI)         (ansible/)
```

The workflow: Create GCP VM → Configure SSH → Generate inventory → Run Ansible playbook

### Key Directories

- `scripts/` - CLI entry points (`manage_deployment.sh`, `backup_deployment.sh`, `restore_deployment.sh`)
- `ansible/` - Ansible playbook and roles
  - `playbook.yml` - Main Ansible entry point
  - `roles/openclaw/tasks/` - Task files organized by function (system-tools, docker, tailscale, firewall, nodejs, openclaw)
  - `roles/openclaw/defaults/main.yml` - All configurable variables
- `inventory/` - Instance-specific config (git-ignored)
  - `<host-alias>.ini` - Generated Ansible inventory (e.g., `my-bot.us-central1-a.project.ini`)
  - `<host-alias>.yml` - Instance variables (Tailscale keys, install mode, etc.)
- `backups/` - Encrypted backup archives (git-ignored)

### OS Abstraction Pattern

Task files follow an OS-dispatch pattern:
- `<task>.yml` - Dispatcher that detects OS and includes appropriate file
- `<task>-linux.yml` - Linux-specific implementation
- `<task>-macos.yml` - macOS-specific implementation

## Commands

### Deployment Operations

```bash
# Check prerequisites before deploying
./scripts/check-prerequisites.sh

# Create new deployment
./scripts/manage_deployment.sh create <vm_name>

# Create with custom options
./scripts/manage_deployment.sh create <vm_name> --zone us-central1-a --machine-type e2-medium

# Preview what would happen (dry run)
./scripts/manage_deployment.sh create <vm_name> --dry-run

# Update existing deployment
./scripts/manage_deployment.sh update <vm_name>

# Update with CLI overrides
./scripts/manage_deployment.sh update <vm_name> --install-mode development --tailscale-key tskey-xxx

# Backup (encrypted by default)
./scripts/backup_deployment.sh <vm_name>

# Restore from backup
./scripts/restore_deployment.sh <vm_name> <backup_file>
```

### Linting (run from ansible/ directory)

```bash
ansible-lint playbook.yml        # Ansible linting
yamllint .                        # YAML linting
ansible-playbook playbook.yml --syntax-check  # Syntax validation
```

### Manual Ansible Execution (from ansible/)

```bash
# Install Ansible collections first
ansible-galaxy collection install -r requirements.yml

# Run playbook with variables
./run-playbook.sh -e openclaw_install_mode=development

# Or directly
ansible-playbook playbook.yml --ask-become-pass -e @vars.yml
```

## Configuration

### Environment Variables (GCP)

| Variable | Default | Description |
|----------|---------|-------------|
| `GCP_PROJECT_ID` | gcloud config | Google Cloud project ID |
| `GCP_ZONE` | `us-central1-a` | Deployment zone |
| `GCP_MACHINE_TYPE` | `t2a-standard-2` | Instance type (ARM) |
| `GCP_DISK_SIZE` | `50GB` | Boot disk size |
| `GCP_DISK_TYPE` | `pd-ssd` | Boot disk type (pd-ssd or pd-standard) |

### Ansible Variables (vars.yml)

| Variable | Default | Description |
|----------|---------|-------------|
| `openclaw_install_mode` | `release` | `release` or `development` |
| `tailscale_authkey` | `""` | Auto-join Tailscale mesh |
| `openclaw_repo_url` | github.com/openclaw | Git repo (dev mode) |
| `openclaw_repo_branch` | `main` | Git branch (dev mode) |

## Development Guidelines

- **Idempotency**: All Ansible tasks must be safe to re-run
- **Linting**: Code must pass `ansible-lint` (see `.ansible-lint` for skipped rules) and `yamllint`
- **Security model**: Zero-trust via Tailscale, UFW firewall, non-root execution, Docker isolation
- **YAML formatting**: 2-space indentation, max 120 char lines (see `.yamllint`)

## Security Model

- **Isolated VPC**: Dedicated `openclaw-vpc` network with custom subnet for workload isolation
- **No public IP**: VMs have private IPs only, not discoverable via Shodan or port scanners
- **IAP SSH access**: SSH via Identity-Aware Proxy with Google authentication (no exposed SSH port)
- **Cloud NAT**: Outbound-only connectivity for package updates and external APIs
- **Least-privilege service account**: Dedicated `openclaw-sa` with only logging and monitoring permissions
- **Limited sudo**: openclaw user has restricted NOPASSWD access to specific commands only (tailscale, systemctl)
- **Docker hardening**: userns-remap enabled, no-new-privileges, ip6tables enabled
- **Encrypted backups**: Backups are GPG-encrypted by default (use `--no-encrypt` to disable)
- **Homebrew verification**: Install script is downloaded and validated before execution

### Linting Exceptions (from .ansible-lint)

- `var-naming[no-role-prefix]` - Variables don't require role prefix
- `risky-shell-pipe` - Pipefail handled manually where needed
- `command-instead-of-module` - curl for GPG keys is intentional
