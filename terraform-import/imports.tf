# Aufgabe 3: the running cluster referenced as existing infrastructure.
# `app` is the default node pool (tag terraform:default-node-pool), so it is
# part of the cluster resource; `mon` and `pool` are imported separately.

import {
  to = digitalocean_kubernetes_cluster.teko
  id = "072d9e7a-8946-44c4-8a18-932eac3572fa"
}

import {
  to = digitalocean_kubernetes_node_pool.mon
  id = "6d111222-53bf-4c83-a201-32a0aae168e5"
}

import {
  to = digitalocean_kubernetes_node_pool.pool
  id = "9e27d4e7-1ea0-4c6f-8888-506a569f1a0c"
}
