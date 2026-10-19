variable "region" {
  type    = string
  default = "us-west-2"
}

variable "profile" {
  description = "AWS CLI profile for the dev account (null = default credential chain)."
  type        = string
  default     = null
}

variable "owner" {
  type    = string
  default = "longhorn-dev"
}

variable "prefix" {
  description = "Prepended to every AWS resource name (e.g. your handle: jdoe)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.prefix))
    error_message = "prefix must be 2-12 chars: lowercase letters, digits, hyphens; start with a letter (S3/IAM naming rules)."
  }
}

variable "name" {
  type    = string
  default = "longhorn-zarf-airgap-lab"
}

variable "vpc_cidr" {
  description = "CIDR of the lab VPC."
  type        = string
  default     = "10.250.0.0/16"
}

variable "availability_zone" {
  type    = string
  default = null
}

variable "instance_type" {
  description = "V2 data engine pins one CPU core per instance manager; use >= 4 vCPU."
  type        = string
  default     = "m6i.xlarge"
}

variable "root_volume_gb" {
  description = "Holds K3s, the Zarf registry/Gitea PVs (local-path), and package tarballs."
  type        = number
  default     = 80
}

# Sizes must differ: user-data identifies the disks by size.
variable "v1_disk_gb" {
  description = "Formatted ext4 and mounted at /var/lib/longhorn (V1 filesystem disk)."
  type        = number
  default     = 100
}

variable "v2_disk_gb" {
  description = "Left raw and added to Longhorn as a V2 block disk."
  type        = number
  default     = 120
}

variable "zarf_version" {
  type    = string
  default = "v0.88.0"
}

variable "auto_prep" {
  description = "In user-data: zarf init (k3s + registry + gitea), then `lab prep` builds every package while still online."
  type        = bool
  default     = true
}

variable "airgap" {
  description = "false = node has internet (bootstrap/prep). true = cut the cord: no internet route, only SSM + S3 endpoints."
  type        = bool
  default     = false
}
