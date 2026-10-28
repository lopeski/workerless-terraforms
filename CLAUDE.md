# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## TL;DR (English)

Terraform IaC that provisions a Kubernetes cluster (k3d locally or HA k3s on Hetzner Cloud) plus a thin PaaS for event-driven consumer workloads autoscaled by KEDA. The repo is organized in three layers — `envs/<env>` (physical cluster) → `platform/<env>` (provider wiring) → `modules/{core-platform,workload}` (shared services and per-app deployment). Brokers and databases are **external**; the platform installs only KEDA, External Secrets Operator, Kyverno (PSS baseline), CoreDNS hardening, and kube-prometheus-stack.

Two entry points: `./build.local.sh` and `./build.hetzner.sh`. Each runs `terraform fmt -check`, then `init` → `validate` → `plan` → `apply` against `envs/<env>` followed by `platform/<env>`. There is no separate unit test suite — validation is that same `fmt`/`init`/`validate`/`plan` pipeline, run locally via the build scripts and in CI via GitHub Actions (`.github/workflows/terraform-pr.yml` on pull requests, `terraform-apply.yml` running `./build.hetzner.sh` on merge to `main`). See `AGENTS.md` for commit/PR conventions. The rest of this document is in Portuguese to match the existing project docs.

---

## Visão Geral

Terraform IaC que provisiona um cluster Kubernetes (k3d local ou k3s HA na Hetzner Cloud) e instala a base de uma PaaS para workloads consumidores orientados a eventos. O usuário traz a imagem do consumidor e a configuração do seu broker; a plataforma cuida de namespace, quota, NetworkPolicies, secrets, observabilidade e autoscaling KEDA.

Componentes instalados pelo `core-platform`: **External Secrets Operator**, **KEDA**, **Kyverno** (ClusterPolicy PSS `baseline`), **CoreDNS** (Corefile com upstream Cloudflare anti-malware) e **kube-prometheus-stack**. **Brokers (RabbitMQ, Kafka, Pub/Sub, etc.) e bancos de dados são externos** — workloads se conectam via egress whitelist + credenciais entregues por External Secrets.

## Arquitetura (3 camadas)

```
envs/<env>          # 1. Infra física
                    #    - local:    cluster k3d (1 server + 1 agent)
                    #    - hetzner:  k3s HA (1 bootstrap + 2 joiners + N workers, etcd embarcado)
platform/<env>      # 2. Wrapper: configura providers, lê remote_state (hetzner) e chama os módulos
modules/
  core-platform/                      #    a. Plataforma compartilhada (ESO, KEDA, Kyverno, cert-manager, CoreDNS, kube-prometheus-stack)
  workload/                           #    b. Namespace por tenant + Deployment + ScaledObject + NetworkPolicies + ExternalSecret
  security-guard-grpc/                #    c. Workerless Security Guard (opcional, *_enabled=false por padrão) — ver seção dedicada abaixo
  tailscale-operator/                 #       e os READMEs de cada módulo para detalhes de design
  security-monitoring/
  cloudflare-operational-blocking/
  security-evidence-r2/
  security-datastore-acl/
```

`platform/<env>` é o ponto de entrada que orquestra `core-platform` + `workload` na ordem correta via `depends_on`, e também chama os 6 módulos opcionais do Security Guard (cada um por trás de sua própria flag `*_enabled`, default `false`). Em `platform/hetzner`, a configuração de providers (kubeconfig, CA, network_id) vem de `data.terraform_remote_state` apontando para o backend S3 de `envs/hetzner`.

Código legado (monolítico `startbuild.tf`, `pecas/`, `infra/` antigos) está em `_legacy/` apenas para referência — não é aplicado.

## Comandos

Ambos os scripts rodam `terraform fmt -check` antes de qualquer init e abortam se houver desformatação. Cada camada é então `init` → `validate` → `plan -out=tfplan` → `apply tfplan`, na ordem `envs/<env>` → `platform/<env>`.

### Local (k3d)

```bash
cp platform/local/terraform.tfvars.example platform/local/terraform.tfvars
# edite platform/local/terraform.tfvars (plans + workloads)

./build.local.sh
```

State local (sem backend remoto). Requer `k3d` e `kubectl` instalados; usa contexto `k3d-local-rock` em `~/.kube/config`.

### Hetzner

```bash
export TF_VAR_hcloud_token=<seu_token>

# Backend S3 remoto OBRIGATÓRIO — o script falha sem isso:
cp envs/hetzner/backend.hcl.example envs/hetzner/backend.hcl
cp platform/hetzner/backend.hcl.example platform/hetzner/backend.hcl
# edite ambos: `encryption = true` e `use_lockfile = true` são validados pelo build script

cp envs/hetzner/terraform.tfvars.example envs/hetzner/terraform.tfvars
cp platform/hetzner/terraform.tfvars.example platform/hetzner/terraform.tfvars
# edite ambos

./build.hetzner.sh
```

### Destroy (ordem reversa)

