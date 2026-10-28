terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 2.16" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
    time       = { source = "hashicorp/time", version = "~> 0.11" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.27" }
    tailscale  = { source = "tailscale/tailscale", version = "~> 0.29" }
    postgresql = { source = "cyrilgdn/postgresql", version = "~> 1.27" }
    kafka      = { source = "Mongey/kafka", version = "~> 0.13" }
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

variable "workerless_api_server_url" {
  description = "URL do API server k3d alcancavel pela API executada no host."
  type        = string
  default     = "https://127.0.0.1:6550"
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
      secret_store_name = string
      secret_store_kind = string
    })
    keda_polling_interval = optional(number, 30)
    keda_cooldown_period  = optional(number, 60)
    keda_triggers = list(object({
      type        = string
      metadata    = map(string)
      metric_type = optional(string)
      authentication_secret_refs = optional(list(object({
        parameter = string
        key       = string
      })), [])
    }))
    event_source_egress_rules = optional(list(object({
      cidr = string
      ports = list(object({
        port     = number
        protocol = optional(string, "TCP")
      }))
    })), [])
    min_replicas                     = optional(number, 0)
    image_pull_secret_refs           = optional(list(string), [])
    termination_grace_period_seconds = optional(number, 30)
    probes = optional(object({
      readiness = optional(object({
        http_get = object({
          path   = string
          port   = string
          scheme = optional(string, "HTTP")
        })
        initial_delay_seconds = optional(number, 5)
        period_seconds        = optional(number, 10)
        timeout_seconds       = optional(number, 1)
        failure_threshold     = optional(number, 3)
      }))
      liveness = optional(object({
        http_get = object({
          path   = string
          port   = string
          scheme = optional(string, "HTTP")
        })
        initial_delay_seconds = optional(number, 15)
        period_seconds        = optional(number, 20)
        timeout_seconds       = optional(number, 1)
        failure_threshold     = optional(number, 3)
      }))
    }), {})
    metrics = optional(object({
      enabled   = optional(bool, false)
      port_name = optional(string, "metrics")
      port      = optional(number, 9090)
      path      = optional(string, "/metrics")
    }), {})
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

  validation {
    condition = alltrue([
      for workload in values(var.workloads) : length(workload.keda_triggers) > 0
    ])
    error_message = "Each workload must declare at least one KEDA trigger."
  }
}

locals {
  workload_event_source_egress_rules = flatten([
    for workload in values(var.workloads) : workload.event_source_egress_rules
  ])
  workload_credentials_backend_keys = {
    for app_id, workload in var.workloads : app_id => "${workload.tenant_id}-${app_id}-credentials"
  }
}

# -------------------------------------------------------------------------
# Workerless Security Guard — flag-gated modules. Every *_enabled below
# defaults to false: local dev never creates fake resources or placeholder
# credentials for these capabilities (spec §12). See
# terraform.tfvars.example for the staging/production profile notes.
#
# modules/cloudflare-operational-blocking, modules/security-evidence-r2,
# modules/tailscale-operator, and modules/security-datastore-acl all
# declare their own provider configuration here at the root — none of them
# contain an internal `provider` block, because Terraform refuses to call a
# module with its own provider configuration using count/for_each/depends_on.
# See each module's README "Provider wiring" section for the exact contract.
# -------------------------------------------------------------------------

variable "is_production" {
  description = "Arms the production-only validations across the Security Guard modules (ProxyGroup HA, R2 retention floor, ...). Always false for platform/local."
  type        = bool
  default     = false
}

variable "security_guard_grpc_enabled" {
  type    = bool
  default = false
}

variable "guard_grpc_image" {
  type        = string
  default     = null
  description = "Container image for the Security Guard gRPC admin API. Required when security_guard_grpc_enabled."
}

variable "guard_grpc_port" {
  description = "TCP port the gRPC admin API listens on. Shared literal between modules.security_guard_grpc and modules.tailscale_operator — keep both in sync if ever changed."
  type        = number
  default     = 8443
}

