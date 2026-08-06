variable "cluster_pod_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "cluster_service_cidr" {
  type    = string
  default = "10.43.0.0/16"
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
  description = "CIDR da rede privada dos nós (ex.: 10.10.1.0/24 na Hetzner). Necessário apenas quando prometheus_node_port != null, para liberar na NetworkPolicy o tráfego já SNATed pelo NodePort."
  type        = string
  default     = null
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
