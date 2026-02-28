# InstaLILY SF Hackathon — GPU VM Provisioning

Provision A100 80GB GPU VMs for up to 50 hackathon teams in one command. Each team gets a dedicated VM with PyTorch, CUDA, and Jupyter pre-installed.

## What each team gets

- **a2-ultragpu-1g** instance: 12 vCPUs, 170 GB RAM, 1x NVIDIA A100 80GB, 375 GB NVMe SSD
- Static external IP
- Deep Learning VM image (PyTorch + CUDA pre-installed)
- Jupyter notebook on port 8080
- $4,000 project-wide budget with auto-shutdown

## Prerequisites

- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- `tofu` or `terraform` installed
- Access to the `internal-sf-hackathon` GCP project
- Access to the `infra-050524` billing project

## Quick start

```bash
git clone <gist-url> hackathon-gpu && cd hackathon-gpu
chmod +x provision.sh

# One-time setup (creates shared VPC, firewall, TF state bucket)
./provision.sh setup

# Provision a team
./provision.sh up team-alpha
```

## Commands

| Command | Description |
|---|---|
| `./provision.sh setup` | One-time: creates shared VPC, firewall rules, GCS state bucket, runs `terraform init` |
| `./provision.sh up <team>` | Provisions a GPU VM for `<team>`, prints IP and SSH command |
| `./provision.sh down <team>` | Tears down all resources for `<team>` and deletes the workspace |
| `./provision.sh list` | Lists all active team workspaces |
| `./provision.sh ssh <team>` | SSH into a team's VM |

## What happens on `provision.sh up`

1. Creates (or selects) a Terraform workspace named `<team>`
2. Creates a service account with `roles/editor`
3. Reserves a static external IP
4. Provisions an `a2-ultragpu-1g` VM with the Deep Learning VM image
5. Sets up a billing budget ($4k) with email alerts at $500 / $1k / $2k / $3k / $4k
6. Deploys a Cloud Function that auto-stops all VMs if budget is exceeded
7. Prints the IP, SSH command, and Jupyter URL

## SSH access

```bash
# Via provision.sh
./provision.sh ssh team-alpha

# Direct SSH
ssh <ip>

# Via gcloud
gcloud compute ssh hackathon-vm-team-alpha --zone=us-central1-b --project=internal-sf-hackathon
```

## Jupyter access

Open in your browser:

```
http://<ip>:8080
```

The Deep Learning VM image starts Jupyter automatically.

## Budget & alerts

- **Budget**: $4,000 per project (shared across all teams)
- **Email alerts**: Sent to sai@instalily.ai and viraj@instalily.ai at $500, $1k, $2k, $3k, $4k
- **Auto-shutdown**: A Cloud Function monitors the Pub/Sub topic and stops all running VMs when spend reaches the budget
- **Expected cost**: ~$1.36/hr per VM. 50 teams × 8 hours ≈ $544 total

## Troubleshooting

### GPU quota error
```
Quota 'NVIDIA_A100_80GB' exceeded
```
Verify quota: `gcloud compute regions describe us-central1 --project=internal-sf-hackathon | grep -A5 A100`

### Image not found
```
The resource 'projects/deeplearning-platform-release/global/images/family/pytorch-latest-gpu' was not found
```
List available images: `gcloud compute images list --project=deeplearning-platform-release --filter="family:pytorch" --no-standard-images`

### Static IP quota
Default is ~8 per region. Request an increase:
```
gcloud compute project-info describe --project=internal-sf-hackathon | grep -A2 EXTERNAL
```

### Cloud Function deployment fails
Ensure these APIs are enabled:
```
gcloud services enable cloudfunctions.googleapis.com cloudbuild.googleapis.com run.googleapis.com eventarc.googleapis.com --project=internal-sf-hackathon
```

### Terraform state lock
If a previous run was interrupted:
```
tofu force-unlock <lock-id>
```

## Nuclear teardown

After the hackathon, delete the entire project:

```bash
gcloud projects delete internal-sf-hackathon
```

This destroys all VMs, IPs, buckets, and billing configuration in one shot.

## Cost estimate

| Item | Cost |
|---|---|
| a2-ultragpu-1g (on-demand) | ~$1.36/hr |
| 1 team × 8 hours | ~$10.88 |
| 50 teams × 8 hours | ~$544 |
| Static IP (while attached) | Free |
| Cloud Function | Negligible |