variable "guard_grpc_replicas" {
  type    = number
  default = 2
}

variable "guard_grpc_tailnet_hostname" {
  description = "Tailscale MagicDNS hostname the gRPC server certificate SAN must cover. Must stay in sync with how the Tailscale Operator actually names the forwarding Service — see modules/tailscale-operator/README.md. Required when security_guard_grpc_enabled."
  type        = string
  default     = null
}

variable "guard_grpc_db_credentials_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  default     = null
  description = "ExternalSecret pointer for the gRPC API's read-only security-database credentials. Required when security_guard_grpc_enabled."
}

variable "guard_grpc_db_egress_cidr" {
  type        = string
  default     = null
  description = "CIDR of the security database the gRPC API reads from. Required when security_guard_grpc_enabled; never 0.0.0.0/0."
}

variable "guard_grpc_db_egress_port" {
  type    = number
  default = 5432
}

variable "guard_grpc_authorized_egress_rules" {
  type = list(object({
    cidr = string
    ports = list(object({
      port     = number
      protocol = optional(string, "TCP")
    }))
  }))
  default = []
}

variable "tailscale_operator_enabled" {
  type    = bool
  default = false
}

# Terraform-PROVIDER-level credential: the Terraform process itself
# authenticates to the Tailscale API to own the full tailnet ACL
# (tailscale_acl). Sourced like hcloud_token (TF_VAR_*/CI secret), never via
# ExternalSecrets — distinct from tailscale_oauth_secret_ref below, which is
# the IN-CLUSTER Operator's own credential.
variable "tailscale_tf_oauth_client_id" {
  type      = string
  sensitive = true
  default   = null
}

variable "tailscale_tf_oauth_client_secret" {
  type      = string
  sensitive = true
  default   = null
}

variable "tailscale_tailnet" {
  description = "Tailnet the Terraform provider manages. \"-\" resolves to whichever tailnet owns the OAuth client credentials."
  type        = string
  default     = "-"
}

variable "tailscale_oauth_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  default     = null
  description = "ExternalSecret pointer for the in-cluster Tailscale Operator's own OAuth client. Required when tailscale_operator_enabled."
}

variable "tailscale_operator_tag" {
  type        = string
  default     = null
  description = "Tailnet tag for the Operator's own device identity, e.g. tag:guard-operator. Required when tailscale_operator_enabled."
}

variable "tailscale_proxy_tag" {
  type        = string
  default     = null
  description = "Tailnet tag for ProxyGroup proxy devices, e.g. tag:guard-proxy. Required when tailscale_operator_enabled."
}

variable "tailscale_allowed_device_tags" {
  type        = list(string)
  default     = []
  description = "Tailnet tags of personally-authorized devices allowed to reach the gRPC proxy tag. Required (non-empty) when tailscale_operator_enabled."
}

variable "tailscale_hostname_override" {
  type    = string
  default = null
}

variable "proxy_group_replicas" {
  type    = number
  default = 2
}

variable "cloudflare_operational_blocking_enabled" {
  type    = bool
  default = false
}

variable "r2_evidence_enabled" {
  type    = bool
  default = false
}

# Shared Cloudflare account between the WAF-blocking and R2-evidence modules
# — they use two DISTINCT API tokens against the same account.
variable "cloudflare_account_id" {
  type    = string
  default = null
}

variable "cloudflare_waf_api_token" {
  description = "Terraform-operator bootstrap credential for modules.cloudflare_operational_blocking (broad enough to manage Rulesets+Lists). Distinct from cloudflare_r2_api_token."
  type        = string
  sensitive   = true
  default     = null
}

variable "cloudflare_r2_api_token" {
  description = "Terraform-operator bootstrap credential for modules.security_evidence_r2 (broad enough to manage the R2 bucket/lock/lifecycle). Distinct from cloudflare_waf_api_token."
  type        = string
  sensitive   = true
  default     = null
}

variable "cloudflare_zone_ids" {
  type    = list(string)
  default = []
}

