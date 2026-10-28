# Intencionalmente SEM bloco `provider "cloudflare" {}` neste módulo: um módulo
# que declara sua própria configuração de provider não pode ser chamado com
# count/for_each/depends_on (erro "Module is incompatible with count, for_each,
# and depends_on" — confirmado empiricamente contra o provider real). Como este
# módulo é opcional e instanciado via `count = var.cloudflare_operational_blocking_enabled
# ? 1 : 0` em platform/<env>, o provider "cloudflare" (autenticado com o token
# bootstrap do Terraform-operator, distinto do token runtime da API) deve ser
# declarado no root (platform/<env>/main.tf) e passado explicitamente via
# `providers = { cloudflare = cloudflare.<alias> }` na chamada do módulo. Ver
# README.md para o snippet exato esperado do caller.
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
  }
}
