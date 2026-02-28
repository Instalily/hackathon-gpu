# --- Notification channels ---

resource "google_monitoring_notification_channel" "budget_email" {
  for_each = toset(var.alert_emails)

  provider     = google-beta
  project      = var.project_id
  display_name = "Hackathon budget alerts - ${each.value}"
  type         = "email"

  labels = {
    email_address = each.value
  }

  depends_on = [google_project_service.apis]
}

# --- Pub/Sub topic for budget alerts ---

resource "google_pubsub_topic" "budget_alerts" {
  name    = "hackathon-budget-alerts-${var.team_name}"
  project = var.project_id

  depends_on = [google_project_service.apis]
}

# --- Billing budget ---

resource "google_billing_budget" "team" {
  provider        = google-beta
  billing_account = var.billing_account
  display_name    = "Hackathon budget - ${var.team_name}"

  budget_filter {
    projects = ["projects/${data.google_project.current.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount)
    }
  }

  # $500 threshold (12.5%)
  threshold_rules {
    threshold_percent = 0.125
    spend_basis       = "CURRENT_SPEND"
  }

  # $1,000 threshold (25%)
  threshold_rules {
    threshold_percent = 0.25
    spend_basis       = "CURRENT_SPEND"
  }

  # $2,000 threshold (50%)
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  # $3,000 threshold (75%)
  threshold_rules {
    threshold_percent = 0.75
    spend_basis       = "CURRENT_SPEND"
  }

  # $4,000 threshold (100%)
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [
      for ch in google_monitoring_notification_channel.budget_email : ch.id
    ]
    pubsub_topic   = google_pubsub_topic.budget_alerts.id
    schema_version = "1.0"
  }
}

# --- Data source for project number ---

data "google_project" "current" {
  project_id = var.project_id
}
