variable "project" {
  description = "The Google Cloud project ID"
  type        = string
  default     = "cka-exam-423318"
}

variable "region" {
  description = "The Google Cloud region"
  type        = string
  default     = "us-west1"
}

variable "zone" {
  description = "The Google Cloud zone"
  type        = string
  default     = "us-west1-a"
}

variable "credentials_file" {
  description = "Path to the Google Cloud credentials JSON file"
  type        = string
  default     = "/mnt/c/Users/glyph/Downloads/cka-exam-423318-577e8a6f29ea.json"
}

variable "machine_type" {
  description = "The machine type to use for instances"
  type        = string
  default     = "e2-medium"
}

variable "image" {
  description = "The image to use for instances"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2004-lts"
}

variable "username" {
  description = "The username for SSH access"
  type        = string
  default     = "ubuntu"
}

variable "pod_network_cidr" {
  description = "CIDR for the pod network"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_account_email" {
  description = "The service account email"
  type        = string
  default     = "cka-svc-acct@cka-exam-423318.iam.gserviceaccount.com"
}

