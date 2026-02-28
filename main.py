"""Cloud Function to auto-shutdown VMs when budget is exceeded."""

import base64
import json
import os

import functions_framework
from googleapiclient import discovery


@functions_framework.cloud_event
def handle_budget_alert(cloud_event):
    """Stop all hackathon VMs when budget threshold is met."""
    data = base64.b64decode(cloud_event.data["message"]["data"]).decode("utf-8")
    notification = json.loads(data)

    cost_amount = notification.get("costAmount", 0)
    budget_amount = notification.get("budgetAmount", 0)

    print(f"Cost: ${cost_amount}, Budget: ${budget_amount}")

    if cost_amount < budget_amount:
        print("Under budget — no action.")
        return

    print("Budget exceeded — stopping all hackathon VMs.")

    project_id = os.environ.get("PROJECT_ID", "internal-sf-hackathon")
    zone = os.environ.get("ZONE", "us-central1-b")

    compute = discovery.build("compute", "v1", cache_discovery=False)

    instances = (
        compute.instances()
        .list(project=project_id, zone=zone, filter='labels.hackathon:*')
        .execute()
    )

    for instance in instances.get("items", []):
        name = instance["name"]
        status = instance["status"]

        if status == "RUNNING":
            print(f"Stopping {name}...")
            compute.instances().stop(
                project=project_id, zone=zone, instance=name
            ).execute()
            print(f"Stopped {name}.")
        else:
            print(f"Skipping {name} (status: {status}).")
