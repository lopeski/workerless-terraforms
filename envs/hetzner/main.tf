terraform {
  backend "s3" {}

  required_providers {
    hcloud   = { source = "hetznercloud/hcloud", version = "~> 1.45" }
    null     = { source = "hashicorp/null", version = "~> 3.2" }
    external = { source = "hashicorp/external", version = "~> 2.3" }
    random   = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "hcloud_token" {
  description = "Token de API do Hetzner Cloud"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path para a chave SSH pública (default ~/.ssh/id_rsa.pub)"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "Path para a chave SSH privada usada nas conexões remotas"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "k3s_version" {
  type    = string
  default = "v1.30.5+k3s1"
}

variable "server_type" {
  description = "Tipo das 3 VMs k3s server. Default economico; aumente apenas se os workloads exigirem."
  type        = string
  default     = "cax11"
}

variable "worker_count" {
  description = "Quantidade de agents k3s dedicados a workloads de tenant."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1
    error_message = "worker_count must be at least 1 so tenant workloads do not run on control-plane nodes."
  }
}

variable "worker_server_type" {
  description = "Tipo das VMs k3s agent dedicadas a workloads."
  type        = string
  default     = "cax21"
}

variable "server_location" {
  type    = string
  default = "ash"
}

variable "network_zone" {
  description = "Hetzner network zone correspondente à location (ash → us-east, fsn1/nbg1/hel1 → eu-central, sin → ap-southeast)"
  type        = string
  default     = "us-east"
}

variable "admin_cidrs" {
  description = "CIDRs administrativos permitidos para SSH (22) e API Kubernetes (6443). Use CIDRs reais; nunca 0.0.0.0/0 em produção."
  type        = list(string)

  validation {
    condition = length(var.admin_cidrs) > 0 && alltrue([
      for cidr in var.admin_cidrs : cidr != "0.0.0.0/0" && cidr != "::/0"
    ])
    error_message = "admin_cidrs is required and must not include 0.0.0.0/0 or ::/0."
  }
}

variable "control_plane_cidrs" {
  description = "CIDRs do host que roda o control-plane da PaaS (ex.: workerless-api), autorizado a acessar a API Kubernetes (6443) e o Prometheus (prometheus_node_port). Separado de admin_cidrs para não conceder SSH a esse host."
  type        = list(string)

  validation {
    condition = length(var.control_plane_cidrs) > 0 && alltrue([
      for cidr in var.control_plane_cidrs : cidr != "0.0.0.0/0" && cidr != "::/0"
    ])
    error_message = "control_plane_cidrs is required and must not include 0.0.0.0/0 or ::/0."
  }
}

variable "prometheus_node_port" {
  description = "NodePort usado para expor o Prometheus ao control-plane externo (deve bater com o mesmo valor em platform/hetzner)."
  type        = number
  default     = 30090
}

variable "registry_enabled" {
  type    = bool
  default = true
}

variable "ingress_http_node_port" {
  type    = number
  default = 30080
}

variable "ingress_https_node_port" {
  type    = number
  default = 30443
}

variable "etcd_snapshot_schedule_cron" {
  description = "Cron usado pelo k3s para snapshots automaticos do embedded etcd."
  type        = string
  default     = "0 */6 * * *"
}

variable "etcd_snapshot_retention" {
  description = "Quantidade de snapshots automaticos do etcd mantidos por cada server k3s."
  type        = number
  default     = 14

  validation {
    condition     = var.etcd_snapshot_retention >= 2
    error_message = "etcd_snapshot_retention must be at least 2."
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# Token compartilhado entre os servers para join no embedded etcd
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "hcloud_ssh_key" "default" {
  name       = "workerless-terraforms"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# Rede privada para tráfego inter-nó (etcd 2379-2380, kubelet 10250, flannel
# VXLAN 8472). Mantém esse tráfego fora da internet pública.
resource "hcloud_network" "private" {
  name     = "k3s-private"
  ip_range = "10.10.0.0/16"
}

resource "hcloud_network_subnet" "private" {
  network_id   = hcloud_network.private.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = "10.10.1.0/24"
}

resource "hcloud_firewall" "k3s" {
  name = "k3s-cluster"

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = tostring(var.ingress_http_node_port)
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Public HTTP forwarded by the registry load balancer"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = tostring(var.ingress_https_node_port)
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Public HTTPS forwarded by the registry load balancer"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_cidrs
    description = "SSH"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = var.admin_cidrs
    description = "Kubernetes API"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = var.control_plane_cidrs
    description = "Kubernetes API - PaaS control-plane host (sem SSH)"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = tostring(var.prometheus_node_port)
    source_ips  = var.control_plane_cidrs
    description = "Prometheus NodePort - PaaS control-plane host"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = ["10.10.1.0/24"]
    description = "k3s API/join over private network"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "9345"
    source_ips  = ["10.10.1.0/24"]
    description = "k3s supervisor over private network"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "2379-2380"
    source_ips  = ["10.10.1.0/24"]
    description = "embedded etcd peer/client over private network"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "10250"
    source_ips  = ["10.10.1.0/24"]
    description = "kubelet over private network"
  }

  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "8472"
    source_ips  = ["10.10.1.0/24"]
    description = "flannel VXLAN over private network"
  }
}

resource "hcloud_load_balancer" "registry" {
  count              = var.registry_enabled ? 1 : 0
  name               = "workerless-registry"
  load_balancer_type = "lb11"
  location           = var.server_location
}

resource "hcloud_load_balancer_target" "registry_servers" {
  for_each         = var.registry_enabled ? merge({ bootstrap = hcloud_server.bootstrap }, hcloud_server.joiners) : {}
  type             = "server"
  load_balancer_id = hcloud_load_balancer.registry[0].id
  server_id        = each.value.id
}

resource "hcloud_load_balancer_service" "registry_http" {
  count            = var.registry_enabled ? 1 : 0
  load_balancer_id = hcloud_load_balancer.registry[0].id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = var.ingress_http_node_port
  health_check {
    protocol = "tcp"
    port     = var.ingress_http_node_port
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "registry_https" {
  count            = var.registry_enabled ? 1 : 0
  load_balancer_id = hcloud_load_balancer.registry[0].id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = var.ingress_https_node_port
  health_check {
    protocol = "tcp"
    port     = var.ingress_https_node_port
    interval = 15
    timeout  = 10
    retries  = 3
  }
}

# HA minimo: 3 k3s servers com embedded etcd e workers separados para tenants.
# IPs privados deterministicos deixam os joiners apontarem para o bootstrap
# dentro do proprio user_data, antes do bootstrap existir.
locals {
  bootstrap_priv_ip = "10.10.1.2"
  joiner_priv_ips = {
    "1" = "10.10.1.3"
    "2" = "10.10.1.4"
  }
  worker_priv_ips = {
    for index in range(var.worker_count) : tostring(index) => cidrhost("10.10.1.0/24", index + 20)
  }
  server_priv_ips       = concat([local.bootstrap_priv_ip], values(local.joiner_priv_ips))
  expected_server_count = length(local.server_priv_ips)
  expected_worker_count = length(local.worker_priv_ips)
  expected_node_count   = local.expected_server_count + local.expected_worker_count
}

resource "hcloud_server" "bootstrap" {
  name         = "k3s-hetzner-rock-0"
  image        = "ubuntu-22.04"
  server_type  = var.server_type
  location     = var.server_location
  ssh_keys     = [hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.k3s.id]

  network {
    network_id = hcloud_network.private.id
    ip         = local.bootstrap_priv_ip
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    until ip -4 addr show enp7s0 2>/dev/null | grep -q "${local.bootstrap_priv_ip}"; do sleep 2; done
    PUBLIC_IP=$(curl -s ifconfig.me)
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION=${var.k3s_version} \
      K3S_TOKEN='${random_password.k3s_token.result}' \
      sh -s - server \
        --cluster-init \
        --tls-san $PUBLIC_IP \
        --node-ip ${local.bootstrap_priv_ip} \
        --advertise-address ${local.bootstrap_priv_ip} \
        --flannel-iface enp7s0 \
        --node-taint CriticalAddonsOnly=true:NoSchedule \
        --etcd-snapshot-schedule-cron '${var.etcd_snapshot_schedule_cron}' \
        --etcd-snapshot-retention ${var.etcd_snapshot_retention} \
        --etcd-snapshot-dir /var/lib/rancher/k3s/server/db/snapshots
  EOF

  depends_on = [
    hcloud_network_subnet.private,
  ]
}

resource "null_resource" "wait_for_bootstrap" {
  depends_on = [hcloud_server.bootstrap]

  triggers = {
    server_id = hcloud_server.bootstrap.id
  }

  connection {
    type        = "ssh"
    user        = "root"
    host        = hcloud_server.bootstrap.ipv4_address
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "until [ -f /etc/rancher/k3s/k3s.yaml ] && systemctl is-active --quiet k3s; do echo 'waiting for k3s bootstrap...'; sleep 5; done",
      "until kubectl get nodes 2>/dev/null | grep -q ' Ready '; do echo 'waiting for bootstrap Ready...'; sleep 5; done",
    ]
  }
}

resource "hcloud_server" "joiners" {
  for_each = local.joiner_priv_ips

  name         = "k3s-hetzner-rock-${each.key}"
  image        = "ubuntu-22.04"
  server_type  = var.server_type
  location     = var.server_location
  ssh_keys     = [hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.k3s.id]

  network {
    network_id = hcloud_network.private.id
    ip         = each.value
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    until ip -4 addr show enp7s0 2>/dev/null | grep -q "${each.value}"; do sleep 2; done
    PUBLIC_IP=$(curl -s ifconfig.me)
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION=${var.k3s_version} \
      K3S_TOKEN='${random_password.k3s_token.result}' \
      sh -s - server \
        --server https://${local.bootstrap_priv_ip}:6443 \
        --tls-san $PUBLIC_IP \
        --node-ip ${each.value} \
        --advertise-address ${each.value} \
        --flannel-iface enp7s0 \
        --node-taint CriticalAddonsOnly=true:NoSchedule \
        --etcd-snapshot-schedule-cron '${var.etcd_snapshot_schedule_cron}' \
        --etcd-snapshot-retention ${var.etcd_snapshot_retention} \
        --etcd-snapshot-dir /var/lib/rancher/k3s/server/db/snapshots
  EOF

  depends_on = [
    hcloud_network_subnet.private,
    null_resource.wait_for_bootstrap,
  ]
}

resource "hcloud_server" "workers" {
  for_each = local.worker_priv_ips

  name         = "k3s-hetzner-worker-${each.key}"
  image        = "ubuntu-22.04"
  server_type  = var.worker_server_type
  location     = var.server_location
  ssh_keys     = [hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.k3s.id]

  network {
    network_id = hcloud_network.private.id
    ip         = each.value
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    until ip -4 addr show enp7s0 2>/dev/null | grep -q "${each.value}"; do sleep 2; done
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION=${var.k3s_version} \
      K3S_TOKEN='${random_password.k3s_token.result}' \
      sh -s - agent \
        --server https://${local.bootstrap_priv_ip}:6443 \
        --node-ip ${each.value} \
        --flannel-iface enp7s0 \
        --node-label workerless.io/node-pool=workers
  EOF

  depends_on = [
    hcloud_network_subnet.private,
    null_resource.wait_for_cluster,
  ]
}

resource "null_resource" "wait_for_workers" {
  depends_on = [hcloud_server.workers]

  triggers = {
    bootstrap_id        = hcloud_server.bootstrap.id
    expected_node_count = local.expected_node_count
    worker_ids          = join(",", [for s in hcloud_server.workers : s.id])
  }

  connection {
    type        = "ssh"
    user        = "root"
    host        = hcloud_server.bootstrap.ipv4_address
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "until [ $(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ') -ge ${local.expected_node_count} ]; do echo 'waiting for ${local.expected_node_count} nodes Ready...'; sleep 5; done",
    ]
  }
}

resource "null_resource" "wait_for_cluster" {
  depends_on = [hcloud_server.joiners]

  triggers = {
    bootstrap_id          = hcloud_server.bootstrap.id
    expected_server_count = local.expected_server_count
    joiner_ids            = join(",", [for s in hcloud_server.joiners : s.id])
  }

  connection {
    type        = "ssh"
    user        = "root"
    host        = hcloud_server.bootstrap.ipv4_address
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "until [ $(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ') -ge ${local.expected_server_count} ]; do echo 'waiting for ${local.expected_server_count} nodes Ready...'; sleep 5; done",
    ]
  }
}

# Captura kubeconfig do bootstrap via SSH, reescreve o server para apontar
# para o IP publico do bootstrap, que fica protegido por admin_cidrs.
# Usa | como delimitador no sed (portável BSD/GNU).
data "external" "kubeconfig" {
  depends_on = [
    null_resource.wait_for_cluster,
    null_resource.wait_for_workers,
  ]

  program = ["bash", "-c", <<-EOT
    KCFG=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i ${pathexpand(var.ssh_private_key_path)} \
      root@${hcloud_server.bootstrap.ipv4_address} "cat /etc/rancher/k3s/k3s.yaml" \
      | sed "s|https://127.0.0.1:6443|https://${hcloud_server.bootstrap.ipv4_address}:6443|")
    jq -nc --arg cfg "$KCFG" '{kubeconfig:$cfg}'
  EOT
  ]
}

locals {
  kc = yamldecode(data.external.kubeconfig.result.kubeconfig)
}

output "server_ipv4s" {
  description = "IPs publicos dos servers k3s (bootstrap + joiners)"
  value = concat(
    [hcloud_server.bootstrap.ipv4_address],
    [for s in hcloud_server.joiners : s.ipv4_address],
  )
}

output "server_count" {
  description = "Quantidade fixa de servers k3s. 3 e o minimo para HA com embedded etcd."
  value       = local.expected_server_count
}

output "worker_count" {
  description = "Quantidade de agents k3s dedicados a workloads."
  value       = local.expected_worker_count
}

output "worker_ipv4s" {
  description = "IPs publicos dos workers k3s"
  value       = [for s in hcloud_server.workers : s.ipv4_address]
}

output "network_id" {
  description = "ID da rede privada (10.10.0.0/16) para uso por workloads que precisem ingressar nela"
  value       = hcloud_network.private.id
}

output "registry_load_balancer_ipv4" {
  description = "Create the registry_domain A record with this address before applying platform/hetzner."
  value       = var.registry_enabled ? hcloud_load_balancer.registry[0].ipv4 : null
}

output "kube_host" {
  value = local.kc.clusters[0].cluster.server
}

output "kube_ca" {
  value     = local.kc.clusters[0].cluster["certificate-authority-data"]
  sensitive = true
}

output "kube_client_cert" {
  value     = local.kc.users[0].user["client-certificate-data"]
  sensitive = true
}

output "kube_client_key" {
  value     = local.kc.users[0].user["client-key-data"]
  sensitive = true
}

output "kubeconfig_raw" {
  description = "Kubeconfig completo (apontando para o bootstrap protegido por admin_cidrs) — exporte para arquivo se precisar usar kubectl localmente"
  value       = data.external.kubeconfig.result.kubeconfig
  sensitive   = true
}
