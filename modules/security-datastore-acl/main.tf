# -------------------------------------------------------------------------
# security-datastore-acl — role separation + Kafka ACLs for an EXTERNAL
# security database/broker (spec §10). This module owns no infrastructure:
# it only reconciles roles/grants/topics/ACLs against a live, reachable
# PostgreSQL + Kafka endpoint.
#
# This module deliberately contains NO provider "postgresql"/"kafka" block.
# Terraform hard-errors ("Module is incompatible with count, for_each, and
# depends_on") if a module with its own provider configuration is called
# with for_each — and platform/<env> must call this module with
# for_each = var.security_datastore_acl_enabled ? {enabled = true} : {}
# so that it is never even instantiated (no live connection attempted) when
# the capability is disabled. The provider blocks live at platform/<env>'s
# root and are passed in explicitly via `providers = {...}`. See README's
# "Provider wiring" section for the exact pattern.
# -------------------------------------------------------------------------
# PostgreSQL roles — API gets SELECT-only; cron/collector gets read+write.
# Kept as two distinct roles so a compromised API credential can never
# INSERT/UPDATE/DELETE/TRUNCATE/ALTER/CREATE.
# -------------------------------------------------------------------------

resource "postgresql_role" "api_readonly" {
  name  = "security_guard_api_readonly"
  login = true

  superuser       = false
  create_role     = false
  create_database = false
}

resource "postgresql_role" "cron_writer" {
  name  = "security_guard_cron_writer"
  login = true

  superuser       = false
  create_role     = false
  create_database = false
}

resource "postgresql_grant" "api_readonly_select" {
  for_each = toset(var.postgresql_security_tables)

  database    = var.postgresql_database
  role        = postgresql_role.api_readonly.name
  schema      = var.postgresql_security_schema
  object_type = "table"
  objects     = [each.value]
  privileges  = ["SELECT"]
}

resource "postgresql_grant" "cron_writer_rw" {
  for_each = toset(var.postgresql_security_tables)

  database    = var.postgresql_database
  role        = postgresql_role.cron_writer.name
  schema      = var.postgresql_security_schema
  object_type = "table"
  objects     = [each.value]
  privileges  = ["SELECT", "INSERT", "UPDATE", "DELETE"]
}

# Lockdown so a future table created in this schema doesn't silently inherit
# a broader PUBLIC grant than the two roles above. Only materializes when the
# caller tells us which role owns newly-created objects (postgresql_grant has
# no equivalent "for future objects" semantics — that's what ALTER DEFAULT
# PRIVILEGES / postgresql_default_privileges governs instead).
resource "postgresql_default_privileges" "revoke_public_future_tables" {
  count = var.postgresql_schema_owner_role != null ? 1 : 0

  role        = "public"
  database    = var.postgresql_database
  owner       = var.postgresql_schema_owner_role
  schema      = var.postgresql_security_schema
  object_type = "table"
  privileges  = []
}

# -------------------------------------------------------------------------
# Kafka topics — explicit partitions/replication/retention per security
# topic, plus a dedicated DLQ with its own retention.
# -------------------------------------------------------------------------

resource "kafka_topic" "security" {
  for_each = var.kafka_security_topics

  name               = each.key
  partitions         = each.value.partitions
  replication_factor = each.value.replication_factor

  config = {
    "retention.ms" = tostring(each.value.retention_ms)
  }
}

resource "kafka_topic" "dlq" {
  name               = var.kafka_dlq_topic_name
  partitions         = 3
  replication_factor = 3

  config = {
    "retention.ms" = tostring(var.kafka_dlq_retention_ms)
  }
}

# -------------------------------------------------------------------------
# Kafka ACLs — producer (API) vs consumer (collector) separated per topic;
# DLQ writable only by the collector, readable only by it and an optional
# ops principal (never a broad Read grant).
# -------------------------------------------------------------------------

resource "kafka_acl" "producer_write" {
  for_each = var.kafka_security_topics

  resource_name       = each.key
  resource_type       = "Topic"
  acl_principal       = var.kafka_api_principal
  acl_host            = "*"
  acl_operation       = "Write"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "producer_describe" {
  for_each = var.kafka_security_topics

  resource_name       = each.key
  resource_type       = "Topic"
  acl_principal       = var.kafka_api_principal
  acl_host            = "*"
  acl_operation       = "Describe"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "consumer_read" {
  for_each = var.kafka_security_topics

  resource_name       = each.key
  resource_type       = "Topic"
  acl_principal       = var.kafka_collector_principal
  acl_host            = "*"
  acl_operation       = "Read"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "consumer_describe" {
  for_each = var.kafka_security_topics

  resource_name       = each.key
  resource_type       = "Topic"
  acl_principal       = var.kafka_collector_principal
  acl_host            = "*"
  acl_operation       = "Describe"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "dlq_write" {
  resource_name       = kafka_topic.dlq.name
  resource_type       = "Topic"
  acl_principal       = var.kafka_collector_principal
  acl_host            = "*"
  acl_operation       = "Write"
  acl_permission_type = "Allow"
}

resource "kafka_acl" "dlq_read_ops" {
  count = var.kafka_dlq_ops_principal != null ? 1 : 0

  resource_name       = kafka_topic.dlq.name
  resource_type       = "Topic"
  acl_principal       = var.kafka_dlq_ops_principal
  acl_host            = "*"
  acl_operation       = "Read"
  acl_permission_type = "Allow"
}

# -------------------------------------------------------------------------
# Soft consistency checks — warnings only, never block a plan/apply, since
# this module can legitimately be used for only Postgres or only Kafka.
# -------------------------------------------------------------------------

check "postgresql_config_consistency" {
  assert {
    condition     = length(var.postgresql_security_tables) == 0 || var.postgresql_database != null
    error_message = "postgresql_security_tables is set but postgresql_database is null — grants will fail to apply. Note: platform/<env> must also have a live, reachable postgresql_host configured on the provider block it passes in — this module cannot see or validate that from here."
  }
}

check "kafka_config_consistency" {
  assert {
    condition     = length(var.kafka_security_topics) == 0 || (var.kafka_api_principal != null && var.kafka_collector_principal != null)
    error_message = "kafka_security_topics is set but kafka_api_principal/kafka_collector_principal is missing — ACLs will fail to apply. Note: platform/<env> must also have live kafka_bootstrap_servers configured on the provider block it passes in — this module cannot see or validate that from here."
  }
}
