# Defaults are the live values of the running cluster. No secrets here: the
# token stays in the environment (see provider.tf), never in a variable.

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
  description = "One size for all three pools, so app/mon/pool run identical nodes."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "db_size" {
  description = "Smallest managed Postgres: 1 vCPU, 1 GB RAM, ~15 USD/month."
  type        = string
  default     = "db-s-1vcpu-1gb"
}

variable "environments" {
  description = "One database and one user per environment on the managed server."
  type        = list(string)
  default     = ["prod", "staging"]
}
