output "namespace" {
  description = "Namespace hosting Falco, Vector, and the security collector."
  value       = kubernetes_namespace_v1.security_monitoring.metadata[0].name
}

output "collector_service_account_name" {
  description = "ServiceAccount used by the security collector Deployment."
  value       = kubernetes_service_account_v1.security_collector.metadata[0].name
}

output "collector_cluster_role_name" {
  description = "ClusterRole granting the collector's explicit get/list/watch allow-list. Never includes secrets."
  value       = kubernetes_cluster_role_v1.security_collector.metadata[0].name
}

output "security_collector_service_name" {
  description = "ClusterIP Service name for the security collector's ingest/metrics endpoints."
  value       = kubernetes_service_v1.security_collector.metadata[0].name
}

output "vector_aggregator_audit_webhook_service_name" {
  description = "Service name fronting the Kubernetes Audit webhook receiver (Vector aggregator's audit_events source)."
  value       = "vector-aggregator"
}
