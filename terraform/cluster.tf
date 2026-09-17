# Creates a fresh cluster on the new account - nothing here is imported.
# No vpc_uuid: left unset so DO drops the cluster into the account's
# default VPC, same as the doctl example in ../../SETUP-FROM-SCRATCH.md.
#
# ha = false: DO may still force this on for newer Kubernetes versions (see
# ../../TERRAFORM-PLAN.md, "ha" row) - if `plan` shows it flipping to true
# on its own after create, that's DO's default, not something to fight here.
#
# Three pools (app/mon/pool) of one node each, matching the existing
# node-pinning setup (../../CLAUDE.md trap 9): Argo CD/ingress-nginx get
# pinned to `mon`/`app` by live kubectl patches after the cluster exists.

resource "digitalocean_kubernetes_cluster" "teko" {
  name    = var.cluster_name
  region  = var.region
  version = var.kubernetes_version

  ha            = false
  surge_upgrade = true

  maintenance_policy {
    start_time = "00:00"
    day        = "any"
  }

  node_pool {
    name       = "app"
    size       = var.node_size
    node_count = 1
  }
}

resource "digitalocean_kubernetes_node_pool" "mon" {
  cluster_id = digitalocean_kubernetes_cluster.teko.id
  name       = "mon"
  size       = var.node_size
  node_count = 1

  labels = {
    workload = "monitoring"
  }
}

resource "digitalocean_kubernetes_node_pool" "pool" {
  cluster_id = digitalocean_kubernetes_cluster.teko.id
  name       = "pool"
  size       = var.node_size
  node_count = 1
}
