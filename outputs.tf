output "external_ip" {
  description = "External IP address of the team VM"
  value       = google_compute_address.team.address
}

output "vm_name" {
  description = "Name of the team VM"
  value       = google_compute_instance.team.name
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "ssh ${google_compute_address.team.address}"
}

output "gcloud_ssh_command" {
  description = "gcloud SSH command to connect to the VM"
  value       = "gcloud compute ssh ${google_compute_instance.team.name} --zone=${var.zone} --project=${var.project_id}"
}

output "jupyter_url" {
  description = "Jupyter notebook URL"
  value       = "http://${google_compute_address.team.address}:8080"
}

output "team_bucket" {
  description = "GCS bucket for team data"
  value       = "gs://${google_storage_bucket.team_data.name}"
}
