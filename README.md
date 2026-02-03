# OpenClaw Deploy

**OpenClaw Deploy** is a command-line tool designed to simplify the provisioning and management of [OpenClaw](https://github.com/openclaw/openclaw) instances on Google Cloud Platform (GCP). It automates infrastructure creation using `gcloud` and application deployment using `ansible`.

## Features

-   **One-Command Provisioning**: Creates a VM, configures SSH, and deploys OpenClaw in a single step.
-   **Idempotent Updates**: Easily update existing deployments without recreating infrastructure.
-   **Environment Configurable**: customize project, zone, machine type, and disk size via environment variables.
-   **Secure Defaults**: Uses secure Ubuntu LTS images and configures OS login.

## Prerequisites

-   [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed and authenticated.
-   [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) installed locally.
-   A GCP Project with Compute Engine API enabled.

## Configuration

You can configure the deployment using the following environment variables.

| Variable | Default | Description |
| :--- | :--- | :--- |
| `GCP_PROJECT_ID` | `(gcloud config default)` | **Required.** The ID of your Google Cloud project. |
| `GCP_ZONE` | `us-east5-a` | The GCP zone to deploy the VM in. |
| `GCP_MACHINE_TYPE` | `t2a-standard-2` | The machine type (CPU/RAM). See [Cost Estimates](#cost-estimates). |
| `GCP_DISK_SIZE` | `50GB` | The size of the boot disk. |

## Parallel Development

You can run a local instance of the agent (e.g., for development or debugging) while leveraging the remote infrastructure (Signal/WhatsApp gateway) on your VM.

### Method: SSH Tunneling

To connect your local agent to the remote Signal daemon (running on the VM), create an SSH tunnel:

```bash
# Forward remote port 8080 (Signal) to local port 8080
gcloud compute ssh <vm-name> --project=<project-id> --zone=<zone> -- -L 8080:localhost:8080 -N
```

Then, configure your local bot to use the local tunnel:

```json
// clawdbot.json (local)
"channels": {
  "signal": {
    "httpUrl": "http://127.0.0.1:8080"
  }
}
```

**⚠️ Important:** You should stop the remote `clawdbot` service (`systemctl --user stop clawdbot`) before running your local instance to prevent both agents from competing for incoming messages.

## Security & Access (Tailscale)

OpenClawDeploy enforces a **Zero Trust** network model using [Tailscale](https://tailscale.com/).

### 1. The "Checkpointed" State
Once deployed, the instance enters a hardened "checkpoint" state:
*   **Public Firewall:** BLOCKED. No incoming traffic is allowed on the public IP (except SSH for admin).
*   **Application Binding:** OpenClaw (`clawdbot`) binds **only** to the Tailscale network interface (`tailnet`). It allows no access from localhost or the public internet.
*   **Secure Access:** You must be connected to your Tailscale network (VPN) to access the application.

### 2. Setup Instructions
To enable this secure access, you must provide a Tailscale Auth Key during or after deployment.

1.  Go to the [Tailscale Admin Console > Keys](https://login.tailscale.com/admin/settings/keys).
2.  Generate a new **Auth Key** (Reusable is recommended if you destroy/recreate often).
3.  Add the key to your deployment's variable file:
    ```yaml
    # deployments/<vm-name>/vars.yml
    tailscale_authkey: "tskey-auth-wiCp..."
    ```
4.  Apply the configuration:
    ```bash
    ./scripts/manage_deployment.sh update <vm-name>
    ```

### 3. Accessing the Bot
Once the update completes:
1.  Open the Tailscale app on your device (iOS, Android, macOS, etc.) and verify you are connected.
2.  Find the machine (e.g., `shodan`) in your Tailscale machine list.
3.  Access the OpenClaw gateway using its Tailscale IP:
    ```
    http://100.x.y.z:18789
    ```

## Usage

The script is located at `scripts/manage_deployment.sh`.

### 1. Create a New Deployment

This command provisions a new VM named `my-claw-bot`, generates an inventory file, and runs the Ansible playbook to install OpenClaw.

```bash
# Optional: Set environment variables
export GCP_PROJECT_ID="my-gcp-project-id"
export GCP_ZONE="us-central1-a"

# Run the script
./scripts/manage_deployment.sh create my-claw-bot
```

### 2. Update an Existing Deployment

This command refreshes the SSH configuration (useful if the VM IP changed) and re-runs the Ansible playbook to update configurations or code.

```bash
./scripts/manage_deployment.sh update my-claw-bot
```

## Directory Structure

Deployments are stored in the `deployments/` directory (ignored by git).

```text
deployments/
└── my-claw-bot/
    ├── inventory.ini   # Generated Ansible inventory
    └── vars.yml        # Customizable variables (Tailscale key, etc.)
```

To customize a specific deployment (e.g., to add a Tailscale auth key), edit `deployments/<vm-name>/vars.yml` before running the `create` or `update` command (for `create`, the file is generated after the VM creation step but before the playbook run if you want to intervene, or you can let it run default and then update). *Note: The script currently runs creating and ansible in one go. You can modify `vars.yml` after the first run and run `update` to apply changes.*

## Cost Estimates

The default configuration uses a **t2a-standard-2** instance (ARM) in a US region.

| Resource | Specification | Est. Monthly Cost (USD) |
| :--- | :--- | :--- |
| **Compute** | t2a-standard-2 (2 vCPU, 8GB RAM ARM) | ~$56.00 |
| **Storage** | 50GB Standard Persistent Disk | ~$2.00 |
| **Network** | Egress (varies by usage) | ~$0.00 - $10.00+ |
| **Total** | | **~$58.00 / month** |

*Note: Costs are estimates and vary by region and usage. E2 instances may offer sustained use discounts.*

## Troubleshooting

-   **SSH Connection Failed**: Ensure `gcloud auth login` and `gcloud config set project <id>` are run. The script attempts to update SSH config automatically.
-   **Permission Denied**: Ensure your GCP user has `Compute Instance Admin` privileges.
