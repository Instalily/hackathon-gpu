# --- Service account ---

resource "google_service_account" "team" {
  account_id   = "hackathon-${var.team_name}"
  display_name = "Hackathon SA - ${var.team_name}"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "team_editor" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.team.email}"
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

  scheduling {
    on_host_maintenance = "TERMINATE"
    automatic_restart   = true
  }

  service_account {
    email  = google_service_account.team.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    install-nvidia-driver = "True"
    proxy-mode            = "project_editors"
  }

  tags = ["hackathon", var.team_name]

  labels = {
    team      = var.team_name
    hackathon = "sf-2026"
    managed   = "terraform"
  }

  depends_on = [google_project_service.apis]
}
