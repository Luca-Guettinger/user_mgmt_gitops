# Aufgabe 6: managed MySQL for the module_service.
#
# A DigitalOcean database cluster serves exactly one engine, so MySQL cannot
# share the Postgres server from database.tf - this is a second cluster. Same
# shape as that one: inside the cluster's VPC, firewalled to the Kubernetes
# cluster, credentials into a hand-made Secret (../../SECRETS-RUNBOOK.md).
#
# One database and one user, not a set per environment: the module_service
# runs in production only.

resource "digitalocean_database_cluster" "mysql" {
  name                 = "module-service-mysql"
  engine               = "mysql"
  version              = "8.4"
  size                 = var.db_size
  region               = var.region
  node_count           = 1
  private_network_uuid = digitalocean_kubernetes_cluster.teko.vpc_uuid
}

resource "digitalocean_database_firewall" "mysql" {
  cluster_id = digitalocean_database_cluster.mysql.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.teko.id
  }
}

resource "digitalocean_database_db" "module" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = "module_prod"
}

resource "digitalocean_database_user" "module" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = "module_prod"

  # The service connects over the private VPC address without TLS, and
  # mysql_native_password is the plugin PyMySQL handles there without an
  # RSA key exchange.
  mysql_auth_plugin = "mysql_native_password"

  # Same as the Postgres users: the API returns an empty settings block that
  # plan would otherwise "remove" on every run.
  lifecycle {
    ignore_changes = [settings]
  }
}

# The Secret is built by hand from these:
#   terraform output -raw mysql_password
output "mysql_private_host" {
  value = digitalocean_database_cluster.mysql.private_host
}

output "mysql_port" {
  value = digitalocean_database_cluster.mysql.port
}

output "mysql_password" {
  value     = digitalocean_database_user.module.password
  sensitive = true
}
