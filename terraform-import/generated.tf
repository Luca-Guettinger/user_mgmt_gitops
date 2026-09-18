# Generated with `terraform plan -generate-config-out=generated.tf` and then
# cleaned up: computed subnets, null attributes and the disabled GPU/registry
# plugin blocks are gone (they also conflicted with each other), the pools
# reference the cluster instead of its id, and the repeated values are
# variables. See ../../TERRAFORM-IMPORT.md for the raw output.

resource "digitalocean_kubernetes_cluster" "teko" {
  name    = var.cluster_name
  region  = var.region
  version = var.kubernetes_version

  ha            = false
  surge_upgrade = true
  auto_upgrade  = false

  maintenance_policy {
    day        = "any"
    start_time = "00:00"
  }

  # Default pool - carries the tag terraform:default-node-pool in DO.
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

  # Argo CD and ingress-nginx are pinned to this node.
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
