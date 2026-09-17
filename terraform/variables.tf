# New account, new cluster - no live state to match, so these are just
# starting points. No secrets here: the token stays in the environment (see
# provider.tf), never in a variable or .tfvars.

variable "cluster_name" {
  type    = string
  default = "teko-tf"
}

variable "region" {
  type    = string
  default = "fra1"
}

variable "kubernetes_version" {
  description = "\"latest\" at create time"
  type        = string
  default     = "latest"
}

variable "node_size" {
  description = "One size for all three pools, so app/mon/pool run identical nodes."
  type        = string
  default     = "s-2vcpu-4gb"
}
