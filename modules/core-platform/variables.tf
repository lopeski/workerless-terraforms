variable "cluster_pod_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "cluster_service_cidr" {
  type    = string
  default = "10.43.0.0/16"
}

variable "registry_service_ip" {
  description = "ClusterIP fixo do registry interno usado pelo fluxo build-system/Kaniko."
  type        = string
  default     = "10.43.100.100"
}

variable "registry_port" {
  description = "Porta TCP do registry interno."
  type        = number
  default     = 5000
}

variable "registry_storage" {
  description = "Configuração do PVC persistente do registry interno."
  type = object({
    storage_class_name = string
    size               = optional(string, "20Gi")
  })
}

variable "event_source_egress_rules" {
  type = list(object({
    cidr = string
    ports = list(object({
      port     = number
      protocol = optional(string, "TCP")
    }))
  }))
  description = "Regras de egress para fontes externas usadas pelos scalers KEDA, como Pub/Sub, AMQP ou Kafka."
  default     = []
}

# Resources requests/limits para os componentes da plataforma. Override seletivo:
# passe apenas o subcomponente que quer ajustar; o restante mantém os defaults
# definidos em locals.default_platform_resources (main.tf).
# Estrutura esperada (todos os níveis opcionais):
#   {
#     external_secrets      = { controller = { requests = {cpu, memory}, limits = {cpu, memory} }, webhook = {...}, cert_controller = {...} }
#     keda                  = { operator = {...}, metrics_server = {...}, webhooks = {...} }
#     kyverno               = { admission = {...}, background = {...}, cleanup = {...}, reports = {...} }
#     kube_prometheus_stack = { operator = {...}, prometheus = {...}, alertmanager = {...}, grafana = {...} }
#   }
variable "platform_resources" {
  description = "Override seletivo de resources requests/limits por subcomponente. Veja locals.default_platform_resources em main.tf para defaults."
  type        = any
  default     = {}
}

# Exposição opcional do Prometheus a um consumidor externo ao cluster (ex.:
# workerless-api rodando fora do cluster). null preserva o comportamento atual
# (ClusterIP, sem regra extra de NetworkPolicy) — usado por platform/local.
variable "prometheus_node_port" {
  description = "NodePort para o Service do Prometheus. null mantém ClusterIP (sem exposição externa)."
  type        = number
  default     = null
}

variable "node_private_cidr" {
  description = "CIDR da rede privada dos nós (ex.: 10.10.1.0/24 na Hetzner). Usado para liberar tráfego já SNATed pelo NodePort do Prometheus e pulls dos nós para o registry interno."
  type        = string
  default     = null
}

variable "registry_node_private_cidr" {
  description = "CIDR de origem dos nós para pulls contra o registry interno. Quando null, usa node_private_cidr."
  type        = string
  default     = null
}

variable "create_workerless_api_static_token" {
  description = "Cria um token persistente para a API. Deve ser true somente em clusters locais descartaveis; producao deve usar TokenRequest."
  type        = bool
  default     = false
}

variable "workerless_policy_failure_action" {
  description = "Modo inicial das policies Workerless no Kyverno. Use Audit durante a migracao e Enforce depois do backfill."
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Enforce"], var.workerless_policy_failure_action)
    error_message = "workerless_policy_failure_action must be Audit or Enforce."
  }
}

# Persistência do kube-prometheus-stack. storage_class_name é obrigatório:
# - local (k3d): "local-path"
# - hetzner: "hcloud-volumes" (criado pelo Hetzner CSI Driver em platform/hetzner)
variable "monitoring_storage" {
  description = "Configuração de PVCs e retenção para Prometheus, Alertmanager e Grafana."
  type = object({
    storage_class_name        = string
    prometheus_size           = optional(string, "50Gi")
    prometheus_retention      = optional(string, "15d")
    prometheus_retention_size = optional(string, "40GiB")
    alertmanager_size         = optional(string, "5Gi")
    grafana_size              = optional(string, "10Gi")
  })
}
