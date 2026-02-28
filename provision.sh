#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="internal-sf-hackathon"
REGION="us-central1"
ZONE="us-central1-b"
NETWORK="hackathon-vpc"
SUBNET="hackathon-subnet"
STATE_BUCKET="hackathon-gpu-tf-state"
STATE_PROJECT="infra-050524"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Use tofu if available, otherwise terraform
TF=$(command -v tofu 2>/dev/null || command -v terraform 2>/dev/null || { echo "ERROR: Neither tofu nor terraform found in PATH"; exit 1; })

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  setup             One-time setup: creates shared VPC, firewall rules, and TF state bucket
  up <team-name>    Provision a GPU VM for a team
  down <team-name>  Tear down a team's GPU VM
  list              List all active team workspaces
  ssh <team-name>   SSH into a team's VM

Examples:
  $0 setup
  $0 up team-alpha
  $0 ssh team-alpha
  $0 down team-alpha
  $0 list
EOF
  exit 1
}

cmd_setup() {
  echo "==> Creating shared infrastructure..."

  # Create GCS bucket for TF state
  echo "==> Creating TF state bucket: gs://${STATE_BUCKET}"
  if gsutil ls -b "gs://${STATE_BUCKET}" &>/dev/null; then
    echo "    Bucket already exists, skipping."
  else
    gsutil mb -p "${STATE_PROJECT}" -l "${REGION}" "gs://${STATE_BUCKET}"
    gsutil versioning set on "gs://${STATE_BUCKET}"
  fi

  # Create VPC network
  echo "==> Creating VPC network: ${NETWORK}"
  if gcloud compute networks describe "${NETWORK}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    Network already exists, skipping."
  else
    gcloud compute networks create "${NETWORK}" \
      --project="${PROJECT_ID}" \
      --subnet-mode=custom
  fi

  # Create subnet
  echo "==> Creating subnet: ${SUBNET}"
  if gcloud compute networks subnets describe "${SUBNET}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "    Subnet already exists, skipping."
  else
    gcloud compute networks subnets create "${SUBNET}" \
      --project="${PROJECT_ID}" \
      --network="${NETWORK}" \
      --region="${REGION}" \
      --range="10.0.0.0/16"
  fi

  # Create firewall rules
  echo "==> Creating firewall rules..."

  # Allow all internal traffic
  if gcloud compute firewall-rules describe hackathon-allow-internal --project="${PROJECT_ID}" &>/dev/null; then
    echo "    hackathon-allow-internal already exists, skipping."
  else
    gcloud compute firewall-rules create hackathon-allow-internal \
      --project="${PROJECT_ID}" \
      --network="${NETWORK}" \
      --allow=tcp,udp,icmp \
      --source-ranges="10.0.0.0/16"
  fi

  # Allow SSH from anywhere
  if gcloud compute firewall-rules describe hackathon-allow-ssh --project="${PROJECT_ID}" &>/dev/null; then
    echo "    hackathon-allow-ssh already exists, skipping."
  else
    gcloud compute firewall-rules create hackathon-allow-ssh \
      --project="${PROJECT_ID}" \
      --network="${NETWORK}" \
      --allow=tcp:22 \
      --source-ranges="0.0.0.0/0" \
      --target-tags="hackathon"
  fi

  # Allow Jupyter (8080) from anywhere
  if gcloud compute firewall-rules describe hackathon-allow-jupyter --project="${PROJECT_ID}" &>/dev/null; then
    echo "    hackathon-allow-jupyter already exists, skipping."
  else
    gcloud compute firewall-rules create hackathon-allow-jupyter \
      --project="${PROJECT_ID}" \
      --network="${NETWORK}" \
      --allow=tcp:8080 \
      --source-ranges="0.0.0.0/0" \
      --target-tags="hackathon"
  fi

  # Initialize Terraform
  echo "==> Initializing Terraform..."
  cd "${SCRIPT_DIR}"
  ${TF} init

  echo ""
  echo "==> Setup complete! Shared infrastructure is ready."
  echo "    Run '$0 up <team-name>' to provision a team VM."
}

cmd_up() {
  local team_name="$1"

  echo "==> Provisioning GPU VM for team: ${team_name}"

  cd "${SCRIPT_DIR}"

  # Create or select workspace
  if ${TF} workspace list | grep -q "  ${team_name}$\|  ${team_name} $\|\* ${team_name}$"; then
    echo "==> Selecting existing workspace: ${team_name}"
    ${TF} workspace select "${team_name}"
  else
    echo "==> Creating workspace: ${team_name}"
    ${TF} workspace new "${team_name}"
  fi

  # Apply
  ${TF} apply -var="team_name=${team_name}" -auto-approve

  # Show outputs
  echo ""
  echo "============================================"
  echo "  Team: ${team_name}"
  echo "  IP:   $(${TF} output -raw external_ip)"
  echo "  SSH:  $(${TF} output -raw ssh_command)"
  echo "  Jupyter: $(${TF} output -raw jupyter_url)"
  echo "============================================"
  echo ""
}

cmd_down() {
  local team_name="$1"

  echo "==> Tearing down team: ${team_name}"

  cd "${SCRIPT_DIR}"

  if ! ${TF} workspace list | grep -q "  ${team_name}$\|  ${team_name} $\|\* ${team_name}$"; then
    echo "ERROR: Workspace '${team_name}' not found."
    exit 1
  fi

  ${TF} workspace select "${team_name}"
  ${TF} destroy -var="team_name=${team_name}" -auto-approve

  # Switch back to default and delete the workspace
  ${TF} workspace select default
  ${TF} workspace delete "${team_name}"

  echo "==> Team ${team_name} torn down."
}

cmd_list() {
  echo "==> Active team workspaces:"
  cd "${SCRIPT_DIR}"
  ${TF} workspace list | grep -v "^  default$\|^\* default$" | sed 's/^[* ]*/  /' | grep -v "^$" || echo "  (none)"
}

cmd_ssh() {
  local team_name="$1"

  cd "${SCRIPT_DIR}"

  if ! ${TF} workspace list | grep -q "  ${team_name}$\|  ${team_name} $\|\* ${team_name}$"; then
    echo "ERROR: Workspace '${team_name}' not found."
    exit 1
  fi

  ${TF} workspace select "${team_name}"
  local ip
  ip=$(${TF} output -raw external_ip)

  echo "==> Connecting to team ${team_name} at ${ip}..."
  ssh -o StrictHostKeyChecking=no "${ip}"
}

# --- Main ---

if [ $# -lt 1 ]; then
  usage
fi

COMMAND="$1"
shift

case "${COMMAND}" in
  setup)
    cmd_setup
    ;;
  up)
    if [ $# -ne 1 ]; then
      echo "Usage: $0 up <team-name>"
      exit 1
    fi
    cmd_up "$1"
    ;;
  down)
    if [ $# -ne 1 ]; then
      echo "Usage: $0 down <team-name>"
      exit 1
    fi
    cmd_down "$1"
    ;;
  list)
    cmd_list
    ;;
  ssh)
    if [ $# -ne 1 ]; then
      echo "Usage: $0 ssh <team-name>"
      exit 1
    fi
    cmd_ssh "$1"
    ;;
  *)
    echo "Unknown command: ${COMMAND}"
    usage
    ;;
esac
