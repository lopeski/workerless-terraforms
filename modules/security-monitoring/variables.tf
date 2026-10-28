variable "namespace" {
  type        = string
  description = "Namespace for Falco, Vector, and the security collector."
  default     = "security-monitoring"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.namespace)) && length(var.namespace) <= 63
    error_message = "namespace must be a valid Kubernetes DNS label."
  }
}

# -------------------------------------------------------------------------
# Falco
# -------------------------------------------------------------------------

variable "falco_chart_version" {
  type        = string
  description = "Pinned falcosecurity/charts falco chart version."
  default     = "9.2.0"
}

variable "falco_image_digest" {
  type        = string
  description = <<-EOT
    sha256 digest (hex only, no "sha256:" prefix) of the falcosecurity/falco
    image to pin. The chart's image helper always appends ":<tag>" after
    image.repository, so digest pinning is done by setting
    image.repository = "falcosecurity/falco@sha256" and image.tag = this
    value, yielding "docker.io/falcosecurity/falco@sha256:<digest>" — a
    valid digest reference. No default: callers must pin explicitly.
  EOT

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.falco_image_digest))
    error_message = "falco_image_digest must be a 64-character lowercase hex sha256 digest, without the 'sha256:' prefix."
  }
}

variable "falco_driver" {
  type        = string
  description = "Falco driver kind. Chart only documents kmod and modern_ebpf as deterministic choices (auto is excluded here because it is non-deterministic across nodes)."
  default     = "modern_ebpf"

  validation {
    condition     = contains(["kmod", "modern_ebpf"], var.falco_driver)
    error_message = "falco_driver must be kmod or modern_ebpf."
  }
}

variable "falco_custom_rules" {
  type        = map(string)
  description = "Versioned custom Falco rules, keyed by filename (e.g. \"custom-rules.yaml\"), value is the rules file content."
  default     = {}
}

variable "falco_resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "CPU/memory requests and limits for the Falco DaemonSet containers."
  default = {
    requests = { cpu = "200m", memory = "512Mi" }
    limits   = { cpu = "1", memory = "1Gi" }
  }
}

# -------------------------------------------------------------------------
# Vector
# -------------------------------------------------------------------------

variable "vector_chart_version" {
  type        = string
  description = "Pinned vectordotdev/helm-charts vector chart version."
  default     = "0.59.0"
}

variable "vector_aggregator_replicas" {
  type        = number
  description = "Replica count for the Vector Stateless-Aggregator Deployment. Must be >= 2 for PDB/topology-spread to be meaningful."
  default     = 2

  validation {
    condition     = var.vector_aggregator_replicas >= 2
    error_message = "vector_aggregator_replicas must be >= 2."
  }
}

variable "vector_agent_resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "100m", memory = "128Mi" }
    limits   = { cpu = "500m", memory = "512Mi" }
  }
}

variable "vector_aggregator_resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "200m", memory = "256Mi" }
    limits   = { cpu = "1", memory = "1Gi" }
  }
}

variable "vector_disk_buffer_max_size_bytes" {
  type        = number
  description = "Max size (bytes) of Vector's on-disk buffer per sink before when_full=drop_newest kicks in."
  default     = 268435456 # 256MiB

  validation {
    condition     = var.vector_disk_buffer_max_size_bytes >= 268435456
    error_message = "vector_disk_buffer_max_size_bytes must be at least 268435456 (256MiB) per Vector's minimum disk buffer size."
  }
}

variable "kafka_security_bootstrap_servers" {
  type        = list(string)
  description = "Kafka bootstrap servers for the Vector aggregator's Kafka sink. Empty list disables the Kafka sink (collector-only sink remains)."
  default     = []
}

variable "vector_kafka_credentials_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  description = "External Secrets store reference for Vector's Kafka SASL credentials. Required only when kafka_security_bootstrap_servers is non-empty."
  default     = null

  validation {
    condition     = var.vector_kafka_credentials_secret_ref == null || contains(["SecretStore", "ClusterSecretStore"], var.vector_kafka_credentials_secret_ref.secret_store_kind)
    error_message = "vector_kafka_credentials_secret_ref.secret_store_kind must be SecretStore or ClusterSecretStore."
  }

  validation {
    condition     = length(var.kafka_security_bootstrap_servers) == 0 || var.vector_kafka_credentials_secret_ref != null
    error_message = "vector_kafka_credentials_secret_ref is required when kafka_security_bootstrap_servers is non-empty."
  }
}

