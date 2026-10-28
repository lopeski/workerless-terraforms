# Intencionalmente SEM bloco `provider "cloudflare" {}` neste módulo: um
# módulo que declara sua própria configuração de provider não pode ser
# chamado com count/for_each/depends_on ("Module is incompatible with
# count, for_each, and depends_on" — confirmado empiricamente contra o
# provider real). Como este módulo é opcional e instanciado via
# `count = var.r2_evidence_enabled ? 1 : 0` em platform/<env>, o provider
# "cloudflare" (autenticado com cloudflare_r2_api_token, distinto do token
# usado por modules/cloudflare-operational-blocking) deve ser declarado no
# root e passado via `providers = { cloudflare = cloudflare.<alias> }`. Ver
# README.md "Provider wiring" para o snippet exato esperado do caller.

locals {
  evidence_secret_name = "r2-evidence-credentials"
}

# -------------------------------------------------------------------------
# Bucket — privado por padrão. Nenhum cloudflare_r2_managed_domain nem
# cloudflare_r2_custom_domain é criado: "sem domínio público" é satisfeito
# por omissão, não por uma flag que possa ser invertida por engano.
# -------------------------------------------------------------------------

resource "cloudflare_r2_bucket" "evidence" {
  account_id    = var.cloudflare_account_id
  name          = var.r2_evidence_bucket_name
  location      = var.r2_evidence_location
  storage_class = "Standard"
}

# -------------------------------------------------------------------------
# Bucket Lock — retenção mínima (365d em produção). O provider aplica a
# condição "Age" a partir da data de criação/upload de cada objeto; overwrite
# e delete antecipado são rejeitados pelo R2 enquanto o objeto estiver dentro
# da janela. Terraform só declara a regra; a garantia é server-side.
# -------------------------------------------------------------------------

resource "cloudflare_r2_bucket_lock" "evidence_retention" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.evidence.name

  rules = [{
    id      = "workerless-guard-evidence-retention"
    enabled = true
    prefix  = var.r2_evidence_key_prefix
    condition = {
      type            = "Age"
      max_age_seconds = var.r2_evidence_retention_days * 86400
    }
  }]
}

# -------------------------------------------------------------------------
# Lifecycle — só pode expirar objetos APÓS a retenção, nunca antes. Usa
# max_age estritamente maior que a retenção do Bucket Lock. O Bucket Lock
# acima já impede qualquer delete antes disso; esta regra só evita acúmulo
# indefinido de evidência além do período exigido.
# -------------------------------------------------------------------------

resource "cloudflare_r2_bucket_lifecycle" "evidence_expiry" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.evidence.name

  rules = [{
    id      = "workerless-guard-evidence-expire-after-retention"
    enabled = true
    conditions = {
      prefix = var.r2_evidence_key_prefix
    }
    delete_objects_transition = {
      condition = {
        type    = "Age"
        max_age = (var.r2_evidence_retention_days + 1) * 86400
      }
    }
  }]

  lifecycle {
    precondition {
      condition     = var.r2_evidence_retention_days > 0
      error_message = "r2_evidence_retention_days must be positive for the lifecycle expiry to stay strictly after the lock period."
    }
  }
}

# -------------------------------------------------------------------------
# ExternalSecret — materializa o access key R2 da API (provisionado fora
# deste Terraform, escopado a put+head neste bucket apenas). Intencionalmente
# gavinbunney/kubectl: o CRD vem do ESO instalado em modules/core-platform,
# mas kubernetes_manifest exige o CRD no plan-time. Mesmo padrão de
# modules/workload/main.tf.
# -------------------------------------------------------------------------

resource "kubectl_manifest" "r2_evidence_external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.evidence_secret_name
      namespace = var.r2_evidence_namespace
      labels = {
        "app.kubernetes.io/name"       = "security-evidence-r2"
        "app.kubernetes.io/managed-by" = "workerless"
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = var.r2_evidence_token_secret_ref.secret_store_name
        kind = var.r2_evidence_token_secret_ref.secret_store_kind
      }
      target = {
        name           = local.evidence_secret_name
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = "${var.r2_evidence_bucket_name}-r2-credentials"
        }
      }]
    }
  })
}
