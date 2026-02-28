#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.yaml"

yaml_get() {
  grep "^${1}:" "$CONFIG" | head -1 | sed 's/^[^:]*:[[:space:]]*//'
}

PROJECT_ID="$(yaml_get project)"
NETWORK="$(yaml_get network)"
SUBNET="$(yaml_get subnet)"
STATE_BUCKET="$(yaml_get state_bucket)"
STATE_PROJECT="$(yaml_get state_project)"
MACHINE_TYPE="$(yaml_get machine_type)"
RESERVATION_PREFIX="$(yaml_get reservation_prefix)"
read -ra ALL_ZONES <<< "$(yaml_get zones)"
DEFAULT_ZONE="${ALL_ZONES[0]}"
DEFAULT_REGION="${DEFAULT_ZONE%-*}"

TF=$(command -v tofu 2>/dev/null || command -v terraform 2>/dev/null || { echo "ERROR: Neither tofu nor terraform found in PATH"; exit 1; })

tf_vars() {
  local team_name="$1"
  local zone="$2"
  local region="${zone%-*}"
  echo "-var=team_name=${team_name}" \
       "-var=zone=${zone}" \
       "-var=region=${region}" \
       "-var=machine_type=${MACHINE_TYPE}" \
       "-var=reservation_prefix=${RESERVATION_PREFIX}"
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  setup                        One-time setup: creates shared VPC, firewall rules, and TF state bucket
  up <team-name> [zone]        Provision a GPU VM for a team (zone defaults to ${DEFAULT_ZONE})
  down <team-name> [zone]      Tear down a team's GPU VM
  list                         List all active team workspaces
  ssh <team-name>              SSH into a team's VM

Zones (from config.yaml):
  ${ALL_ZONES[*]}

Examples:
  $0 setup
  $0 up team-alpha
  $0 up team-alpha us-central1-c
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
    gsutil mb -p "${STATE_PROJECT}" -l "${DEFAULT_REGION}" "gs://${STATE_BUCKET}"
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

  # Create one subnet per region used by the configured zones
  local regions=()
  for z in "${ALL_ZONES[@]}"; do
    regions+=("${z%-*}")
  done
  # Deduplicate
  readarray -t regions < <(printf '%s\n' "${regions[@]}" | sort -u)

  local idx=0
  for region in "${regions[@]}"; do
    local cidr="10.${idx}.0.0/16"
    local subnet_name="${SUBNET}"
    if [ "${#regions[@]}" -gt 1 ]; then
      subnet_name="${SUBNET}-${region}"
    fi

    echo "==> Creating subnet: ${subnet_name} (${region}, ${cidr})"
    if gcloud compute networks subnets describe "${subnet_name}" --region="${region}" --project="${PROJECT_ID}" &>/dev/null; then
      echo "    Subnet already exists, skipping."
    else
      gcloud compute networks subnets create "${subnet_name}" \
        --project="${PROJECT_ID}" \
        --network="${NETWORK}" \
        --region="${region}" \
        --range="${cidr}"
    fi
    idx=$((idx + 1))
  done

  # Create firewall rules
  echo "==> Creating firewall rules..."

  # Remove legacy blanket internal rule if it exists
  if gcloud compute firewall-rules describe hackathon-allow-internal --project="${PROJECT_ID}" &>/dev/null; then
    echo "==> Removing legacy allow-all-internal rule (replaced by per-team rules)..."
    gcloud compute firewall-rules delete hackathon-allow-internal \
      --project="${PROJECT_ID}" --quiet
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
  echo "    Run '$0 up <team-name> [zone]' to provision a team VM."
}

cmd_up() {
  local team_name="$1"
  local zone="${2:-${DEFAULT_ZONE}}"
  local region="${zone%-*}"

  echo "==> Provisioning GPU VM for team: ${team_name} (zone: ${zone})"

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
  ${TF} apply $(tf_vars "${team_name}" "${zone}") -auto-approve

  # Show outputs
  echo ""
  echo "============================================"
  echo "  Team:    ${team_name}"
  echo "  Zone:    ${zone}"
  echo "  IP:      $(${TF} output -raw external_ip)"
  echo "  SSH:     $(${TF} output -raw ssh_command)"
  echo "  Jupyter: $(${TF} output -raw jupyter_url)"
  echo "  Bucket:  $(${TF} output -raw team_bucket)"
  echo "============================================"
  echo ""
}

cmd_down() {
  local team_name="$1"
  local zone="${2:-${DEFAULT_ZONE}}"

  echo "==> Tearing down team: ${team_name}"

  cd "${SCRIPT_DIR}"

  if ! ${TF} workspace list | grep -q "  ${team_name}$\|  ${team_name} $\|\* ${team_name}$"; then
    echo "ERROR: Workspace '${team_name}' not found."
    exit 1
  fi

  ${TF} workspace select "${team_name}"
  ${TF} destroy $(tf_vars "${team_name}" "${zone}") -auto-approve

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
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
      echo "Usage: $0 up <team-name> [zone]"
      exit 1
    fi
    cmd_up "$@"
    ;;
  down)
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
      echo "Usage: $0 down <team-name> [zone]"
      exit 1
    fi
    cmd_down "$@"
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