# -------------------------------------------------------------------------
# Kubernetes Audit ingestion
# -------------------------------------------------------------------------

variable "audit_webhook_port" {
  type        = number
  description = "Port the Vector aggregator's audit-webhook HTTP source listens on."
  default     = 8443
}

variable "audit_ingestion_allowed_cidr" {
  type        = string
  description = "CIDR of the k3s control-plane nodes allowed to reach the audit webhook receiver. Never 0.0.0.0/0."

  validation {
    condition     = var.audit_ingestion_allowed_cidr != "0.0.0.0/0"
    error_message = "audit_ingestion_allowed_cidr must not be 0.0.0.0/0 — scope it to the control-plane node CIDR."
  }
}

# -------------------------------------------------------------------------
# Collector
# -------------------------------------------------------------------------

variable "collector_image" {
  type        = string
  description = "Security collector container image."
}

variable "collector_replicas" {
  type        = number
  description = "Collector Deployment replica count."
  default     = 1

  validation {
    condition     = var.collector_replicas >= 1
    error_message = "collector_replicas must be >= 1."
  }
}

variable "collector_resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "100m", memory = "128Mi" }
    limits   = { cpu = "500m", memory = "512Mi" }
  }
}

variable "collector_watched_resources" {
  description = "Explicit allow-list of resources the collector RBAC may get/list/watch. No wildcards, and secrets are always rejected regardless of what is passed here."
  type = list(object({
    api_groups = list(string)
    resources  = list(string)
    verbs      = list(string)
  }))

  validation {
    condition = alltrue(flatten([
      for r in var.collector_watched_resources : [
        for v in r.verbs : contains(["get", "list", "watch"], v)
      ]
    ]))
    error_message = "collector_watched_resources verbs must be a subset of get/list/watch."
  }

  validation {
    condition = alltrue([
      for r in var.collector_watched_resources : !contains(r.resources, "secrets")
    ])
    error_message = "collector_watched_resources must never include secrets."
  }

  validation {
    condition = alltrue([
      for r in var.collector_watched_resources : length(r.api_groups) > 0 && length(r.resources) > 0 && !contains(r.api_groups, "*") && !contains(r.resources, "*")
    ])
    error_message = "collector_watched_resources must not use wildcard api_groups or resources."
  }
}

variable "collector_coordination_namespace" {
  type        = string
  description = "Namespace the collector's Lease-based coordination RBAC is scoped to. Defaults to this module's namespace when null."
  default     = null
}

variable "collector_probes" {
  type = object({
    startup = optional(object({
      http_get              = object({ path = string, port = string, scheme = optional(string, "HTTP") })
      initial_delay_seconds = optional(number, 0)
      period_seconds        = optional(number, 5)
      timeout_seconds       = optional(number, 1)
      failure_threshold     = optional(number, 30)
    }))
    readiness = optional(object({
      http_get              = object({ path = string, port = string, scheme = optional(string, "HTTP") })
      initial_delay_seconds = optional(number, 5)
      period_seconds        = optional(number, 10)
      timeout_seconds       = optional(number, 1)
      failure_threshold     = optional(number, 3)
    }))
    liveness = optional(object({
      http_get              = object({ path = string, port = string, scheme = optional(string, "HTTP") })
      initial_delay_seconds = optional(number, 15)
      period_seconds        = optional(number, 20)
      timeout_seconds       = optional(number, 1)
      failure_threshold     = optional(number, 3)
    }))
  })
  description = "Startup/readiness/liveness HTTP probes for the collector container."
  default     = {}
}

variable "collector_metrics_port" {
  type        = number
  description = "Port the collector exposes Prometheus metrics and health endpoints on."
  default     = 9090
}

variable "collector_ingest_port" {
  type        = number
  description = "Port the collector exposes its HTTPS event-ingest endpoint on, consumed by Vector's collector sink over the internal mTLS CA."
  default     = 8443
}
