output "security_datastore_acl_enabled" {
  description = "Capability flag passthrough — what platform/<env> surfaces upward to the external Security Guard API."
  value       = var.security_datastore_acl_enabled
}

output "postgresql_readonly_role_name" {
  value = postgresql_role.api_readonly.name
}

output "postgresql_writer_role_name" {
  value = postgresql_role.cron_writer.name
}

output "kafka_security_topic_names" {
  value = [for t in kafka_topic.security : t.name]
}

output "kafka_dlq_topic_name" {
  value = kafka_topic.dlq.name
}
