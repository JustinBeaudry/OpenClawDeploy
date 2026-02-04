# OpenClaw Deploy

## Project Overview
This project is an **Infrastructure-as-Code (IaC)** toolset designed to automate the provisioning and deployment of **OpenClaw** instances on Google Cloud Platform (GCP). It combines shell scripting (`gcloud` CLI wrapper) for infrastructure management with **Ansible** for configuration management and application deployment.

## Architecture & Structure
*   **`scripts/manage_deployment.sh`**: The primary entry point. It wraps `gcloud` commands to create VMs and `ansible-playbook` to configure them.
*   **`ansible/`**: Contains the Ansible playbook and roles.
    *   `playbook.yml`: Main entry point for Ansible.
    *   `roles/openclaw/`: The primary role handling Docker, Node.js, UFW, and OpenClaw setup.
*   **`inventory/`**: Stores state and configuration for individual VM instances.
    *   `<host-alias>.ini`: Generated Ansible inventory file (e.g., `my-bot.us-central1-a.project.ini`).
    *   `<host-alias>.yml`: Instance-specific configuration (e.g., Tailscale keys, git branches).
*   **`backups/`**: Encrypted backup archives organized by VM name.

## Key Workflows

### 1. Provisioning a New Instance
To create a new VM and deploy OpenClaw:
```bash
# Set GCP Project (optional if set in gcloud config)
export GCP_PROJECT_ID="your-project-id"

# Run the create command
./scripts/manage_deployment.sh create <vm_name>
```
*   **What happens:** Creates a GCP VM -> Configures SSH -> Generates `inventory.ini` -> Runs Ansible playbook.

### 2. Updating an Instance
To apply code updates or configuration changes to an existing VM:
```bash
./scripts/manage_deployment.sh update <vm_name>
```
*   **What happens:** Refreshes SSH config -> Runs Ansible playbook against existing inventory.

## Configuration

### Environment Variables
The `manage_deployment.sh` script respects the following variables:
*   `GCP_PROJECT_ID` (Default: `gcloud config` default)
*   `GCP_ZONE` (Default: `us-central1-a`)
*   `GCP_MACHINE_TYPE` (Default: `t2a-standard-2`)
*   `GCP_DISK_SIZE` (Default: `50GB`)

### Ansible Variables (`vars.yml`)
Located in `inventory/<host-alias>.yml`. Key variables include:
*   `openclaw_install_mode`: `release` (default) or `development`.
*   `tailscale_authkey`: Auth key for auto-joining a Tailscale mesh.
*   `openclaw_repo_url` / `openclaw_repo_branch`: For development mode overrides.

## Development & Conventions
*   **Idempotency:** The Ansible playbook is designed to be idempotent. It can be re-run safely to bring the system to the desired state.
*   **Security:** The setup uses `ufw` to restrict ports (SSH + Tailscale only) and installs OpenClaw as a non-privileged user.
*   **Linting:** Ansible linting is configured in `.ansible-lint` and GitHub Actions.
