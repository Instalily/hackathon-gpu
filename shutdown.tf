# --- Cloud Function source bucket ---

resource "google_storage_bucket" "function_source" {
  name                        = "hackathon-shutdown-fn-${var.team_name}"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = true

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.apis]
}

# --- Zip the Cloud Function source ---

data "archive_file" "shutdown_function" {
  type        = "zip"
  output_path = "${path.module}/.build/shutdown-${var.team_name}.zip"

  source {
    content  = file("${path.module}/main.py")
    filename = "main.py"
  }

  source {
    content  = file("${path.module}/requirements.txt")
    filename = "requirements.txt"
  }
}

resource "google_storage_bucket_object" "function_source" {
  name   = "shutdown-${data.archive_file.shutdown_function.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.shutdown_function.output_path
}

# --- Cloud Function service account ---

resource "google_service_account" "shutdown_fn" {
  account_id   = "shutdown-fn-${var.team_name}"
  display_name = "Shutdown function SA - ${var.team_name}"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "shutdown_fn_compute" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.shutdown_fn.email}"
}

# --- Cloud Function Gen 2 ---

resource "google_cloudfunctions2_function" "shutdown" {
  name     = "hackathon-shutdown-${var.team_name}"
  location = var.region
  project  = var.project_id

  build_config {
    runtime     = "python312"
    entry_point = "handle_budget_alert"

    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  service_config {
    min_instance_count             = 0
    max_instance_count             = 1
    available_memory               = "256M"
    timeout_seconds                = 120
    service_account_email          = google_service_account.shutdown_fn.email
    ingress_settings               = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision = true

    environment_variables = {
      PROJECT_ID = var.project_id
      ZONE       = var.zone
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.budget_alerts.id
    retry_policy   = "RETRY_POLICY_DO_NOT_RETRY"
  }

  depends_on = [google_project_service.apis]
}
