variable "team_name" {
  description = "Team name (lowercase alphanumeric + hyphens)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.team_name))
    error_message = "Team name must be lowercase alphanumeric + hyphens, 3-30 chars."
  }
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "internal-sf-hackathon"
}

variable "org_id" {
  description = "GCP organization ID"
  type        = string
}

variable "billing_account" {
  description = "GCP billing account ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-b"
}

variable "machine_type" {
  description = "Machine type for GPU VM"
  type        = string
  default     = "a2-highgpu-1g"
}

variable "budget_amount" {
  description = "Budget amount in USD"
  type        = number
  default     = 6000
}

variable "alert_emails" {
  description = "Email addresses for budget alerts"
  type        = list(string)
  default     = ["sai@instalily.ai", "viraj@instalily.ai"]
}

variable "network_name" {
  description = "Name of the shared VPC network"
  type        = string
  default     = "hackathon-vpc"
}

variable "subnet_name" {
  description = "Name of the shared subnet"
  type        = string
  default     = "hackathon-subnet"
}
