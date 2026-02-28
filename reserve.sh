#!/bin/bash
set -euo pipefail

# Reserve NVIDIA RTX Pro 6000 instances
# All settings are read from config.yaml

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.yaml"

yaml_get() {
  grep "^${1}:" "$CONFIG" | head -1 | sed 's/^[^:]*:[[:space:]]*//'
}

PROJECT="${1:-$(yaml_get project)}"
MACHINE_TYPE="$(yaml_get machine_type)"
ACCELERATOR_TYPE="$(yaml_get accelerator_type)"
RESERVATION_PREFIX="$(yaml_get reservation_prefix)"
VM_COUNT="$(yaml_get vm_count)"
MAX_PARALLEL="$(yaml_get max_parallel)"
read -ra ALL_ZONES <<< "$(yaml_get zones)"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

reservation_name() {
  echo "${RESERVATION_PREFIX}-$(echo "$1" | tr -d '-')"
}

echo "============================================="
echo "RTX Pro 6000 Capacity Reservation"
echo "Project:     ${PROJECT}"
echo "Accelerator: ${ACCELERATOR_TYPE} (built into ${MACHINE_TYPE})"
echo "Machine:     ${MACHINE_TYPE}"
echo "Zones:       ${ALL_ZONES[*]}"
echo "Count/zone:  ${VM_COUNT}"
echo "============================================="
echo ""

# Step 1 — Check for existing reservations
echo "Step 1: Checking for existing reservations..."
EXISTING_ZONES=()
while IFS= read -r zone; do
  [ -n "$zone" ] && EXISTING_ZONES+=("$zone")
done < <(gcloud compute reservations list \
  --project="$PROJECT" \
  --filter="name~^${RESERVATION_PREFIX}" \
  --format="csv[no-heading](zone)" 2>/dev/null | sort -u)
EXISTING_LOOKUP=" ${EXISTING_ZONES[*]+"${EXISTING_ZONES[*]}"} "
echo "  Found ${#EXISTING_ZONES[@]} zone(s) with existing reservations"
echo ""

# Step 2 — Create reservations in parallel
echo "Step 2: Creating reservations..."
echo ""

PIDS=()
for ZONE in "${ALL_ZONES[@]}"; do
  RES_NAME=$(reservation_name "$ZONE")
  OUTFILE="$WORK_DIR/$(echo "$ZONE" | tr -d '-')"

  if echo "$EXISTING_LOOKUP" | grep -q " ${ZONE} "; then
    echo "skipped" > "$OUTFILE"
    continue
  fi

  (
    BOOKED=0
    for TRY_COUNT in $VM_COUNT 20 10 5 1; do
      ERROR=$(gcloud compute reservations create "$RES_NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --vm-count="$TRY_COUNT" \
        --machine-type="$MACHINE_TYPE" \
        --require-specific-reservation \
        --quiet 2>&1)

      if [ $? -eq 0 ]; then
        echo "created:${TRY_COUNT}" > "$OUTFILE"
        BOOKED=1
        break
      elif echo "$ERROR" | grep -q "alreadyExists\|already exists"; then
        echo "skipped" > "$OUTFILE"
        BOOKED=1
        break
      elif echo "$ERROR" | grep -q "ZONE_RESOURCE_POOL_EXHAUSTED\|STOCKOUT\|gpu_availability"; then
        continue
      else
        echo "error: ${ERROR}" > "$OUTFILE"
        BOOKED=1
        break
      fi
    done
    [ "$BOOKED" -eq 0 ] && echo "stockout" > "$OUTFILE"
  ) &
  PIDS+=($!)

  if [ "${#PIDS[@]}" -ge "$MAX_PARALLEL" ]; then
    wait "${PIDS[0]}"
    PIDS=("${PIDS[@]:1}")
  fi
done
wait

# Step 3 — Summary
echo "============================================="
echo "Results"
echo "============================================="
printf "%-12s %-25s %-40s\n" "STATUS" "ZONE" "RESERVATION"
printf "%-12s %-25s %-40s\n" "------------" "-------------------------" "----------------------------------------"

CREATED=0
TOTAL_SLOTS=0
STOCKOUT=0
SKIPPED=0
ERRORS=0

for ZONE in "${ALL_ZONES[@]}"; do
  OUTFILE="$WORK_DIR/$(echo "$ZONE" | tr -d '-')"
  STATUS=$(cat "$OUTFILE" 2>/dev/null || echo "error: no result")
  RES_NAME=$(reservation_name "$ZONE")

  case $STATUS in
    created:*)
      COUNT="${STATUS#created:}"
      printf "  CREATED    %-25s %-40s\n" "$ZONE" "$RES_NAME (${COUNT} slots)"
      CREATED=$((CREATED + 1))
      TOTAL_SLOTS=$((TOTAL_SLOTS + COUNT))
      ;;
    stockout)
      printf "  STOCKOUT   %-25s\n" "$ZONE"
      STOCKOUT=$((STOCKOUT + 1))
      ;;
    skipped)
      printf "  SKIPPED    %-25s %-40s\n" "$ZONE" "(reservation exists)"
      SKIPPED=$((SKIPPED + 1))
      ;;
    error*)
      printf "  ERROR      %-25s\n" "$ZONE"
      echo "${STATUS#error: }" | sed 's/^/     /'
      ERRORS=$((ERRORS + 1))
      ;;
  esac
done

echo ""
echo "============================================="
echo "Summary"
echo "============================================="
echo "  Created:  ${CREATED} reservations (${TOTAL_SLOTS} total slots)"
echo "  Skipped:  ${SKIPPED} (already had reservation)"
echo "  STOCKOUT: ${STOCKOUT} (no capacity)"
echo "  Errors:   ${ERRORS}"
echo ""
if [ "$CREATED" -gt 0 ]; then
  echo "To list reservations:"
  echo "  gcloud compute reservations list --project=${PROJECT} --filter='name~${RESERVATION_PREFIX}'"
  echo ""
  echo "To delete all:"
  echo "  gcloud compute reservations list --project=${PROJECT} --filter='name~${RESERVATION_PREFIX}' --format='csv[no-heading](name,zone)' | while IFS=, read name zone; do"
  echo "    gcloud compute reservations delete \"\$name\" --project=${PROJECT} --zone=\"\$zone\" --quiet &"
  echo "  done"
  echo "  wait"
fi
