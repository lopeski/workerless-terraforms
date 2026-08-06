output "paas_sa_token" {
  description = "Token JWT da ServiceAccount paas-admin-sa"
  value       = kubernetes_secret_v1.paas_admin_token.data["token"]
  sensitive   = true
}

output "paas_sa_token_base64" {
  description = "Token JWT da ServiceAccount codificado em Base64"
  value       = base64encode(kubernetes_secret_v1.paas_admin_token.data["token"])
  sensitive   = true
}
