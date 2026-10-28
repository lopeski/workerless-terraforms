variable "r2_evidence_enabled" {
  type        = bool
  description = "Whether this module's resources (bucket, lock, lifecycle, ExternalSecret) are created. When false, the module should not be instantiated at all by the caller (count/for_each = 0) so no live Cloudflare API call is attempted."
  default     = false
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID that owns the evidence R2 bucket."
}

variable "r2_evidence_bucket_name" {
  type        = string
  description = "Name of the dedicated, exclusive-per-environment R2 bucket used to store Security Guard evidence."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.r2_evidence_bucket_name)) && length(var.r2_evidence_bucket_name) <= 63
    error_message = "r2_evidence_bucket_name must be a valid R2/DNS-label-style bucket name."
  }
}

variable "r2_evidence_retention_days" {
  type        = number
  description = "Bucket Lock retention period, in days. Must be >= 365 whenever is_production is true."
  default     = 365

  validation {
    condition     = var.r2_evidence_retention_days > 0
    error_message = "r2_evidence_retention_days must be greater than zero."
  }

  validation {
    condition     = !var.is_production || var.r2_evidence_retention_days >= 365
    error_message = "r2_evidence_retention_days must be >= 365 when is_production is true."
  }
}

variable "r2_evidence_token_secret_ref" {
  type = object({
    secret_store_name = string
    secret_store_kind = string
  })
  description = "External Secrets store reference used to materialize the Security Guard API's own R2 access-key credential (scoped to put+head on this bucket only, provisioned out-of-band — Terraform never creates this credential)."

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.r2_evidence_token_secret_ref.secret_store_name)) && length(var.r2_evidence_token_secret_ref.secret_store_name) <= 63
    error_message = "r2_evidence_token_secret_ref.secret_store_name must be a valid Kubernetes DNS label."
  }

  validation {
    condition     = contains(["SecretStore", "ClusterSecretStore"], var.r2_evidence_token_secret_ref.secret_store_kind)
    error_message = "r2_evidence_token_secret_ref.secret_store_kind must be SecretStore or ClusterSecretStore."
  }
}

variable "r2_evidence_key_prefix" {
  type        = string
  description = "Optional object-key prefix the Bucket Lock rule and lifecycle rule are scoped to. Empty string scopes the rule to all objects in the bucket."
  default     = ""
}

variable "r2_evidence_location" {
  type        = string
  description = "R2 bucket location hint. Only honored the first time a bucket with this name is created."
  default     = "weur"

  validation {
    condition     = contains(["apac", "eeur", "enam", "weur", "wnam", "oc"], var.r2_evidence_location)
    error_message = "r2_evidence_location must be one of apac, eeur, enam, weur, wnam, oc."
  }
}

variable "r2_evidence_namespace" {
  type        = string
  description = "Kubernetes namespace where the R2 credential ExternalSecret is materialized for the Security Guard API to consume."
  default     = "security-guard-grpc"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.r2_evidence_namespace)) && length(var.r2_evidence_namespace) <= 63
    error_message = "r2_evidence_namespace must be a valid Kubernetes DNS label."
  }
}

variable "is_production" {
  type        = bool
  description = "Arms the production-only validation requiring r2_evidence_retention_days >= 365."
  default     = false
}
