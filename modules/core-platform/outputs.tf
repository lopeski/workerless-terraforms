output "paas_sa_token" {
  description = "DEPRECATED: alias do token local de workerless-api-runtime; null quando token estatico esta desabilitado."
  value       = var.create_workerless_api_static_token ? kubernetes_secret_v1.workerless_api_token[0].data["token"] : null
  sensitive   = true
}

output "paas_sa_token_base64" {
  description = "DEPRECATED: alias Base64 do token local de workerless-api-runtime."
  value       = var.create_workerless_api_static_token ? base64encode(kubernetes_secret_v1.workerless_api_token[0].data["token"]) : null
  sensitive   = true
}

output "workerless_api_token" {
  description = "Token persistente da identidade limitada, criado somente em desenvolvimento local."
  value       = var.create_workerless_api_static_token ? kubernetes_secret_v1.workerless_api_token[0].data["token"] : null
  sensitive   = true
}

output "workerless_api_ca_base64" {
  description = "CA do cluster associada ao token local, em Base64; null em producao."
  value       = var.create_workerless_api_static_token ? base64encode(kubernetes_secret_v1.workerless_api_token[0].data["ca.crt"]) : null
  sensitive   = true
}

output "registry_internal_endpoint" {
  description = "Endpoint interno host:porta do registry privado do cluster."
  value       = "${kubernetes_service_v1.registry.spec[0].cluster_ip}:${kubernetes_service_v1.registry.spec[0].port[0].port}"
}

output "registry_internal_url" {
  description = "URL HTTP interna do registry privado do cluster."
  value       = "http://${kubernetes_service_v1.registry.spec[0].cluster_ip}:${kubernetes_service_v1.registry.spec[0].port[0].port}"
}
