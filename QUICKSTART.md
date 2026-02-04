# OpenClaw Deploy - Quickstart Guide

Get an OpenClaw instance running on Google Cloud in 5 minutes.

## Prerequisites Checklist

Before you begin, ensure you have:

- [ ] **Google Cloud SDK** installed ([Install Guide](https://cloud.google.com/sdk/docs/install))
- [ ] **Ansible 2.14+** installed (`pip install ansible` or `brew install ansible`)
- [ ] **GCP Project** with billing enabled
- [ ] **Compute Engine API** enabled in your project

Verify your setup:

```bash
# Run the prerequisite checker
./scripts/check-prerequisites.sh
```

## Step 1: Authenticate with Google Cloud

```bash
# Login to Google Cloud
gcloud auth login

# Set your project
gcloud config set project YOUR_PROJECT_ID

# Enable Compute Engine API (if not already enabled)
gcloud services enable compute.googleapis.com
```

## Step 2: Create Your Deployment

```bash
# Basic deployment (uses defaults: us-central1-a, t2a-standard-2, 50GB)
./scripts/manage_deployment.sh create my-bot

# Or with custom options
./scripts/manage_deployment.sh create my-bot \
    --zone us-central1-a \
    --machine-type e2-medium
```

The script will:
1. Create a GCP VM
2. Configure SSH access
3. Run Ansible to install OpenClaw

This takes approximately 5-10 minutes.

## Step 3: Access Your Instance

After deployment completes:

```bash
# SSH into your instance
gcloud compute ssh my-bot --zone us-east5-a

# Switch to the openclaw user
sudo su - openclaw

# Run the onboarding wizard
openclaw onboard --install-daemon
```

## Step 4: Configure Tailscale (Recommended)

Tailscale provides secure remote access without exposing ports.

1. Get an auth key from [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)

2. Add it to your deployment:
   ```bash
   # Edit your deployment variables (filename includes zone and project)
   nano inventory/my-bot.us-central1-a.YOUR_PROJECT.yml

   # Add your key:
   # tailscale_authkey: "tskey-auth-xxxxx"
   ```

3. Apply the configuration:
   ```bash
   ./scripts/manage_deployment.sh update my-bot
   ```

4. Access via Tailscale:
   ```
   http://100.x.y.z:3000  (your Tailscale IP)
   ```

## Common Configurations

### Development Mode

Build OpenClaw from source instead of npm:

```bash
./scripts/manage_deployment.sh create my-bot --install-mode development
```

### Custom Fork/Branch

Edit your instance's `.yml` file in `inventory/`:

```yaml
openclaw_install_mode: "development"
openclaw_repo_url: "https://github.com/YOUR_USERNAME/openclaw.git"
openclaw_repo_branch: "feature-branch"
```

Then update:

```bash
./scripts/manage_deployment.sh update my-bot
```

### Add SSH Keys

Edit your instance's `.yml` file in `inventory/`:

```yaml
openclaw_ssh_keys:
  - "ssh-ed25519 AAAAC3... user@laptop"
```

## Quick Reference

| Command | Description |
|---------|-------------|
| `./scripts/manage_deployment.sh create <name>` | Create new deployment |
| `./scripts/manage_deployment.sh update <name>` | Update existing deployment |
| `./scripts/manage_deployment.sh create <name> --dry-run` | Preview without changes |
| `./scripts/backup_deployment.sh <name>` | Backup deployment data |
| `./scripts/restore_deployment.sh <name> <backup>` | Restore from backup |
| `./scripts/check-prerequisites.sh` | Verify environment setup |

## Troubleshooting

### "Permission denied" during VM creation

Ensure your GCP account has `Compute Instance Admin` role:

```bash
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
    --member="user:your-email@example.com" \
    --role="roles/compute.instanceAdmin.v1"
```

### SSH connection fails

Refresh your SSH configuration:

```bash
gcloud compute config-ssh --project YOUR_PROJECT_ID
```

### Ansible fails with "host unreachable"

Wait a minute for the VM to fully initialize, then retry:

```bash
./scripts/manage_deployment.sh update my-bot
```

### Tailscale not connecting

SSH into the VM and manually authenticate:

```bash
gcloud compute ssh my-bot
sudo tailscale up
```

## Next Steps

- Read the full [README.md](README.md) for detailed documentation
- Configure messaging providers with `openclaw providers login`
- Set up agents with `openclaw agents create`
- Monitor with `openclaw status` and `openclaw logs`
