output "registry_url" {
  value = var.enabled ? local.external_host : null
}

output "registry_push_url" {
  value = var.enabled ? local.push_host : null
}

output "registry_credentials_source_namespace" {
  value = var.enabled ? var.namespace : null
}

output "registry_credentials_source_secret" {
  value = var.enabled ? var.robot_secret_name : null
}