variable "cloudflare_guard_list_name" {
  type    = string
  default = null
}

variable "cloudflare_guard_rule_expression" {
  type    = string
  default = null
}

variable "cloudflare_protected_endpoints" {
  type    = list(string)
  default = []
}

variable "cloudflare_guard_token_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  default = null
}

variable "guard_token_secret_namespace" {
  type    = string
  default = "security-guard-grpc"
}

variable "cloudflare_guard_token_backend_key" {
  type    = string
  default = null
}

variable "r2_evidence_bucket_name" {
  type    = string
  default = null
}

variable "r2_evidence_retention_days" {
  type    = number
  default = 365
}

variable "r2_evidence_token_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  default = null
}

variable "security_datastore_acl_enabled" {
  type    = bool
  default = false
}

# Live-connection bootstrap variables — NOT ExternalSecret pointers. The
# postgresql/kafka Terraform providers connect at plan/apply time, so these
# must be TF_VAR_*/CI-sourced like hcloud_token. Safe null/empty defaults so
# the always-initialized root provider blocks below don't break
# terraform plan when security_datastore_acl_enabled = false.
variable "postgresql_host" {
  type    = string
  default = null
}

variable "postgresql_port" {
  type    = number
  default = 5432
}

variable "postgresql_database" {
  type    = string
  default = null
}

variable "postgresql_admin_credentials_secret_ref" {
  type = object({
    username = string
    password = string
  })
  sensitive = true
  default   = null
}

variable "postgresql_security_schema" {
  type    = string
  default = "security"
}

variable "postgresql_security_tables" {
  type    = list(string)
  default = []
}

variable "postgresql_schema_owner_role" {
  type    = string
  default = null
}

variable "kafka_bootstrap_servers" {
  type    = list(string)
  default = []
}

variable "kafka_admin_credentials_secret_ref" {
  type = object({
    username = string
    password = string
  })
  sensitive = true
  default   = null
}

variable "kafka_security_topics" {
  type = map(object({
    partitions         = number
    replication_factor = number
    retention_ms       = number
  }))
  default = {}
}

variable "kafka_dlq_topic_name" {
  type    = string
  default = "security-guard-dlq"
}

variable "kafka_dlq_retention_ms" {
  type    = number
  default = 604800000
}

variable "kafka_api_principal" {
  type    = string
  default = null
}

variable "kafka_collector_principal" {
  type    = string
  default = null
}

variable "kafka_dlq_ops_principal" {
  type    = string
  default = null
}

variable "security_monitoring_enabled" {
  type    = bool
  default = false
}

variable "falco_image_digest" {
  type        = string
  default     = null
  description = "sha256 digest (hex only, no prefix) of the Falco image to pin. Required when security_monitoring_enabled."
}

variable "audit_ingestion_allowed_cidr" {
  type        = string
  default     = null
  description = "CIDR of the k3s control-plane nodes allowed to reach the audit webhook receiver. Required when security_monitoring_enabled; never 0.0.0.0/0."
}

variable "collector_image" {
  type    = string
  default = null
}

variable "collector_replicas" {
  type    = number
  default = 1
}

variable "collector_watched_resources" {
  description = "Explicit allow-list of resources the security collector's RBAC may get/list/watch. Required when security_monitoring_enabled; see terraform.tfvars.example for a starting-point list. Never includes secrets or wildcards (enforced by the module's own validation)."
  type = list(object({
    api_groups = list(string)
    resources  = list(string)
    verbs      = list(string)
  }))
  default = []
}

variable "security_monitoring_kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers for the Vector aggregator's sink. Distinct variable from kafka_bootstrap_servers (security-datastore-acl's connection target) even if pointed at the same cluster."
  type        = list(string)
  default     = []
}

variable "vector_kafka_credentials_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  default = null
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

# Security Guard: root-level provider configuration for the 4 modules that
# cannot declare their own provider block (see the variables section above
# for why). Each stays safely uninitialized-but-valid when its *_enabled
# flag is false — nothing attempts a live connection unless the gated
# module/resources are actually instantiated.
provider "cloudflare" {
  alias     = "ops_blocking"
  api_token = var.cloudflare_waf_api_token
}

