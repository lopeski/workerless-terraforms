locals {
  host_expression    = join(" or ", [for host in var.protected_endpoints : "http.host eq \"${host}\""])
  scoped_expression  = "(${var.cloudflare_guard_rule_expression}) and (${local.host_expression})"
  guard_rule_comment = "Managed by Terraform (modules/cloudflare-operational-blocking) — Workerless Security Guard operational blocking only. Do not hand-edit; items are managed at runtime by the Security Guard API via its own minimal-scope token."
}

# Lista dedicada exclusivamente ao bloqueio operacional do Security Guard.
# items é deliberadamente omitido: o ciclo de vida de cada IP/CIDR bloqueado
# pertence à API em runtime (via cloudflare_guard_token_secret_ref), não ao
# Terraform. ignore_changes evita que um `terraform apply` remova bloqueios
# operacionais inseridos pela API entre um plan e outro (spec §7).
resource "cloudflare_list" "guard" {
  account_id  = var.cloudflare_account_id
  kind        = "ip"
  name        = var.cloudflare_guard_list_name
  description = local.guard_rule_comment

  lifecycle {
    ignore_changes = [items]
  }
}

# Uma ruleset/regra dedicada por zona, sempre escopada aos endpoints públicos
# protegidos — nunca um `ip.src in $list` zone-wide sem escopo de host.
resource "cloudflare_ruleset" "guard" {
  for_each = toset(var.cloudflare_zone_ids)

  zone_id = each.value
  name    = "workerless-guard-operational-blocking"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [
    {
      action      = "block"
      expression  = local.scoped_expression
      description = local.guard_rule_comment
      enabled     = true
    }
  ]
}

# Este módulo é dono de seu próprio ExternalSecret: materializa o token
# runtime (mínimo-escopo) da API a partir do secret manager, sem jamais ler
# ou criar o valor do token em si — ver cloudflare_guard_token_secret_ref.
resource "kubectl_manifest" "guard_token_external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = var.guard_token_secret_name
      namespace = var.guard_token_secret_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "workerless"
        "workerless.io/component"      = "cloudflare-operational-blocking"
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = var.cloudflare_guard_token_secret_ref.secret_store_name
        kind = var.cloudflare_guard_token_secret_ref.secret_store_kind
      }
      target = {
        name           = var.guard_token_secret_name
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = var.guard_token_backend_key
        }
      }]
    }
  })
}
