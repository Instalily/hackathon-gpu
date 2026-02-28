# --- Service account ---

resource "google_service_account" "team" {
  account_id   = "hackathon-${var.team_name}"
  display_name = "Hackathon SA - ${var.team_name}"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

locals {
  team_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
  reservation_name = "${var.reservation_prefix}-${replace(var.zone, "-", "")}"
}

resource "google_project_iam_member" "team_roles" {
  for_each = toset(local.team_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.team.email}"
}

# --- Per-team GCS bucket ---

resource "google_storage_bucket" "team_data" {
  name                        = "${var.project_id}-${var.team_name}"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = true

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "team_data_admin" {
  bucket = google_storage_bucket.team_data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.team.email}"
}

# --- Per-team firewall rule (isolates teams from each other) ---

resource "google_compute_firewall" "team_internal" {
  name    = "hackathon-internal-${var.team_name}"
  network = data.google_compute_network.hackathon.self_link
  project = var.project_id

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_tags = [var.team_name]
  target_tags = [var.team_name]

  depends_on = [google_project_service.apis]
}

# --- Static external IP ---

resource "google_compute_address" "team" {
  name    = "hackathon-ip-${var.team_name}"
  region  = var.region
  project = var.project_id

  depends_on = [google_project_service.apis]
}

# --- GPU VM ---

resource "google_compute_instance" "team" {
  name         = "hackathon-vm-${var.team_name}"
  machine_type = var.machine_type
  zone         = var.zone
  project      = var.project_id

  boot_disk {
    initialize_params {
      image = "projects/deeplearning-platform-release/global/images/family/pytorch-2-7-cu128-ubuntu-2204-nvidia-570"
      size  = 200
      type  = "pd-ssd"
    }
  }

  network_interface {
    network    = data.google_compute_network.hackathon.self_link
    subnetwork = data.google_compute_subnetwork.hackathon.self_link

    access_config {
      nat_ip = google_compute_address.team.address
    }
  }

  guest_accelerator {
    type  = "nvidia-rtx-pro-6000"
    count = 1
  }

  scheduling {
    on_host_maintenance = "TERMINATE"
    automatic_restart   = true
  }

  reservation_affinity {
    type = "SPECIFIC_RESERVATION"
    specific_reservation {
      key    = "compute.googleapis.com/reservation-name"
      values = [local.reservation_name]
    }
  }

  service_account {
    email  = google_service_account.team.email
    scopes = [
      "https://www.googleapis.com/auth/devstorage.read_write",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  metadata = {
    install-nvidia-driver = "True"
    startup-script        = "iptables -A OUTPUT -d 169.254.169.254 -m owner ! --uid-owner root -j REJECT"
  }

  tags = ["hackathon", var.team_name]

  labels = {
    team      = var.team_name
    hackathon = "sf-2026"
    managed   = "terraform"
  }

  depends_on = [google_project_service.apis]
}
