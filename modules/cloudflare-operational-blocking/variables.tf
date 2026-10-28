variable "cloudflare_operational_blocking_enabled" {
  type        = bool
  description = "Whether this module's resources (dedicated IP list + firewall rule) should exist. platform/<env> must only instantiate this module (count/for_each) when true — absent configuration must result in the capability being reported unavailable, never a fake/placeholder block."
  default     = false
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID that owns the dedicated IP list."
}

variable "cloudflare_zone_ids" {
  type        = list(string)
  description = "Zone IDs to attach the dedicated blocking rule to. One cloudflare_ruleset is created per zone."

  validation {
    condition     = length(var.cloudflare_zone_ids) > 0
    error_message = "cloudflare_zone_ids must contain at least one zone when the module is enabled."
  }
}

variable "cloudflare_guard_list_name" {
  type        = string
  description = "Name of the dedicated IP list used exclusively for Security Guard operational blocking. Must be unambiguous per environment and must never collide with a manually-maintained list."

  validation {
    condition     = can(regex("^workerless_guard_block_[a-z0-9_]+$", var.cloudflare_guard_list_name))
    error_message = "cloudflare_guard_list_name must match ^workerless_guard_block_[a-z0-9_]+$ (e.g. workerless_guard_block_prod)."
  }
}

variable "cloudflare_guard_rule_expression" {
  type        = string
  description = "Base Wirefilter expression that references the dedicated list, e.g. \"ip.src in $workerless_guard_block_prod\". The module ANDs this with a host-match expression built from protected_endpoints — it must never be deployed unscoped."
}

variable "protected_endpoints" {
  type        = list(string)
  description = "Public hostnames this rule must be scoped to. The rendered rule only ever blocks traffic to these hosts in combination with cloudflare_guard_rule_expression — never applied zone-wide with no endpoint scope."

  validation {
    condition     = length(var.protected_endpoints) > 0
    error_message = "protected_endpoints must contain at least one hostname when the module is enabled; the blocking rule must never be unscoped."
  }
}

variable "cloudflare_guard_token_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  description = "External Secrets store reference pointing at the Security Guard API's own minimal-scope Cloudflare runtime token (Rulesets+Lists edit only, created out-of-band — see README). This module creates the ExternalSecret CR that materializes it; it never creates or reads the token's value."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.cloudflare_guard_token_secret_ref.secret_store_name)) && length(var.cloudflare_guard_token_secret_ref.secret_store_name) <= 63
    error_message = "cloudflare_guard_token_secret_ref.secret_store_name must be a valid Kubernetes DNS label."
  }

  validation {
    condition     = contains(["SecretStore", "ClusterSecretStore"], var.cloudflare_guard_token_secret_ref.secret_store_kind)
    error_message = "cloudflare_guard_token_secret_ref.secret_store_kind must be SecretStore or ClusterSecretStore."
  }
}

variable "guard_token_secret_namespace" {
  type        = string
  description = "Namespace where the ExternalSecret/Secret carrying the Security Guard API's Cloudflare runtime token is materialized (typically the gRPC API's namespace)."
}

variable "guard_token_secret_name" {
  type        = string
  description = "Name of the Kubernetes Secret materialized from cloudflare_guard_token_secret_ref."
  default     = "cloudflare-guard-runtime-token"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.guard_token_secret_name)) && length(var.guard_token_secret_name) <= 63
    error_message = "guard_token_secret_name must be a valid Kubernetes DNS label."
  }
}

variable "guard_token_backend_key" {
  type        = string
  description = "Backend key in the secret store under which the Security Guard API's Cloudflare runtime token is stored."
}
