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
    name              = string
    secret_store_name = string
    secret_store_kind = string
  })
  description = "External Secrets reference used to materialize the worker environment Secret. The backend secret key and Kubernetes Secret name both use name."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.external_secret_ref.name)) && length(var.external_secret_ref.name) <= 63
    error_message = "external_secret_ref.name must be a valid Kubernetes DNS label."
  }

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
}

variable "keda_triggers" {
  type        = list(any)
  description = "KEDA triggers in ScaledObject format."
}

variable "keda_authentication_manifests" {
  type        = list(any)
  description = "Optional KEDA authentication manifests, such as TriggerAuthentication."
  default     = []
}
