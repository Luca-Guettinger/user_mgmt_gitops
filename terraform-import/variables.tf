# Defaults are the live values, so `plan` needs no .tfvars.
# The DO token is not a variable - it comes from DIGITALOCEAN_TOKEN.

variable "cluster_name" {
  type    = string
  default = "teko-tf"
}

variable "region" {
  type    = string
  default = "fra1"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36.3-do.5"
}

variable "node_size" {
  description = "One size for all three pools."
  type        = string
  default     = "s-2vcpu-4gb"
}
