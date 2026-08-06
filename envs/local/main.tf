terraform {
  required_providers {
    null = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

# NodePort usado para publicar o Prometheus no host via k3d (deve bater com
# o mesmo valor em platform/local), permitindo que consumidores fora do
# cluster (ex.: workerless-api) alcancem OBSERVABILITY_PROMETHEUS_URL.
variable "prometheus_node_port" {
  type    = number
  default = 30090
}

resource "null_resource" "k3d_cluster" {
  triggers = {
    command = "k3d cluster create local-rock --api-port 6550 --servers 1 --agents 1 --port \"${var.prometheus_node_port}:${var.prometheus_node_port}@server:0\" --wait"
  }

  provisioner "local-exec" {
    command = self.triggers.command
  }
  provisioner "local-exec" {
    when       = destroy
    command    = "k3d cluster delete local-rock"
    on_failure = continue
  }
}
