terraform {
  backend "s3" {}

  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.16" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
    time       = { source = "hashicorp/time", version = "~> 0.11" }
  }
}

variable "plans" {
  type = map(object({
    quota = map(string)
    container = object({
      default_cpu            = string
      default_memory         = string
      default_request_cpu    = string
      default_request_memory = string
      max_cpu                = string
      max_memory             = string
    })
    max_replicas = number
  }))
  description = "Named workload plans used to drive namespace quota, container limits and KEDA max replicas."

  validation {
    condition = alltrue([
      for plan_key in keys(var.plans) : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", plan_key)) && length(plan_key) <= 63
    ])
    error_message = "Each plan key must be a valid Kubernetes DNS label."
  }
}

variable "workloads" {
  type = map(object({
    tenant_id    = string
    plan_key     = string
    worker_image = string
    external_secret_ref = object({
      name              = string
      secret_store_name = string
      secret_store_kind = string
    })
    keda_triggers                 = list(any)
    keda_authentication_manifests = optional(list(any), [])
    event_source_egress_rules = optional(list(object({
      cidr = string
      ports = list(object({
        port     = number
        protocol = optional(string, "TCP")
      }))
    })), [])
    min_replicas = optional(number, 0)
  }))
  description = "Tenant workloads keyed by DNS-label application id."

  validation {
    condition = alltrue([
      for app_id in keys(var.workloads) : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", app_id)) && length(app_id) <= 63
    ])
    error_message = "Each workload key must be a valid Kubernetes DNS label."
  }

  validation {
    condition = alltrue([
      for workload in values(var.workloads) : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", workload.tenant_id)) && length(workload.tenant_id) <= 63
    ])
    error_message = "Each workload tenant_id must be a valid Kubernetes DNS label."
  }

  validation {
    condition = alltrue([
      for app_id, workload in var.workloads : length("wl-${workload.tenant_id}-${app_id}") <= 63
    ])
    error_message = "Each generated namespace name wl-tenant-app must be 63 characters or fewer."
  }
}

variable "remote_state_bucket" {
  description = "S3 bucket that stores the remote state for envs/hetzner."
  type        = string
}

variable "remote_state_region" {
  description = "AWS region for the S3 bucket that stores envs/hetzner remote state."
  type        = string
}

variable "remote_state_env_key" {
  description = "S3 key for the envs/hetzner remote state."
  type        = string
  default     = "workerless-terraforms/envs/hetzner/terraform.tfstate"
}

variable "remote_state_profile" {
  description = "Optional AWS profile used to read the remote state."
  type        = string
  default     = null
}

variable "hcloud_token" {
  description = "Token de API do Hetzner Cloud, consumido pelo Hetzner CSI Driver. Default: reaproveita TF_VAR_hcloud_token de envs/hetzner."
  type        = string
  sensitive   = true
}

variable "prometheus_node_port" {
  description = "NodePort usado para expor o Prometheus ao control-plane externo (deve bater com o mesmo valor em envs/hetzner)."
  type        = number
  default     = 30090
}

locals {
  workload_event_source_egress_rules = flatten([
    for workload in values(var.workloads) : workload.event_source_egress_rules
  ])
}

data "terraform_remote_state" "hetzner_env" {
  backend = "s3"
  config = merge(
    {
      bucket = var.remote_state_bucket
      key    = var.remote_state_env_key
      region = var.remote_state_region
    },
    var.remote_state_profile == null ? {} : { profile = var.remote_state_profile },
  )
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.hetzner_env.outputs.kube_host
    cluster_ca_certificate = base64decode(data.terraform_remote_state.hetzner_env.outputs.kube_ca)
    client_certificate     = base64decode(data.terraform_remote_state.hetzner_env.outputs.kube_client_cert)
    client_key             = base64decode(data.terraform_remote_state.hetzner_env.outputs.kube_client_key)
  }
}

