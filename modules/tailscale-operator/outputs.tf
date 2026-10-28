output "tailscale_operator_namespace" {
  description = "Namespace running the Tailscale Operator, its proxies, and the forwarding Service."
  value       = kubernetes_namespace_v1.tailscale_operator.metadata[0].name
}

output "proxy_group_name" {
  description = "Name of the ProxyGroup fronting the gRPC Service."
  value       = local.proxy_group_name
}

output "tailnet_acl_tags" {
  description = "Tags managed by this module's tailnet ACL (operator tag, proxy tag)."
  value       = [var.tailscale_operator_tag, var.tailscale_proxy_tag]
}

output "guard_grpc_tailnet_proxy_service_name" {
  description = "Name of the ExternalName Service forwarding tailnet traffic to the gRPC API's ClusterIP Service."
  value       = var.guard_grpc_proxy_enabled ? kubernetes_service_v1.guard_grpc_tailnet_proxy[0].metadata[0].name : null
}


output "kube_apiserver_proxy_group_name" {
  description = "ProxyGroup name and MagicDNS hostname prefix used for private Kubernetes API access."
  value       = var.kube_apiserver_proxy_group_name
}