```bash
# Local
(cd platform/local && terraform destroy -auto-approve)
(cd envs/local     && terraform destroy -auto-approve)

# Hetzner
(cd platform/hetzner && terraform destroy -auto-approve)
(cd envs/hetzner     && terraform destroy -auto-approve)
```

## Configuração de workloads

`platform/<env>/terraform.tfvars` define dois mapas — `plans` e `workloads`. Veja `platform/local/terraform.tfvars.example` como referência viva.

- **`plans`** — tiers de recurso (ex.: `starter`, `growth`). Cada plan carrega `quota` (ResourceQuota), `container` (LimitRange) e `max_replicas` (cap do `ScaledObject`).
- **`workloads`** — map de aplicações. Cada entrada inclui:
  - `tenant_id`, `plan_key`, `worker_image`, `min_replicas` (default 0).
  - `external_secret_ref` — `{ name, secret_store_name, secret_store_kind }`. Aponta para um `SecretStore`/`ClusterSecretStore` provisionado **fora deste Terraform**; o módulo cria o `ExternalSecret` que materializa o Secret no namespace do workload.
  - `event_source_egress_rules` — lista `[{ cidr, ports: [{port}] }]`. Abre o egress (default-deny) tanto para o KEDA (no namespace `keda`) quanto para os pods do workload, restrito ao broker em uso.
  - `keda_triggers` — passado como-está para o `ScaledObject` (ex.: `rabbitmq`, `kafka`, `gcp-pubsub`).

O namespace do workload é `wl-{tenant_id}-{app_id}` (validado contra 63 chars DNS label) e recebe label `pod-security.kubernetes.io/enforce=baseline`.

## Credenciais

