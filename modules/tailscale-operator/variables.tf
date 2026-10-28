variable "tailscale_operator_enabled" {
  type        = bool
  description = "Feature flag. When false, the caller must not instantiate this module at all (count/for_each = 0) so no Tailscale provider connection is attempted."
  default     = true
}

variable "tailscale_operator_namespace" {
  type        = string
  description = "Namespace for the Tailscale Kubernetes Operator, its proxies, and the ExternalName forwarding Service."
  default     = "tailscale"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.tailscale_operator_namespace)) && length(var.tailscale_operator_namespace) <= 63
    error_message = "tailscale_operator_namespace must be a valid Kubernetes DNS label."
  }
}

# ExternalSecret pointer for the IN-CLUSTER Operator's OAuth client/secret.
# Mirrors modules/workload's external_secret_ref shape exactly. This is a
# different credential plane than tailscale_tf_oauth_client_id/secret below:
# this one is consumed by the Operator Pod inside the cluster via a Secret
# materialized by External Secrets Operator; it never passes through the
# Terraform process itself.
variable "tailscale_oauth_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  description = "External Secrets store reference used to materialize the in-cluster Tailscale Operator's own OAuth client Secret (consumed by the Operator Pod, not by the Terraform provider)."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.tailscale_oauth_secret_ref.secret_store_name)) && length(var.tailscale_oauth_secret_ref.secret_store_name) <= 63
    error_message = "tailscale_oauth_secret_ref.secret_store_name must be a valid Kubernetes DNS label."
  }

  validation {
    condition     = contains(["SecretStore", "ClusterSecretStore"], var.tailscale_oauth_secret_ref.secret_store_kind)
    error_message = "tailscale_oauth_secret_ref.secret_store_kind must be SecretStore or ClusterSecretStore."
  }
}

variable "tailscale_operator_tag" {
  type        = string
  description = "Tailnet tag applied to the Operator's own device identity, e.g. tag:guard-operator."

  validation {
    condition     = can(regex("^tag:[a-zA-Z][a-zA-Z0-9-]*$", var.tailscale_operator_tag))
    error_message = "tailscale_operator_tag must match tag:[a-zA-Z][a-zA-Z0-9-]*."
  }
}

variable "tailscale_proxy_tag" {
  type        = string
  description = "Tailnet tag applied to ProxyGroup proxy devices, e.g. tag:guard-proxy."

  validation {
    condition     = can(regex("^tag:[a-zA-Z][a-zA-Z0-9-]*$", var.tailscale_proxy_tag))
    error_message = "tailscale_proxy_tag must match tag:[a-zA-Z][a-zA-Z0-9-]*."
  }
}

variable "tailscale_allowed_device_tags" {
  type        = list(string)
  description = "Tailnet tags of personally-authorized devices allowed to reach the gRPC proxy tag. Only these tags (plus mTLS at the application layer) may connect."

  validation {
    condition     = length(var.tailscale_allowed_device_tags) > 0
    error_message = "tailscale_allowed_device_tags must contain at least one tag."
  }

  validation {
    condition     = alltrue([for t in var.tailscale_allowed_device_tags : can(regex("^tag:[a-zA-Z][a-zA-Z0-9-]*$", t))])
    error_message = "Each tailscale_allowed_device_tags entry must match tag:[a-zA-Z][a-zA-Z0-9-]*."
  }
}

variable "guard_grpc_proxy_enabled" {
  type        = bool
  description = "Also expose the Security Guard gRPC Service through the ingress ProxyGroup. Kubernetes API access does not require this."
  default     = false
}

variable "kube_apiserver_proxy_group_name" {
  type        = string
  description = "MagicDNS hostname prefix and Kubernetes name of the HA kube-apiserver ProxyGroup."
  default     = "workerless-prod"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.kube_apiserver_proxy_group_name)) && length(var.kube_apiserver_proxy_group_name) <= 63
    error_message = "kube_apiserver_proxy_group_name must be a valid Kubernetes DNS label."
  }
}

variable "guard_grpc_service_name" {
  type        = string
  description = "Name of the existing ClusterIP Service fronting the security-guard-grpc API (owned by modules/security-guard-grpc), forwarded onto the tailnet via an ExternalName proxy Service in this module."
  default     = "guard-grpc"
}

variable "guard_grpc_namespace" {
  type        = string
  description = "Namespace of the existing security-guard-grpc Service."
  default     = "security-guard-grpc"
}

variable "guard_grpc_port" {
  type        = number
  description = "TCP port the gRPC Service listens on. Only this port is granted in the tailnet ACL."
  default     = 8443

  validation {
    condition     = var.guard_grpc_port > 0 && var.guard_grpc_port < 65536
    error_message = "guard_grpc_port must be a valid TCP port number."
  }
}

variable "proxy_group_replicas" {
  type        = number
  description = "Replica count for the Tailscale ProxyGroup fronting the gRPC Service."
  default     = 2

  validation {
    condition     = var.proxy_group_replicas >= 1
    error_message = "proxy_group_replicas must be at least 1."
  }
}

variable "is_production" {
  type        = bool
  description = "Arms the proxy_group_replicas >= 2 HA requirement."
  default     = false

  validation {
    condition     = !var.is_production || var.proxy_group_replicas >= 2
    error_message = "proxy_group_replicas must be >= 2 when is_production is true."
  }
}

variable "tailscale_hostname_override" {
  type        = string
  description = "Optional explicit MagicDNS hostname (without the .ts.net suffix) for the forwarding Service, via the tailscale.com/hostname annotation. Must match the security-guard-grpc module's tailnet_hostname (minus the tailnet suffix) used as the server certificate SAN. When null, Tailscale's default <namespace>-<service> naming applies and the operator must independently verify the resulting MagicDNS name matches the certificate SAN."
  default     = null
}

# -------------------------------------------------------------------------
# NOTE on the Terraform PROVIDER's own authentication plane: this module
# does NOT declare tailscale_tf_oauth_client_id/secret or tailnet as its own
# variables, and does NOT declare a `provider "tailscale" {}` block — same
# convention as modules/core-platform and modules/workload, which never
# declare provider "kubernetes"/"helm"/"kubectl" blocks either. Exactly one
# tailscale provider instance is needed for the whole platform/<env> call
# graph, so platform/<env> itself must declare:
#
#   provider "tailscale" {
#     oauth_client_id     = var.tailscale_tf_oauth_client_id
#     oauth_client_secret = var.tailscale_tf_oauth_client_secret
#     tailnet              = var.tailnet # defaults to "-"
#   }
#
# with tailscale_tf_oauth_client_id/secret declared as sensitive variables
# in platform/<env>/variables.tf (sourced like hcloud_token: TF_VAR_*/CI
# secret, never via ExternalSecrets, since nothing inside the cluster
# consumes this credential). This module's resources (tailscale_acl,
# ProxyGroup, etc.) use the inherited default tailscale provider implicitly.
# -------------------------------------------------------------------------