provider "cloudflare" {
  alias     = "r2_evidence"
  api_token = var.cloudflare_r2_api_token
}

provider "tailscale" {
  oauth_client_id     = var.tailscale_tf_oauth_client_id
  oauth_client_secret = var.tailscale_tf_oauth_client_secret
  tailnet             = var.tailscale_tailnet
}

provider "postgresql" {
  alias           = "security_datastore"
  host            = var.postgresql_host
  port            = var.postgresql_port
  database        = var.postgresql_database
  username        = try(var.postgresql_admin_credentials_secret_ref.username, null)
  password        = try(var.postgresql_admin_credentials_secret_ref.password, null)
  sslmode         = "verify-full"
  connect_timeout = 10
  superuser       = false
}

provider "kafka" {
  alias             = "security_datastore"
  bootstrap_servers = var.kafka_bootstrap_servers
  sasl_mechanism    = "scram-sha256"
  sasl_username     = try(var.kafka_admin_credentials_secret_ref.username, null)
  sasl_password     = try(var.kafka_admin_credentials_secret_ref.password, null)
  tls_enabled       = true
}

module "core_platform" {
  source = "../../modules/core-platform"

  create_workerless_api_static_token = true

  cluster_pod_cidr          = "10.42.0.0/16"
  cluster_service_cidr      = "10.43.0.0/16"
  event_source_egress_rules = local.workload_event_source_egress_rules

  # Expõe o Prometheus via NodePort, publicado no host pelo k3d
  # (envs/local). Sem firewall externo a restringir aqui (dev local
  # single-user), então liberamos a NetworkPolicy para qualquer origem.
  prometheus_node_port = var.prometheus_node_port
  node_private_cidr    = "0.0.0.0/0"

  # Pulls do registry interno chegam ao pod a partir da bridge Docker do k3d.
  registry_node_private_cidr = "172.16.0.0/12"

  # k3d traz o local-path-provisioner nativamente; suficiente para dev.
  monitoring_storage = {
    storage_class_name = "local-path"
  }
  registry_storage = {
    storage_class_name = "local-path"
  }
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
    name      = local.workload_credentials_backend_keys[each.key]
    namespace = kubernetes_namespace_v1.dev_secrets.metadata[0].name
  }

  data = {
    RABBITMQ_CONNECTION_STRING = "amqp://guest:guest@rabbitmq.default.svc.cluster.local:5672/"
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

  app_id                           = each.key
  tenant_id                        = each.value.tenant_id
  plan_key                         = each.value.plan_key
  plan                             = var.plans[each.value.plan_key]
  worker_image                     = each.value.worker_image
  external_secret_ref              = each.value.external_secret_ref
  event_source_egress_rules        = each.value.event_source_egress_rules
  min_replicas                     = each.value.min_replicas
  keda_polling_interval            = each.value.keda_polling_interval
  keda_cooldown_period             = each.value.keda_cooldown_period
  keda_triggers                    = each.value.keda_triggers
  image_pull_secret_refs           = each.value.image_pull_secret_refs
  termination_grace_period_seconds = each.value.termination_grace_period_seconds
  probes                           = each.value.probes
  metrics                          = each.value.metrics
}

# -------------------------------------------------------------------------
# Workerless Security Guard modules — each gated by its own *_enabled flag.
# count = 0 / for_each = {} by default: nothing is created, no live
# connection to Cloudflare/Tailscale/Postgres/Kafka is ever attempted.
# -------------------------------------------------------------------------

module "security_guard_grpc" {
  count      = var.security_guard_grpc_enabled ? 1 : 0
  source     = "../../modules/security-guard-grpc"
  depends_on = [module.core_platform]