- **`TF_VAR_hcloud_token`** — único valor sensível consumido diretamente pelo Terraform. Sem default; pode vir de env var ou `terraform.tfvars`.
- **Credenciais de workload (broker, DB, etc.)** — nunca passam pelo Terraform. São providenciadas no backend de secrets (Vault, AWS Secrets Manager, GCP Secret Manager, etc.) e o cluster as alcança via `(Cluster)SecretStore` apontada por `external_secret_ref`.
- **Backend S3 da Hetzner** — credenciais via env vars padrão AWS (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` ou `AWS_PROFILE`).
- **Acesso do control-plane da PaaS (ex.: `workerless-api`, rodando fora do cluster)** — `modules/core-platform` cria a ServiceAccount `workerless-api-runtime` (namespace `workerless-system`), escopada por ClusterRoles dedicados (`workerless-namespace-bootstrap`, `workerless-api-token-issuer`, `workerless-tenant-runtime`) em vez de `cluster-admin`. `platform/hetzner` não cria nem expõe um token Secret de longa duração: CI autentica com uma identidade administrativa separada, usa o `workerless-api-token-issuer` para emitir um `TokenRequest` de curta duração (`kubectl create token workerless-api-runtime --duration=1h`) e grava o resultado no secret manager de produção sob as chaves `KUBERNETES_SERVER_URL`/`KUBERNETES_BEARER_TOKEN`/`KUBERNETES_CA_DATA_BASE64`. Ver `docs/workerless-api-credentials.md` para o contrato completo (rotação, `OBSERVABILITY_PROMETHEUS_URL` continua exposto via `prometheus_url`). O acesso de rede a esse host é liberado via `control_plane_cidrs` (não `admin_cidrs`, que também dá SSH).
- `.gitignore` exclui `*.tfvars` (preserva `*.tfvars.example`), `backend.hcl`, `*.tfstate*`, `.terraform/`.

## Decisões e Trade-offs

- **Brokers e bancos são externos.** A plataforma não instala RabbitMQ/Postgres — workloads se conectam a serviços gerenciados via `event_source_egress_rules` + `external_secret_ref`. Reduz acoplamento entre dia-2 do data store e o ciclo de vida do cluster.
- **HA na Hetzner** — bootstrap + 2 joiners de control plane (etcd embarcado) + N workers, em rede privada `10.10.0.0/16`. Firewall fecha tudo exceto SSH/API a partir de `admin_cidrs` e tráfego inter-cluster.
- **Backend S3 remoto na Hetzner com `encryption = true` e `use_lockfile = true`** — exigido pelo `build.hetzner.sh`. Local ainda usa state local (workflow single-user).
- **gVisor removido** do módulo. `RuntimeClass runsc` sem o binário `runsc` e `containerd-shim-runsc-v1` instalados nos nós não funciona; manter manifests criava ilusão de segurança. Se voltar, instalar via `user_data`/cloud-init.
- **Namespaces como `kubernetes_namespace_v1`** (não `create_namespace = true` do Helm). Elimina race com NetworkPolicies e permite fixar `pod-security.kubernetes.io/enforce`. Criados: `external-secrets`, `keda`, `monitoring`, `kyverno`.
- **CoreDNS patch declarativo** via `kubernetes_config_map_v1_data` + `kubernetes_annotations` (restart). Substitui `null_resource` + `kubectl` + Python inline.
- **Kyverno PSS baseline** em ClusterPolicy único, excluindo `kube-system`, `monitoring`, `kyverno`. Substitui 3 policies custom que bloqueavam node-exporter do kube-prometheus-stack.
- **`set_sensitive`** em todos os credentials passados para charts Helm — mantém valores fora do plan output.
- **Kubeconfig Hetzner via `terraform_remote_state`**, não arquivo em path relativo. Captura é polling-based (`remote-exec` + `until`), não `sleep 30`.
- **Prometheus exposto ao control-plane externo via NodePort + firewall Hetzner** (`prometheus_node_port`/`control_plane_cidrs`), em vez de Ingress. Mesma lógica já usada para a porta 6443 (IP público do nó + CIDR allowlist), sem introduzir ingress-nginx/cert-manager/Hetzner CCM. `prometheus_node_port = null` (default do módulo, usado por `platform/local`) mantém ClusterIP-only.
- **`workerless-api-runtime` usa ClusterRoles escopados, não `cluster-admin`** — hardening já implementado (ver `docs/workerless-api-credentials.md`; `docs/paas-control-plane-rbac.md` descreve a identidade legada `paas-admin-sa` que foi substituída). Globalmente a API só pode `get/create` namespaces e criar `SelfSubjectAccessReview`; permissões de tenant (`workerless-tenant-runtime`) são concedidas por namespace via RoleBinding gerado pelo Kyverno. Nenhum token de longa duração é criado em produção — CI emite um `TokenRequest` de 1h sob demanda.
- **Workerless Security Guard** (`modules/security-guard-grpc`, `tailscale-operator`, `security-monitoring`, `cloudflare-operational-blocking`, `security-evidence-r2`, `security-datastore-acl`) — ver a seção dedicada no `README.md` para o que cada módulo faz. Todos ficam atrás de uma flag `*_enabled` própria (default `false`); nenhum é exercitado por `./build.local.sh` até que `platform/local/terraform.tfvars` ative explicitamente. Decisões arquiteturais fixadas: PKI via cert-manager + CAs self-signed independentes por domínio (nunca Vault, nunca chave privada de CA gerada direto pelo provider `tls`); `tailscale_acl` é full-replace — este repo passa a ser o único dono da política do tailnet; `security-datastore-acl` assume uma identidade de banco/Kafka que já existe fora deste Terraform (é apenas gestão de role/ACL, não provisiona o banco).
- **Um módulo com `provider {}` próprio não pode ser chamado com `count`/`for_each`/`depends_on`** (erro real do Terraform: "Module is incompatible with count, for_each, and depends_on") — descoberto ao implementar os módulos acima, que precisam ser opcionais. Por isso `cloudflare-operational-blocking`, `security-evidence-r2`, `tailscale-operator` e `security-datastore-acl` **não** declaram `provider "cloudflare"/"tailscale"/"postgresql"/"kafka" {}` internamente — apenas `required_providers` em `versions.tf`. Quem declara e configura esses providers é sempre `platform/<env>/main.tf` (inclusive com `alias` quando duas credenciais distintas usam o mesmo provider, ex.: `cloudflare.ops_blocking` vs `cloudflare.r2_evidence`), passando-os ao módulo via `providers = { ... }`. Como `platform/<env>` não tem `count` em si mesmo, esses provider blocks raiz são sempre inicializados mesmo com a capability desligada — as variáveis de conexão correspondentes precisam de default seguro (`null`/vazio) para não quebrar `plan` localmente.

## Operações

- **Snapshots etcd (Hetzner)** — schedule e retenção configuráveis em `envs/hetzner/terraform.tfvars` (`etcd_snapshot_schedule_cron`, `etcd_snapshot_retention`). Snapshots em `/var/lib/rancher/k3s/server/db/snapshots` na bootstrap node. Procedimento de restore documentado no `README.md`.
- **Validação** — não há suíte de testes unitários. O caminho de validação é `terraform fmt -check` → `terraform init` → `terraform validate` → `terraform plan`, executado localmente pelos build scripts e em CI pelo GitHub Actions (`.github/workflows/terraform-pr.yml` em PRs; `terraform-apply.yml` roda `./build.hetzner.sh` completo, incluindo `apply`, em merge para `main`). Convenções de PR/commit no `AGENTS.md`.

## TODOs (não implementados)

- Bumpar `kube-prometheus-stack` de 61.9.0 para versão atual (verificar breaking changes do Prometheus 3.x).
- Migrar `gavinbunney/kubectl` para `hashicorp/kubernetes_manifest` **quando** o provider oficial suportar lazy CRD validation (`wait_for_crd`). Hoje a migração quebra primeiro `terraform plan` porque os 4 usos consomem CRDs instalados no mesmo apply (Kyverno em core-platform, ESO/KEDA via `depends_on` em `platform/<env>`). `alekc/kubectl` é alternativa intermediária se o gap se prolongar.
- `cluster_pod_cidr` e `cluster_service_cidr` são defaults k3d/k3s; ajustar para outros provedores.
- State remoto também para `envs/local` / `platform/local` se o workflow virar multi-user.
