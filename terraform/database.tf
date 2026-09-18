# Aufgabe 4: managed PostgreSQL instead of the Postgres pod in the cluster.
#
# One DO-managed server with two databases, one per environment, each with
# its own user, so staging cannot read prod data. It sits in the cluster's
# VPC and its firewall only lets the Kubernetes cluster in.
#
# The credentials go into a hand-made Kubernetes Secret per environment
# (see ../../SECRETS-RUNBOOK.md), never into Git.

resource "digitalocean_database_cluster" "pg" {
  name                 = "user-mgmt-pg"
  engine               = "pg"
  version              = "16"
  size                 = var.db_size
  region               = var.region
  node_count           = 1
  private_network_uuid = digitalocean_kubernetes_cluster.teko.vpc_uuid
}

resource "digitalocean_database_firewall" "pg" {
  cluster_id = digitalocean_database_cluster.pg.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.teko.id
  }
}

resource "digitalocean_database_db" "env" {
  for_each   = toset(var.environments)
  cluster_id = digitalocean_database_cluster.pg.id
  name       = "user_mgmt_${each.key}"
}

resource "digitalocean_database_user" "env" {
  for_each   = toset(var.environments)
  cluster_id = digitalocean_database_cluster.pg.id
  name       = "user_mgmt_${each.key}"

  # The API returns an empty settings block, which plan would otherwise
  # "remove" on every run.
  lifecycle {
    ignore_changes = [settings]
  }
}

# Everything the Secrets need except the passwords, which stay sensitive:
#   terraform output -json db_passwords
output "db_private_host" {
  value = digitalocean_database_cluster.pg.private_host
}

output "db_port" {
  value = digitalocean_database_cluster.pg.port
}

output "db_passwords" {
  value     = { for env, user in digitalocean_database_user.env : env => user.password }
  sensitive = true
}
