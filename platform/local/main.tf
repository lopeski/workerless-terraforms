terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.16" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
    time       = { source = "hashicorp/time", version = "~> 0.11" }
  }
}

variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/config"
}

variable "kube_context" {
  type    = string
  default = "k3d-local-rock"
}

# Deve bater com o mesmo valor em envs/local (é usado lá para o port mapping
# do k3d). Usado aqui para configurar o Service NodePort do Prometheus e
# para o output prometheus_url (OBSERVABILITY_PROMETHEUS_URL).
variable "prometheus_node_port" {
  type    = number
  default = 30090
}

variable "registry_enabled" {
  type    = bool
  default = true
}

variable "registry_node_port" {
  type    = number
  default = 30001
}

variable "registry_storage_class" {
  type    = string
  default = "local-path"
}

variable "registry_admin_password" {
  description = "Development-only Harbor administrator password."
  type        = string
  sensitive   = true
  default     = "workerless-local-harbor-admin"
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

locals {
  workload_event_source_egress_rules = flatten([
    for workload in values(var.workloads) : workload.event_source_egress_rules
  ])
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

module "core_platform" {
  source = "../../modules/core-platform"

  cluster_pod_cidr          = "10.42.0.0/16"
  cluster_service_cidr      = "10.43.0.0/16"
  event_source_egress_rules = local.workload_event_source_egress_rules

  # Expõe o Prometheus via NodePort, publicado no host pelo k3d
  # (envs/local). Sem firewall externo a restringir aqui (dev local
  # single-user), então liberamos a NetworkPolicy para qualquer origem.
  prometheus_node_port = var.prometheus_node_port
  node_private_cidr    = "0.0.0.0/0"

  # k3d traz o local-path-provisioner nativamente; suficiente para dev.
  monitoring_storage = {
    storage_class_name = "local-path"
  }
}

resource "kubernetes_secret_v1" "harbor_admin" {
  count = var.registry_enabled ? 1 : 0
  metadata {
    name      = "harbor-admin"
    namespace = "harbor"
  }
  data       = { HARBOR_ADMIN_PASSWORD = var.registry_admin_password }
  depends_on = [kubernetes_namespace_v1.harbor]
}

resource "kubernetes_namespace_v1" "harbor" {
  count = var.registry_enabled ? 1 : 0
  metadata { name = "harbor" }
}

module "harbor" {
  source = "../../modules/harbor"

  enabled           = var.registry_enabled
  namespace         = "harbor"
  create_namespace  = false
  external_url      = "http://localhost:5001"
  push_url          = "harbor-registry.harbor.svc:5000"
  expose_type       = "nodePort"
  node_port         = var.registry_node_port
  storage_class     = var.registry_storage_class
  trivy_enabled     = false
  admin_secret_name = "harbor-admin"

  depends_on = [kubernetes_secret_v1.harbor_admin]
}

# -------------------------------------------------------------------------
# Dev-only credential backend para o External Secrets Operator.
#
# Em produção (platform/hetzner), o `(Cluster)SecretStore` é provisionado
# fora deste Terraform e aponta para Vault/AWS Secrets Manager/etc.
# Localmente reproduzimos a mesma forma de consumo (workload sempre lê via
# ExternalSecret) usando o provider `kubernetes` do ESO contra Secrets
# nativos do cluster no namespace `dev-secrets`. Desenho de CLAUDE.md
# preservado — broker/DB continuam externos ao Terraform e workloads
# continuam recebendo credenciais via ExternalSecret.
# -------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "dev_secrets" {
  metadata {
    name = "dev-secrets"
    labels = {
      "kubernetes.io/metadata.name" = "dev-secrets"
    }
  }
}

resource "kubernetes_service_account_v1" "dev_secret_reader" {
  metadata {
    name      = "dev-secret-reader"
    namespace = kubernetes_namespace_v1.dev_secrets.metadata[0].name
  }
}

resource "kubernetes_role_v1" "dev_secret_reader" {
  metadata {
    name      = "dev-secret-reader"
    namespace = kubernetes_namespace_v1.dev_secrets.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "dev_secret_reader" {
  metadata {
    name      = "dev-secret-reader"
    namespace = kubernetes_namespace_v1.dev_secrets.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.dev_secret_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.dev_secret_reader.metadata[0].name
    namespace = kubernetes_namespace_v1.dev_secrets.metadata[0].name
  }
}

# Valores dummy: substituir por credenciais reais do broker/DB local
# (ou conectar via host.docker.internal) editando este Secret depois do apply.
resource "kubernetes_secret_v1" "dev_workload_credentials" {
  for_each = var.workloads

  metadata {
    name      = each.value.external_secret_ref.name
    namespace = kubernetes_namespace_v1.dev_secrets.metadata[0].name
  }

  data = {
    EXAMPLE_VAR = "dev"
  }
}

# kubectl_manifest (gavinbunney) em vez de kubernetes_manifest pelo mesmo
# motivo de modules/workload/main.tf:82-85 — o CRD do ClusterSecretStore é
# instalado no mesmo apply pelo Helm release do ESO em module.core_platform,
# e kubernetes_manifest exige o CRD em plan-time.
resource "kubectl_manifest" "dev_cluster_secret_store" {
  depends_on = [
    module.core_platform,
    kubernetes_role_binding_v1.dev_secret_reader,
  ]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "dev-secrets"
    }
    spec = {
      provider = {
        kubernetes = {
          remoteNamespace = kubernetes_namespace_v1.dev_secrets.metadata[0].name
          server = {
            url = "https://kubernetes.default.svc"
            caProvider = {
              type      = "ConfigMap"
              name      = "kube-root-ca.crt"
              key       = "ca.crt"
              namespace = kubernetes_namespace_v1.dev_secrets.metadata[0].name
            }
          }
          auth = {
            serviceAccount = {
              name      = kubernetes_service_account_v1.dev_secret_reader.metadata[0].name
              namespace = kubernetes_namespace_v1.dev_secrets.metadata[0].name
            }
          }
        }
      }
    }
  })
}

module "workload" {
  for_each = var.workloads

  source = "../../modules/workload"
  depends_on = [
    module.core_platform,
    kubectl_manifest.dev_cluster_secret_store,
    kubernetes_secret_v1.dev_workload_credentials,
  ]

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

output "prometheus_url" {
  description = "URL do Prometheus via NodePort do k3d, alcançável do host — usar como OBSERVABILITY_PROMETHEUS_URL."
  value       = "http://localhost:${var.prometheus_node_port}"
}

output "registry_url" {
  value = module.harbor.registry_url
}

output "registry_push_url" {
  value = module.harbor.registry_push_url
}

output "registry_credentials_source_namespace" {
  value = module.harbor.registry_credentials_source_namespace
}

output "registry_credentials_source_secret" {
  value = module.harbor.registry_credentials_source_secret
}
