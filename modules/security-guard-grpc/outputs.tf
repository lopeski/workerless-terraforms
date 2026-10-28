output "guard_grpc_service_name" {
  description = "Name of the ClusterIP Service fronting the gRPC admin API. Target for modules/tailscale-operator's ProxyGroup binding."
  value       = kubernetes_service_v1.guard_grpc.metadata[0].name
}

output "guard_grpc_namespace" {
  description = "Namespace the gRPC admin API runs in."
  value       = kubernetes_namespace_v1.guard_grpc.metadata[0].name
}

output "guard_grpc_port" {
  description = "TCP port the gRPC admin API listens on."
  value       = var.guard_grpc_port
}

output "mac_client_cluster_issuer_name" {
  description = "Name of the ClusterIssuer backing the Mac client-certificate CA. The admin CLI issues per-device leaf certificates against this ClusterIssuer out-of-band — Terraform creates no leaf Certificate and never touches device private key material."
  value       = local.mac_client_cluster_issuer
}