  guard_grpc_image          = var.guard_grpc_image
  guard_grpc_port           = var.guard_grpc_port
  guard_grpc_replicas       = var.guard_grpc_replicas
  tailnet_hostname          = var.guard_grpc_tailnet_hostname
  db_credentials_secret_ref = var.guard_grpc_db_credentials_secret_ref
  db_egress_cidr            = var.guard_grpc_db_egress_cidr
  db_egress_port            = var.guard_grpc_db_egress_port
  authorized_egress_rules   = var.guard_grpc_authorized_egress_rules
}

module "tailscale_operator" {
  count      = var.tailscale_operator_enabled ? 1 : 0
  source     = "../../modules/tailscale-operator"
  depends_on = [module.core_platform, module.security_guard_grpc]

  tailscale_oauth_secret_ref    = var.tailscale_oauth_secret_ref
  tailscale_operator_tag        = var.tailscale_operator_tag
  tailscale_proxy_tag           = var.tailscale_proxy_tag
  tailscale_allowed_device_tags = var.tailscale_allowed_device_tags
  guard_grpc_port               = var.guard_grpc_port
  tailscale_hostname_override   = var.tailscale_hostname_override
  proxy_group_replicas          = var.proxy_group_replicas
  is_production                 = var.is_production
}

module "cloudflare_operational_blocking" {
  count  = var.cloudflare_operational_blocking_enabled ? 1 : 0
  source = "../../modules/cloudflare-operational-blocking"

  providers = {
    cloudflare = cloudflare.ops_blocking
  }

  cloudflare_account_id             = var.cloudflare_account_id
  cloudflare_zone_ids               = var.cloudflare_zone_ids
  cloudflare_guard_list_name        = var.cloudflare_guard_list_name
  cloudflare_guard_rule_expression  = var.cloudflare_guard_rule_expression
  protected_endpoints               = var.cloudflare_protected_endpoints
  cloudflare_guard_token_secret_ref = var.cloudflare_guard_token_secret_ref
  guard_token_secret_namespace      = var.guard_token_secret_namespace
  guard_token_backend_key           = var.cloudflare_guard_token_backend_key
}

module "security_evidence_r2" {
  count  = var.r2_evidence_enabled ? 1 : 0
  source = "../../modules/security-evidence-r2"

  providers = {
    cloudflare = cloudflare.r2_evidence
  }

  cloudflare_account_id        = var.cloudflare_account_id
  r2_evidence_bucket_name      = var.r2_evidence_bucket_name
  r2_evidence_retention_days   = var.r2_evidence_retention_days
  r2_evidence_token_secret_ref = var.r2_evidence_token_secret_ref
  is_production                = var.is_production
}

module "security_datastore_acl" {
  for_each = var.security_datastore_acl_enabled ? { enabled = true } : {}
  source   = "../../modules/security-datastore-acl"

  providers = {
    postgresql = postgresql.security_datastore
    kafka      = kafka.security_datastore
  }

  security_datastore_acl_enabled = true
  postgresql_database            = var.postgresql_database
  postgresql_security_schema     = var.postgresql_security_schema
  postgresql_security_tables     = var.postgresql_security_tables
  postgresql_schema_owner_role   = var.postgresql_schema_owner_role
  kafka_security_topics          = var.kafka_security_topics
  kafka_dlq_topic_name           = var.kafka_dlq_topic_name
  kafka_dlq_retention_ms         = var.kafka_dlq_retention_ms
  kafka_api_principal            = var.kafka_api_principal
  kafka_collector_principal      = var.kafka_collector_principal
  kafka_dlq_ops_principal        = var.kafka_dlq_ops_principal
}

module "security_monitoring" {
  count      = var.security_monitoring_enabled ? 1 : 0
  source     = "../../modules/security-monitoring"
  depends_on = [module.core_platform]

  falco_image_digest                  = var.falco_image_digest
  audit_ingestion_allowed_cidr        = var.audit_ingestion_allowed_cidr
  collector_image                     = var.collector_image
  collector_replicas                  = var.collector_replicas
  collector_watched_resources         = var.collector_watched_resources
  kafka_security_bootstrap_servers    = var.security_monitoring_kafka_bootstrap_servers
  vector_kafka_credentials_secret_ref = var.vector_kafka_credentials_secret_ref
}

