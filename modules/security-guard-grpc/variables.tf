variable "namespace" {
  type        = string
  description = "Namespace for the gRPC admin API. Keep the default unless you have a reason to change it — modules/tailscale-operator targets this name literally from platform/<env>."
  default     = "security-guard-grpc"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.namespace)) && length(var.namespace) <= 63
    error_message = "namespace must be a valid Kubernetes DNS label."
  }
}

variable "cert_manager_namespace" {
  type        = string
  description = "Namespace cert-manager is installed into (modules/core-platform). Root CA Certificates are created here so their Secrets land in cert-manager's default clusterResourceNamespace, which ClusterIssuer.spec.ca.secretName resolves against."
  default     = "cert-manager"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.cert_manager_namespace)) && length(var.cert_manager_namespace) <= 63
    error_message = "cert_manager_namespace must be a valid Kubernetes DNS label."
  }
}

variable "guard_grpc_image" {
  type        = string
  description = "Container image for the Security Guard gRPC admin API."
}

variable "guard_grpc_replicas" {
  type        = number
  description = "Replica count for the gRPC API Deployment."
  default     = 2

  validation {
    condition     = var.guard_grpc_replicas >= 1
    error_message = "guard_grpc_replicas must be at least 1."
  }
}

variable "guard_grpc_port" {
  type        = number
  description = "TCP port the gRPC admin API listens on. This is the port modules/tailscale-operator exposes over the tailnet via the ProxyGroup/L3 TCP binding — never via an Ingress or NodePort."
  default     = 8443
}

variable "tailnet_hostname" {
  type        = string
  description = "Tailscale MagicDNS hostname the server certificate SAN must cover, e.g. guard-grpc.your-tailnet.ts.net."

  validation {
    condition     = length(var.tailnet_hostname) > 0
    error_message = "tailnet_hostname is required."
  }
}

variable "server_cert_duration" {
  type        = string
  description = "cert-manager Certificate duration for the gRPC server leaf certificate (Go duration string)."
  default     = "2160h" # 90d
}

variable "server_cert_renew_before" {
  type        = string
  description = "cert-manager Certificate renewBefore for the gRPC server leaf certificate (Go duration string)."
  default     = "360h" # 15d
}

variable "mac_client_ca_common_name" {
  type        = string
  description = "Common name for the Mac client-certificate root CA. This CA is fully separate from the server-cert CA and from any cluster-generic CA — it exists only to validate per-device client certificates issued by the admin CLI, never by Terraform."
  default     = "workerless-mac-clients"
}

variable "tailscale_namespace" {
  type        = string
  description = "Namespace the Tailscale Operator/proxies run in (modules/tailscale-operator). The only namespace ever allowed to reach guard_grpc_port."
  default     = "tailscale"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.tailscale_namespace)) && length(var.tailscale_namespace) <= 63
    error_message = "tailscale_namespace must be a valid Kubernetes DNS label."
  }
}

variable "db_credentials_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  description = "External Secrets store reference used to materialize the security-database read-only credentials consumed by the gRPC API."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.db_credentials_secret_ref.secret_store_name)) && length(var.db_credentials_secret_ref.secret_store_name) <= 63
    error_message = "db_credentials_secret_ref.secret_store_name must be a valid Kubernetes DNS label."
  }

  validation {
    condition     = contains(["SecretStore", "ClusterSecretStore"], var.db_credentials_secret_ref.secret_store_kind)
    error_message = "db_credentials_secret_ref.secret_store_kind must be SecretStore or ClusterSecretStore."
  }
}

variable "db_credentials_backend_key" {
  type        = string
  description = "Backend key in the secrets store that holds the security-database credentials."
  default     = "security-guard-grpc-db-credentials"
}

variable "db_egress_cidr" {
  type        = string
  description = "CIDR of the security database the gRPC API reads from (read-only), reachable over TLS on db_egress_port. Never 0.0.0.0/0."

  validation {
    condition     = var.db_egress_cidr != "0.0.0.0/0"
    error_message = "db_egress_cidr must not be 0.0.0.0/0 — scope it to the actual database endpoint."
  }
}

variable "db_egress_port" {
  type        = number
  description = "TCP port of the security database."
  default     = 5432
}

variable "authorized_egress_rules" {
  type = list(object({
    cidr = string
    ports = list(object({
      port     = number
      protocol = optional(string, "TCP")
    }))
  }))
  description = "Additional explicit egress destinations the API is authorized to reach (e.g. Kafka, Mongo/Redis, authorized third-party APIs). Each entry must be a scoped CIDR, never a bare 0.0.0.0/0."
  default     = []

  validation {
    condition     = alltrue([for r in var.authorized_egress_rules : r.cidr != "0.0.0.0/0"])
    error_message = "authorized_egress_rules entries must not use a bare 0.0.0.0/0 CIDR — scope to the actual destination."
  }
}

variable "probes" {
  type = object({
    startup = optional(object({
      initial_delay_seconds = optional(number, 0)
      period_seconds        = optional(number, 5)
      timeout_seconds       = optional(number, 1)
      failure_threshold     = optional(number, 30)
    }))
    readiness = optional(object({
      initial_delay_seconds = optional(number, 5)
      period_seconds        = optional(number, 10)
      timeout_seconds       = optional(number, 1)
      failure_threshold     = optional(number, 3)
    }))
    liveness = optional(object({
      initial_delay_seconds = optional(number, 15)
      period_seconds        = optional(number, 20)
      timeout_seconds       = optional(number, 1)
      failure_threshold     = optional(number, 3)
    }))
  })
  description = "Optional startup/readiness/liveness probes for the gRPC container. All three are gRPC health checks against guard_grpc_port only — they deliberately never depend on the database or any external service, so a transient external outage cannot cause a restart loop."
  default     = {}
}

variable "container_resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "Resource requests/limits for the gRPC API container."
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { cpu = "1", memory = "1Gi" }
  }
}
