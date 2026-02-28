# InstaLILY SF Hackathon — GPU VM Provisioning

Provision NVIDIA RTX Pro 6000 GPU VMs for up to 50 hackathon teams in one command. Each team gets a dedicated VM with PyTorch, CUDA, and Jupyter pre-installed.

## What each team gets

- **g4-standard-48** instance: 48 vCPUs, 192 GB RAM, 1x NVIDIA RTX Pro 6000 (96 GB VRAM)
- Static external IP
- Deep Learning VM image (PyTorch 2.7 + CUDA 12.8 pre-installed)
- Jupyter notebook on port 8080
- Per-team GCS bucket for data
- Per-team firewall isolation (teams cannot access each other's VMs)
- SSH access via username/password

## Prerequisites

- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- `tofu` or `terraform` installed
- Access to the `internal-sf-hackathon` GCP project
- Access to the `infra-050524` billing project

## Quick start

```bash
git clone https://github.com/Instalily/hackathon-gpu.git && cd hackathon-gpu
chmod +x provision.sh reserve.sh

# Setup is already done — just provision teams:
./provision.sh up team-alpha
./provision.sh password team-alpha
```

## Commands

| Command | Description |
|---|---|
| `./provision.sh setup` | One-time: creates shared VPC, firewall rules, GCS state bucket, runs `terraform init` |
| `./provision.sh up <team>` | Provisions a GPU VM for `<team>`, prints IP and SSH command |
| `./provision.sh password <team>` | Sets up SSH password auth (creates `hackathon` user with random password) |
| `./provision.sh down <team>` | Tears down all resources for `<team>` and deletes the workspace |
| `./provision.sh list` | Lists all active team workspaces |
| `./provision.sh ssh <team>` | SSH into a team's VM (via gcloud, for operators) |

## Typical workflow

```bash
# 1. Provision the VM
./provision.sh up team-alpha

# 2. Set up SSH password for the team
./provision.sh password team-alpha
# Output:
#   VM:       hackathon-vm-team-alpha
#   IP:       34.x.x.x
#   User:     hackathon
#   Password: a1b2c3d4
#   SSH:      ssh hackathon@34.x.x.x

# 3. Give the team their credentials — they SSH in with:
ssh hackathon@34.x.x.x
# (enter password when prompted)
```

## SSH access

Teams SSH in with the username/password from `./provision.sh password`:

```bash
ssh hackathon@<ip>
# Enter the password when prompted
```

Operators can also use gcloud:
```bash
gcloud compute ssh hackathon-vm-team-alpha --zone=us-central1-b --project=internal-sf-hackathon
```

## Jupyter access

Open in your browser:

```
http://<ip>:8080
```

The Deep Learning VM image starts Jupyter automatically.

## Budget & alerts

- **Budget**: $6,000 per project (shared across all teams)
- **Email alerts**: Sent to sai@instalily.ai and viraj@instalily.ai at $500, $1k, $2k, $4k, $6k
- **Auto-shutdown**: A Cloud Function monitors the Pub/Sub topic and stops all running VMs when spend reaches the budget

## Security

- Service accounts have minimal IAM roles (logging + monitoring only)
- Metadata server is blocked via iptables (prevents `gcloud` commands from inside VMs)
- Per-team firewall rules isolate teams from each other on the network
- Teams can only access their own VM via SSH

## GPU reservations

Reservations are managed separately via `reserve.sh`:

```bash
# Create reservations across all configured zones
./reserve.sh

# List existing reservations
gcloud compute reservations list --project=internal-sf-hackathon --filter='name~hackathon-rtxpro'
```

## Troubleshooting

### GPU quota error
```
Quota 'NVIDIA_RTX_PRO_6000' exceeded
```
Verify quota: `gcloud compute regions describe us-central1 --project=internal-sf-hackathon`

### Reservation not found
Ensure the reservation exists for the target zone:
```bash
gcloud compute reservations list --project=internal-sf-hackathon --filter='name~hackathon-rtxpro'
```

### Static IP quota
Default is ~8 per region. Request an increase:
```bash
gcloud compute project-info describe --project=internal-sf-hackathon | grep -A2 EXTERNAL
```

### Terraform state lock
If a previous run was interrupted:
```bash
tofu force-unlock <lock-id>
```

## Nuclear teardown

After the hackathon, delete the entire project:

```bash
gcloud projects delete internal-sf-hackathon
```

This destroys all VMs, IPs, buckets, and billing configuration in one shot.
