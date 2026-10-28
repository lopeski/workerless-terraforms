variable "security_datastore_acl_enabled" {
  type        = bool
  default     = false
  description = "Capability flag passed through as an output. The platform wrapper must only instantiate this module (via for_each, never a plain count) when this is true, so that no live PostgreSQL/Kafka connection is ever attempted while the capability is disabled."
}

# -----------------------------------------------------------------------
# PostgreSQL — read-only role for the API, writer role for the cron/collector
#
# NOTE on provider wiring: postgresql_host/port and the admin connection
# credential are NOT variables on this module — this module has no
# provider "postgresql" block (see main.tf's header comment and README),
# so those live exclusively on platform/<env>'s own variables.tf, feeding
# the provider block declared there. postgresql_database is the one
# exception kept here: postgresql_grant/postgresql_default_privileges take
# `database` as a REQUIRED argument on the resource itself (independent of
# the provider's own default-database setting), so this module still needs
# it as an input even though the provider connection itself is configured
# one layer up. platform/<env> should declare its own postgresql_database
# variable too (to set the provider's `database` default) and pass the
# same value down to this module.
# -----------------------------------------------------------------------

variable "postgresql_database" {
  type        = string
  default     = null
  description = "Database that holds the security schema/tables. Required by postgresql_grant/postgresql_default_privileges, which take `database` as a mandatory resource-level argument regardless of the provider's own configuration."
}

variable "postgresql_security_schema" {
  type    = string
  default = "security"
}

variable "postgresql_security_tables" {
  description = "Tables the API read-only role and the cron/collector writer role operate on, inside postgresql_security_schema."
  type        = list(string)
  default     = []
}

variable "postgresql_schema_owner_role" {
  description = "Role that creates new objects (tables) in postgresql_security_schema, e.g. the migration role. Required (non-null) to materialize the default-privilege lockdown that revokes PUBLIC's implicit grants on future tables; left null this module skips that resource and documents the gap."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------
# Kafka — topics, DLQ, and per-principal ACLs
#
# NOTE on provider wiring: kafka_bootstrap_servers and the SASL admin
# credential are NOT variables on this module — this module has no
# provider "kafka" block (see main.tf's header comment and README). Every
# kafka_topic/kafka_acl resource argument below is resource-shaping only
# (topic name, partitions, principal strings, ...); none of them need the
# broker address or credential directly, so nothing moves to this module
# for Kafka beyond what's already here.
# -----------------------------------------------------------------------

variable "kafka_security_topics" {
  description = "Security-event topics to create, keyed by topic name."
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
  default = 604800000 # 7d
}

variable "kafka_api_principal" {
  description = "Kafka ACL principal (e.g. \"User:security-guard-api\") granted Write+Describe on every topic in kafka_security_topics. Required (non-null) whenever kafka_security_topics is non-empty."
  type        = string
  default     = null
}

variable "kafka_collector_principal" {
  description = "Kafka ACL principal (e.g. \"User:security-collector\") granted Read+Describe on every topic in kafka_security_topics, and Write+Describe on the DLQ topic. Required (non-null) whenever kafka_security_topics is non-empty."
  type        = string
  default     = null
}

variable "kafka_dlq_ops_principal" {
  description = "Optional Kafka ACL principal granted Read+Describe on the DLQ topic for incident response. Left null, nobody but kafka_collector_principal can read the DLQ."
  type        = string
  default     = null
}
