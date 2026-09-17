variable "app_id" {
  type        = string
  description = "DNS-label identifier for the workload application."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.app_id)) && length(var.app_id) <= 63
    error_message = "app_id must be a valid Kubernetes DNS label."
  }
}

variable "tenant_id" {
  type        = string
  description = "DNS-label identifier for the tenant that owns this workload."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.tenant_id)) && length(var.tenant_id) <= 63
    error_message = "tenant_id must be a valid Kubernetes DNS label."
  }
}

variable "plan_key" {
  type        = string
  description = "Name of the plan selected for this workload."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.plan_key)) && length(var.plan_key) <= 63
    error_message = "plan_key must be a valid Kubernetes DNS label."
  }
}

variable "plan" {
  type = object({
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
  })
  description = "Plan limits, quota and autoscaling ceiling selected by the platform wrapper."
}

variable "worker_image" {
  type        = string
  description = "Consumer worker image."
}

variable "external_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  description = "External Secrets store reference used to materialize the worker environment Secret. Backend key and target Secret name are generated from tenant_id/app_id."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.external_secret_ref.secret_store_name)) && length(var.external_secret_ref.secret_store_name) <= 63
    error_message = "external_secret_ref.secret_store_name must be a valid Kubernetes DNS label."
  }

  validation {
    condition     = contains(["SecretStore", "ClusterSecretStore"], var.external_secret_ref.secret_store_kind)
    error_message = "external_secret_ref.secret_store_kind must be SecretStore or ClusterSecretStore."
  }
}

variable "node_selector" {
  type        = map(string)
  description = "Optional node selector for the worker Deployment."
  default     = {}
}

variable "event_source_egress_rules" {
  type = list(object({
    cidr = string
    ports = list(object({
      port     = number
      protocol = optional(string, "TCP")
    }))
  }))
  description = "Broker/event-source egress rules required by this workload."
  default     = []
}

variable "min_replicas" {
  type        = number
  description = "Minimum replica count for the KEDA ScaledObject."
  default     = 0

  validation {
    condition     = var.min_replicas >= 0
    error_message = "min_replicas must be zero or greater."
  }
}

variable "keda_polling_interval" {
  type        = number
  description = "KEDA polling interval in seconds."
  default     = 30

  validation {
    condition     = var.keda_polling_interval > 0
    error_message = "keda_polling_interval must be greater than zero."
  }
}

variable "keda_cooldown_period" {
  type        = number
  description = "KEDA cooldown period in seconds."
  default     = 60

  validation {
    condition     = var.keda_cooldown_period >= 0
    error_message = "keda_cooldown_period must be zero or greater."
  }
}

variable "image_pull_secret_refs" {
  type        = list(string)
  description = "Optional imagePullSecrets names to attach to the worker Pod."
  default     = []

  validation {
    condition = alltrue([
      for name in var.image_pull_secret_refs : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name)) && length(name) <= 63
    ])
    error_message = "Each image_pull_secret_refs value must be a valid Kubernetes DNS label."
  }
}

variable "termination_grace_period_seconds" {
  type        = number
  description = "Worker Pod termination grace period."
  default     = 30

  validation {
    condition     = var.termination_grace_period_seconds >= 0
    error_message = "termination_grace_period_seconds must be zero or greater."
  }
}

variable "probes" {
  type = object({
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
  })
  description = "Optional HTTP readiness/liveness probes for the worker container."
  default     = {}
}

variable "metrics" {
  type = object({
    enabled   = optional(bool, false)
    port_name = optional(string, "metrics")
    port      = optional(number, 9090)
    path      = optional(string, "/metrics")
  })
  description = "Optional Prometheus PodMonitor settings for the worker."
  default     = {}

  validation {
    condition     = !try(var.metrics.enabled, false) || can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.metrics.port_name))
    error_message = "metrics.port_name must be a valid Kubernetes DNS label when metrics are enabled."
  }
}

variable "keda_triggers" {
  type = list(object({
    type        = string
    metadata    = map(string)
    metric_type = optional(string)
    authentication_secret_refs = optional(list(object({
      parameter = string
      key       = string
    })), [])
  }))
  description = "Typed KEDA trigger descriptors. The module renders ScaledObject triggers and optional namespaced TriggerAuthentication internally."

  validation {
    condition     = length(var.keda_triggers) > 0
    error_message = "At least one KEDA trigger is required."
  }

  validation {
    condition = alltrue([
      for trigger in var.keda_triggers : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", trigger.type))
    ])
    error_message = "Each KEDA trigger type must be a lowercase DNS-label-like value such as rabbitmq, kafka, gcp-pubsub, or cron."
  }

  validation {
    condition = alltrue(flatten([
      for trigger in var.keda_triggers : [
        for ref in trigger.authentication_secret_refs : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", ref.key))
      ]
    ]))
    error_message = "Each authentication_secret_refs.key must be a valid environment-style secret key."
  }

  validation {
    condition = alltrue(flatten([
      for trigger in var.keda_triggers : [
        for ref in trigger.authentication_secret_refs : length(ref.parameter) > 0
      ]
    ]))
    error_message = "Each authentication_secret_refs.parameter must be non-empty."
  }
}