provider "kubectl" {
  host                   = data.terraform_remote_state.hetzner_env.outputs.kube_host
  cluster_ca_certificate = base64decode(data.terraform_remote_state.hetzner_env.outputs.kube_ca)
  client_certificate     = base64decode(data.terraform_remote_state.hetzner_env.outputs.kube_client_cert)
  client_key             = base64decode(data.terraform_remote_state.hetzner_env.outputs.kube_client_key)
  load_config_file       = false
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.hetzner_env.outputs.kube_host
  cluster_ca_certificate = base64decode(data.terraform_remote_state.hetzner_env.outputs.kube_ca)
  client_certificate     = base64decode(data.terraform_remote_state.hetzner_env.outputs.kube_client_cert)
  client_key             = base64decode(data.terraform_remote_state.hetzner_env.outputs.kube_client_key)
}

# Hetzner CSI Driver — provê StorageClass "hcloud-volumes" usada pelo Prometheus,
# Alertmanager e Grafana via var.monitoring_storage no core-platform. Vive em
# platform/ (não em envs/) porque envs/hetzner não tem providers kubernetes/helm
# configurados — todo acesso ao cluster passa pela camada platform/.
resource "kubernetes_secret_v1" "hcloud_csi" {
  metadata {
    name      = "hcloud"
    namespace = "kube-system"
  }
  data = {
    token = var.hcloud_token
  }
  type = "Opaque"
}

resource "helm_release" "hcloud_csi" {
  depends_on = [kubernetes_secret_v1.hcloud_csi]

  name             = "hcloud-csi"
  repository       = "https://charts.hetzner.cloud"
  chart            = "hcloud-csi"
  version          = "2.10.0"
  namespace        = "kube-system"
  create_namespace = false

  wait    = true
  timeout = 600
  atomic  = true
}

module "core_platform" {
  source     = "../../modules/core-platform"
  depends_on = [helm_release.hcloud_csi]

  cluster_pod_cidr          = "10.42.0.0/16"
  cluster_service_cidr      = "10.43.0.0/16"
  event_source_egress_rules = local.workload_event_source_egress_rules

  prometheus_node_port = var.prometheus_node_port
  node_private_cidr    = "10.10.1.0/24"

  monitoring_storage = {
    storage_class_name = "hcloud-volumes"
  }
}

module "workload" {
  for_each = var.workloads

  source     = "../../modules/workload"
  depends_on = [module.core_platform]

  app_id                        = each.key
  tenant_id                     = each.value.tenant_id
  plan_key                      = each.value.plan_key
  plan                          = var.plans[each.value.plan_key]
  worker_image                  = each.value.worker_image
  external_secret_ref           = each.value.external_secret_ref
  event_source_egress_rules     = each.value.event_source_egress_rules
  min_replicas                  = each.value.min_replicas
  keda_authentication_manifests = each.value.keda_authentication_manifests
  keda_triggers                 = each.value.keda_triggers
  node_selector                 = { "workerless.io/node-pool" = "workers" }
}

output "paas_sa_token" {
  description = "Token JWT da ServiceAccount"
  value       = module.core_platform.paas_sa_token
  sensitive   = true
}

output "paas_sa_token_base64" {
  description = "Token JWT da ServiceAccount codificado em Base64"
  value       = module.core_platform.paas_sa_token_base64
  sensitive   = true
}

output "paas_cluster_ca_base64" {
  description = "CA do Cluster em Base64 (repassado do state do Hetzner)"
  value       = data.terraform_remote_state.hetzner_env.outputs.kube_ca
  sensitive   = true
}

output "kube_host" {
  description = "URL do Kubernetes API server (repassado do state do Hetzner) — usar como KUBERNETES_SERVER_URL no control-plane externo (ex.: workerless-api)."
  value       = data.terraform_remote_state.hetzner_env.outputs.kube_host
}

output "prometheus_url" {
  description = "URL do Prometheus via NodePort, alcançável apenas a partir de control_plane_cidrs (firewall em envs/hetzner) — usar como OBSERVABILITY_PROMETHEUS_URL."
  value       = "http://${data.terraform_remote_state.hetzner_env.outputs.server_ipv4s[0]}:${var.prometheus_node_port}"
}