# A ProxyGroup with no backing Service is a misconfiguration — catch it at
# plan time rather than leaving a dangling Tailscale exposure.
check "tailscale_requires_guard_grpc" {
  assert {
    condition     = !var.tailscale_operator_enabled || var.security_guard_grpc_enabled
    error_message = "tailscale_operator_enabled requires security_guard_grpc_enabled (the ProxyGroup would have no backing Service)."
  }
}

output "paas_sa_token" {
  description = "DEPRECATED: use workerless_api_token."
  value       = module.core_platform.paas_sa_token
  sensitive   = true
}

output "paas_sa_token_base64" {
  description = "DEPRECATED: use workerless_api_token (a API espera o JWT sem Base64)."
  value       = module.core_platform.paas_sa_token_base64
  sensitive   = true
}

output "workerless_api_token" {
  description = "Token local persistente da identidade RBAC limitada workerless-api-runtime."
  value       = module.core_platform.workerless_api_token
  sensitive   = true
}

output "workerless_api_ca_base64" {
  description = "CA do cluster local em Base64."
  value       = module.core_platform.workerless_api_ca_base64
  sensitive   = true
}

output "workerless_api_server_url" {
  description = "URL do Kubernetes API server para a API local."
  value       = var.workerless_api_server_url
}

output "prometheus_url" {
  description = "URL do Prometheus via NodePort do k3d, alcançável do host — usar como OBSERVABILITY_PROMETHEUS_URL."
  value       = "http://localhost:${var.prometheus_node_port}"
}

output "registry_internal_endpoint" {
  description = "Endpoint interno host:porta do registry privado do cluster."
  value       = module.core_platform.registry_internal_endpoint
}

output "registry_internal_url" {
  description = "URL HTTP interna do registry privado do cluster."
  value       = module.core_platform.registry_internal_url
}

# -------------------------------------------------------------------------
# Workerless Security Guard — capability flags. The external API reads
# these to report each capability as available or explicitly unavailable
# (spec §12), never silently behaving as if a disabled feature were working.
# Every value below resolves even when its module isn't instantiated.
# -------------------------------------------------------------------------

output "security_guard_grpc_enabled" {
  value = var.security_guard_grpc_enabled
}

output "guard_grpc_service_name" {
  value = var.security_guard_grpc_enabled ? module.security_guard_grpc[0].guard_grpc_service_name : null
}

output "guard_grpc_namespace" {
  value = var.security_guard_grpc_enabled ? module.security_guard_grpc[0].guard_grpc_namespace : null
}

output "guard_grpc_port_output" {
  value = var.security_guard_grpc_enabled ? module.security_guard_grpc[0].guard_grpc_port : null
}

output "tailscale_operator_enabled" {
  value = var.tailscale_operator_enabled
}

output "tailscale_proxy_group_name" {
  value = var.tailscale_operator_enabled ? module.tailscale_operator[0].proxy_group_name : null
}

output "cloudflare_operational_blocking_enabled" {
  value = var.cloudflare_operational_blocking_enabled
}

output "cloudflare_guard_list_id" {
  value = var.cloudflare_operational_blocking_enabled ? module.cloudflare_operational_blocking[0].cloudflare_guard_list_id : null
}

output "r2_evidence_enabled" {
  value = var.r2_evidence_enabled
}

output "r2_evidence_bucket_name_output" {
  value = var.r2_evidence_enabled ? module.security_evidence_r2[0].r2_evidence_bucket_name : null
}

output "security_datastore_acl_enabled" {
  value = var.security_datastore_acl_enabled ? module.security_datastore_acl["enabled"].security_datastore_acl_enabled : false
}

output "security_monitoring_enabled" {
  value = var.security_monitoring_enabled
}

output "security_monitoring_namespace" {
  value = var.security_monitoring_enabled ? module.security_monitoring[0].namespace : null
}
