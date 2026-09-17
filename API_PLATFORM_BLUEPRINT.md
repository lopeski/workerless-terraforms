# Workerless Platform - documento de arquitetura para API

## Objetivo

Este documento descreve o que o projeto `workerless-terraforms` provisiona em ambiente local e em cloud, e como isso deve orientar a construção da API que vai gerenciar tenants, plans e workloads.

O produto-alvo é uma PaaS para workloads consumidores orientados a eventos. O usuário informa uma imagem de container, credenciais/configuração do broker e regras de autoscaling; a plataforma cria o ambiente Kubernetes necessário com segurança, observabilidade e escala automática via KEDA.

Este não é um produto para hospedar APIs REST tradicionais de cliente. Workloads de tenant são consumidores/background workers; health checks e métricas HTTP são internos e não implicam `Service`, `Ingress` ou roteamento público.

## Visão de produto

O usuário final não deve operar Terraform nem Kubernetes diretamente. A experiência desejada é:

1. Criar um tenant.
2. Escolher ou criar um plan de recursos.
3. Registrar um workload consumidor com imagem, variáveis/segredos e trigger KEDA.
4. A plataforma cria os recursos Kubernetes.
5. KEDA escala o consumer conforme backlog do broker.
6. A API expõe status, métricas, logs, eventos, atualização de imagem e deleção segura.

Hoje o repositório implementa essa plataforma como Terraform. A API deve assumir gradualmente o gerenciamento de tenants e workloads em runtime, mantendo Terraform como dono do cluster e dos componentes compartilhados.

## Separação de responsabilidades

| Responsabilidade | Dono atual | Dono futuro |
| --- | --- | --- |
| Cluster local k3d | Terraform | Terraform |
| Cluster cloud Hetzner/k3s | Terraform | Terraform |
| Rede, firewall, VMs, etcd, kubeconfig | Terraform | Terraform |
| External Secrets Operator | Terraform | Terraform |
| KEDA | Terraform | Terraform |
| Kyverno | Terraform | Terraform |
| Monitoring | Terraform | Terraform |
| CoreDNS hardening | Terraform | Terraform |
| Hetzner CSI Driver | Terraform | Terraform |
| Plans iniciais | Terraform tfvars | Seed para DB da API |
| Tenants | Terraform, indiretamente via workload | API |
| Workloads | Terraform `modules/workload` | API |
| Deployment do consumer | Terraform | API via Kubernetes API |
| ResourceQuota e LimitRange por workload | Terraform | API via Kubernetes API |
| ExternalSecret por workload | Terraform | API via Kubernetes API |
| ScaledObject KEDA por workload | Terraform | API via Kubernetes API |
| Status, logs, métricas e eventos | Fora do Terraform | API |

## Camadas do repositório

```text
envs/<env>          # Infraestrutura física ou cluster base
platform/<env>      # Providers e orquestração da plataforma
modules/
  core-platform/    # Componentes compartilhados do cluster
  workload/         # Recursos de uma aplicação consumer
```

### `envs/local`

Cria um cluster k3d local:

- Nome do cluster: `local-rock`
- Contexto esperado: `k3d-local-rock`
- API port local: `6550`
- Servers: `1`
- Agents: `1`
- Storage usado depois pela plataforma: `local-path`

O `destroy` remove o cluster `local-rock`.

### `envs/hetzner`

Cria a base cloud na Hetzner:

- Rede privada `10.10.0.0/16`
- Subnet `10.10.1.0/24`
- 3 nós k3s server para HA com embedded etcd
- N workers dedicados a workloads de tenant
- Firewall permitindo:
  - SSH `22` apenas de `admin_cidrs`
  - Kubernetes API `6443` apenas de `admin_cidrs`
  - tráfego interno k3s/etcd/kubelet/flannel apenas na rede privada
- Token k3s gerado por Terraform
- k3s instalado por `user_data`
- Servers com taint `CriticalAddonsOnly=true:NoSchedule`
- Workers com label `workerless.io/node-pool=workers`
- Snapshots automáticos do etcd
- Kubeconfig capturado do bootstrap e exposto como outputs sensíveis

O backend é S3 remoto. O script de build exige `backend.hcl` com:

- `encrypt = true`
- `use_lockfile = true`

## O que roda em local

O fluxo local é executado por:

```bash
./build.local.sh
```

Ordem:

1. `terraform fmt -check` em `envs/local`, `platform/local`, `modules/core-platform`, `modules/workload`
2. `terraform init`, `validate`, `plan`, `apply` em `envs/local`
3. `terraform init`, `validate`, `plan`, `apply` em `platform/local`

### Infra local

`envs/local` cria apenas o cluster k3d, já configurado para tratar `10.43.100.100:5000` como registry HTTP interno. Não cria broker, banco nem serviços externos. RabbitMQ, Kafka, Pub/Sub emulador, Postgres ou qualquer dependência do workload devem rodar fora desse Terraform. O contrato Terraform atual aceita RabbitMQ como scaler v1; outros brokers ficam para a API/control-plane.

### Plataforma local

`platform/local` usa o kubeconfig local:

- `kubeconfig_path`: `~/.kube/config`
- `kube_context`: `k3d-local-rock`

Ele instala `modules/core-platform` com:

- `cluster_pod_cidr = "10.42.0.0/16"`
- `cluster_service_cidr = "10.43.0.0/16"`
- storage de monitoring em `local-path`
- storage do registry interno em `local-path`
- regras de egress agregadas dos workloads declarados

Também cria um backend local de secrets para desenvolvimento:

- Namespace `dev-secrets`
- ServiceAccount `dev-secret-reader`
- Role/RoleBinding para leitura de Secrets
- `ClusterSecretStore` chamado `dev-secrets`
- Secrets dummy por workload em `dev-secrets`

Esse desenho permite que workloads consumam credenciais sempre via External Secrets Operator, mesmo em dev. Em local, o store lê Secrets nativos do namespace `dev-secrets`; em produção, o store deve apontar para Vault, AWS Secrets Manager, GCP Secret Manager ou outro backend real. A chave backend é gerada pela plataforma no formato DNS-safe `<tenant>-<app>-credentials`.

### Workloads locais atuais

Os workloads são declarados em `platform/local/terraform.tfvars`. O exemplo cria:

- plan `starter`
- workload `placeholder-consumer`
- tenant `dev`
- imagem `registry.k8s.io/pause:3.9`
- `min_replicas = 1`
- trigger KEDA RabbitMQ usado como cenário de aceite local
- Secret backend `dev-placeholder-consumer-credentials`
- Secret materializado `placeholder-consumer-credentials`
- SecretStore `dev-secrets`

Esse workload placeholder valida os manifestos, mas só fica saudável quando o Secret dev aponta para um RabbitMQ acessível pelo cluster.

## O que roda em cloud

O fluxo cloud é executado por:

```bash
export TF_VAR_hcloud_token=<token>
./build.hetzner.sh
```

Ordem:

1. `terraform fmt -check` em `envs/hetzner`, `platform/hetzner`, `modules/core-platform`, `modules/workload`
2. valida `TF_VAR_hcloud_token`
3. valida `backend.hcl` em `envs/hetzner`
4. aplica `envs/hetzner`
5. valida `backend.hcl` em `platform/hetzner`
6. aplica `platform/hetzner`

### Infra cloud

`envs/hetzner` cria a infraestrutura Kubernetes:

- 1 bootstrap server
- 2 joiner servers
- `worker_count` workers
- rede privada
- firewall
- SSH key
- token k3s
- snapshots etcd
- outputs para acesso Kubernetes

Defaults atuais:

- `k3s_version = "v1.30.5+k3s1"`
- `server_type = "cax11"`
- `worker_server_type = "cax21"`
- `worker_count = 2`
- `server_location = "ash"`
- `network_zone = "us-east"`
- `etcd_snapshot_schedule_cron = "0 */6 * * *"`
- `etcd_snapshot_retention = 14`

`admin_cidrs` é obrigatório e rejeita `0.0.0.0/0` e `::/0`.

### Plataforma cloud

`platform/hetzner` lê o remote state de `envs/hetzner` para configurar os providers Kubernetes, Helm e Kubectl. Ele instala:

- Hetzner CSI Driver
- `modules/core-platform`
- `modules/workload` para os workloads declarados

O Hetzner CSI Driver usa um Secret `hcloud` no namespace `kube-system` e instala o chart `hcloud-csi`. A storage class usada pelo monitoring e pelo registry interno é:

```text
hcloud-volumes
```

### Workloads cloud atuais

Os workloads são declarados em `platform/hetzner/terraform.tfvars`. O exemplo inclui:

- `orders-consumer`, tenant `acme`, plan `starter`, trigger RabbitMQ
- `billing-consumer`, tenant `globex`, plan `growth`, trigger Kafka

Em cloud, os workloads recebem:

- node selector `workerless.io/node-pool=workers`
- ExternalSecret apontando para `tenant-secrets`
- egress explícito para brokers externos
- quotas e limites conforme o plan

O Terraform cloud não cria um `ClusterSecretStore` de produção. Esse store deve existir fora deste Terraform e apontar para o backend real de secrets.

## Core platform

`modules/core-platform` instala os componentes compartilhados do cluster.

### Namespaces

Cria namespaces explícitos:

| Namespace | Pod Security |
| --- | --- |
| `build-system` | `baseline` |
| `external-secrets` | `baseline` |
| `keda` | `baseline` |
| `monitoring` | `privileged` |
| `kyverno` | `privileged` |

### External Secrets Operator

Instala o chart `external-secrets` versão `2.5.0` com CRDs habilitados. O objetivo é materializar Kubernetes Secrets a partir de backends externos, evitando colocar credenciais de workload no Terraform state.

### KEDA

Instala o chart `keda` versão `2.19.0`, com:

- operator
- metrics server
- webhooks
- replicas e PodDisruptionBudgets para maior disponibilidade
- NetworkPolicy default-deny e allowlist

KEDA é o mecanismo central de autoscaling. A API deve gerar `ScaledObject` e `TriggerAuthentication` namespaced. `ClusterTriggerAuthentication` não deve ser aceito para workloads de tenant.

### CoreDNS

Lê o ConfigMap `kube-system/coredns`, encontra a diretiva `forward .` e substitui os resolvers por:

- `1.1.1.2`
- `1.0.0.2`

Esses resolvers são Cloudflare anti-malware. O Terraform força restart do deployment CoreDNS via annotation.

### Kyverno

Instala Kyverno e aplica uma `ClusterPolicy` PSS baseline. A policy valida Pods e exclui namespaces de sistema e observabilidade:

- `kube-system`
- `kube-public`
- `kube-node-lease`
- `kyverno`
- `monitoring`

Workloads de tenant devem ser compatíveis com PSS baseline.

### Internal registry

Cria um Docker Registry `registry:2` no namespace `build-system` para o fluxo
ZIP/Kaniko in-cluster:

- Deployment de 1 réplica
- Service `ClusterIP` fixo `10.43.100.100:5000`
- PVC persistente
- sem autenticação neste primeiro corte
- sem NodePort, Ingress ou firewall público
- NetworkPolicy permitindo ingress no registry a partir de `build-system` e dos
  nós via `node_private_cidr`

As imagens internas devem usar o formato:

```text
10.43.100.100:5000/workerless/<tenant>/<app>:sha-<hash>
```

### Monitoring

Instala `kube-prometheus-stack` versão `61.9.0`, com:

- Prometheus
- Alertmanager
- Grafana
- kubelet/cAdvisor metrics
- PVCs para Prometheus, Alertmanager e Grafana
- NetworkPolicy default-deny e allowlist

Storage por ambiente:

| Ambiente | StorageClass |
| --- | --- |
| local | `local-path` |
| hetzner | `hcloud-volumes` |

## Módulo workload

`modules/workload` é a especificação viva do que a API deve gerar no Kubernetes.

Para cada workload, o módulo cria:

1. Namespace `wl-{tenant_id}-{app_id}`
2. ServiceAccount `{app_id}`
3. LimitRange `worker-limits`
4. ResourceQuota `worker-quota`
5. ExternalSecret `{app_id}-credentials`
6. NetworkPolicy `default-deny-all`
7. NetworkPolicy `worker-egress-allow`
8. NetworkPolicy `worker-allow-monitoring-scrape` quando métricas estão habilitadas
9. Deployment `{app_id}`
10. TriggerAuthentication `{app_id}-keda-auth` quando algum trigger usa secret
11. KEDA ScaledObject `{app_id}-scaledobject`
12. PodMonitor `{app_id}-metrics` quando métricas estão habilitadas

### Labels padrão

Todo recurso gerenciado pelo workload usa labels:

```text
app.kubernetes.io/name = <app_id>
workerless.io/tenant   = <tenant_id>
workerless.io/app      = <app_id>
workerless.io/plan     = <plan_key>
```

O namespace também recebe:

```text
kubernetes.io/metadata.name = wl-<tenant_id>-<app_id>
pod-security.kubernetes.io/enforce = baseline
```

### Segurança do workload

O Deployment gerado aplica:

- `automount_service_account_token = false`
- `run_as_non_root = true`
- `run_as_user = 1000`
- `seccompProfile = RuntimeDefault`
- `allowPrivilegeEscalation = false`
- `readOnlyRootFilesystem = true`
- drop de todas as Linux capabilities
- volume `emptyDir` montado em `/tmp`
- env vars vindas do Secret materializado pelo ExternalSecret

Esses defaults devem ser preservados pela API.

### Rede do workload

Cada namespace começa com default deny total.

Egress permitido:

- DNS para `kube-system` nas portas `53/UDP` e `53/TCP`
- regras explícitas de broker/event source via `event_source_egress_rules`
- internet pública nas portas `80`, `443`, `587`, `465`, exceto redes privadas RFC1918 e link-local

Ingress permitido:

- scrape pelo namespace `monitoring`

### Autoscaling

O `ScaledObject` aponta para o Deployment do worker:

```yaml
scaleTargetRef:
  name: <app_id>
pollingInterval: <keda_polling_interval>
cooldownPeriod: <keda_cooldown_period>
minReplicaCount: <min_replicas>
maxReplicaCount: <plan.max_replicas>
triggers:
  - type: rabbitmq
    metadata:
      queueName: <keda_triggers[0].metadata.queueName>
      mode: <keda_triggers[0].metadata.mode>
      value: "<keda_triggers[0].metadata.value>"
    authenticationRef:
      name: <app_id>-keda-auth
```

O módulo Terraform recebe descritores de trigger KEDA, não manifests CRD livres. RabbitMQ é o caso de aceite, mas o campo `type` não fica travado nele. O módulo gera internamente:

- metadata do trigger KEDA como `map(string)`
- `authenticationRef` para `TriggerAuthentication` namespaced
- `secretTargetRef` apontando somente para o Secret canônico do próprio workload

## Contrato de dados para a API

A API deve tratar Terraform como bootstrap de infraestrutura e Kubernetes como runtime. O estado de negócio deve morar no Postgres da API.

### Entidades principais

#### Plan

Define limites de recursos e teto de escala.

Campos recomendados:

- `id`
- `key`
- `name`
- `quota`
- `container`
- `maxReplicas`
- `createdAt`
- `updatedAt`

`quota` deve mapear diretamente para `ResourceQuota.spec.hard`.

`container` deve mapear para `LimitRange` e `Deployment.resources`.

#### Tenant

Representa o dono lógico dos workloads.

Campos recomendados:

- `id`
- `slug`
- `name`
- `status`
- `createdAt`
- `updatedAt`

`slug` deve ser DNS label Kubernetes, porque participa do nome do namespace.

#### Workload

Representa uma aplicação consumer.

Campos recomendados:

- `id`
- `tenantId`
- `appId`
- `planId`
- `namespace`
- `workerImage`
- `minReplicas`
- `kedaTriggers`
- `kedaAuthenticationManifests`
- `eventSourceEgressRules`
- `externalSecretRef`
- `nodeSelector`
- `status`
- `createdAt`
- `updatedAt`
- `deletedAt`

`namespace` pode ser derivado como `wl-{tenant.slug}-{appId}`, mas vale persistir para auditoria e consultas.

#### ExternalSecretRef

Estrutura:

```json
{
  "name": "orders-consumer-credentials",
  "secretStoreName": "tenant-secrets",
  "secretStoreKind": "ClusterSecretStore"
}
```

Em local, a API pode criar ou atualizar o Secret correspondente em `dev-secrets`. Em cloud/prod, a API deve apenas referenciar um secret já existente no backend externo ou acionar integração própria com Vault/secret manager.

#### EventSourceEgressRule

Estrutura:

```json
{
  "cidr": "203.0.113.10/32",
  "ports": [
    { "port": 5671, "protocol": "TCP" }
  ]
}
```

Essas regras precisam alimentar:

- NetworkPolicy do workload
- NetworkPolicy do namespace KEDA, quando o scaler precisar acessar o broker diretamente

## Endpoints recomendados

### Health e plataforma

| Método | Rota | Função |
| --- | --- | --- |
| `GET` | `/health` | Health da API |
| `GET` | `/cluster/health` | Readiness agregado de Kubernetes, KEDA, ESO, Kyverno e Prometheus |
| `GET` | `/cluster/capacity` | Capacidade total vs quotas alocadas |
| `GET` | `/cluster/components` | Versões/status dos componentes compartilhados |

### Plans

| Método | Rota | Função |
| --- | --- | --- |
| `POST` | `/plans` | Cria plan |
| `GET` | `/plans` | Lista plans |
| `GET` | `/plans/:id` | Detalha plan |
| `PATCH` | `/plans/:id` | Atualiza quota, container defaults ou max replicas |
| `DELETE` | `/plans/:id` | Remove plan se não houver workloads ativos |

Ao editar um plan, a API deve reconciliar `LimitRange`, `ResourceQuota` e `ScaledObject.maxReplicaCount` dos workloads que usam esse plan.

### Tenants

| Método | Rota | Função |
| --- | --- | --- |
| `POST` | `/tenants` | Cria tenant |
| `GET` | `/tenants` | Lista tenants |
| `GET` | `/tenants/:id` | Detalha tenant |
| `PATCH` | `/tenants/:id` | Atualiza metadados |
| `DELETE` | `/tenants/:id` | Remove tenant se não houver workloads ativos |

### Workloads

| Método | Rota | Função |
| --- | --- | --- |
| `POST` | `/tenants/:tenantId/workloads` | Cria workload e aplica recursos Kubernetes |
| `GET` | `/workloads` | Lista workloads |
| `GET` | `/workloads/:id` | Detalha workload |
| `PATCH` | `/workloads/:id` | Atualiza imagem, plan, triggers, egress ou secret ref |
| `DELETE` | `/workloads/:id` | Drena, remove recursos e soft-delete |
| `POST` | `/workloads/:id/scale` | Override manual temporário |
| `GET` | `/workloads/:id/status` | Status Kubernetes |
| `GET` | `/workloads/:id/events` | Eventos recentes |
| `GET` | `/workloads/:id/logs` | Stream ou página de logs |
| `GET` | `/workloads/:id/metrics` | Métricas Prometheus |

### Secrets em dev

Para ambiente local, endpoints úteis:

| Método | Rota | Função |
| --- | --- | --- |
| `PUT` | `/workloads/:id/dev-secret` | Cria/atualiza Secret no namespace `dev-secrets` |
| `DELETE` | `/workloads/:id/dev-secret` | Remove Secret dev |

Esses endpoints devem ser desabilitados ou protegidos em produção.

## Fluxo de criação de workload pela API

1. Receber request `POST /tenants/:tenantId/workloads`.
2. Validar tenant ativo.
3. Validar plan ativo.
4. Validar `appId` como DNS label.
5. Gerar namespace `wl-{tenantSlug}-{appId}`.
6. Validar limite de 63 caracteres do namespace.
7. Validar imagem de container.
8. Validar `externalSecretRef`.
9. Validar descritores KEDA e usar RabbitMQ como cenário de aceite.
10. Validar CIDRs e portas de egress.
11. Inserir workload no DB com `status = "pending"`.
12. Em local, criar/atualizar Secret em `dev-secrets`, se a request trouxer credenciais dev.
13. Gerar manifestos Kubernetes equivalentes ao `modules/workload`.
14. Aplicar manifestos em ordem segura:
    - Namespace
    - ServiceAccount
    - LimitRange
    - ResourceQuota
    - ExternalSecret
    - NetworkPolicies
    - Deployment
    - TriggerAuthentication
    - ScaledObject
    - PodMonitor quando métricas estiverem habilitadas
15. Consultar readiness mínima.
16. Atualizar DB para `status = "active"`.
17. Retornar workload com namespace, status e links de status/métricas/logs.

Em falha:

- marcar como `failed` ou voltar para estado anterior
- tentar cleanup best-effort dos recursos criados
- registrar erro com detalhes operacionais

## Fluxo de atualização de workload

Atualizações devem ser parciais e reconciliadas:

| Campo | Ação Kubernetes |
| --- | --- |
| `workerImage` | patch no Deployment |
| `planId` | patch ResourceQuota, LimitRange, Deployment resources e ScaledObject max |
| `minReplicas` | patch ScaledObject |
| `kedaTriggers` | patch ScaledObject |
| `kedaAuthenticationManifests` | apply/delete dos manifests de auth |
| `eventSourceEgressRules` | patch NetworkPolicies do workload e KEDA |
| `externalSecretRef` | patch ExternalSecret e Deployment envFrom se necessário |

A API deve evitar recriar namespace ou Deployment quando patch resolve.

## Fluxo de deleção de workload

Recomendação:

1. Marcar workload como `draining`.
2. Patch `ScaledObject.minReplicaCount = 0`, quando aplicável.
3. Opcionalmente suspender autoscaling ou remover ScaledObject.
4. Escalar Deployment para `0`.
5. Aguardar pods terminarem ou atingir timeout.
6. Remover recursos criados pela API.
7. Remover Secret dev em local, se existir e se for gerenciado pela API.
8. Soft-delete no DB.

## Status que a API deve expor

Para cada workload:

- namespace
- deployment exists
- desired replicas
- ready replicas
- available replicas
- KEDA ScaledObject conditions
- HPA relacionado, se existir
- pods atuais
- últimos eventos Kubernetes
- ExternalSecret readiness
- data da última reconciliação
- drift detectado

Estados de negócio recomendados:

```text
pending
active
updating
draining
failed
deleted
```

## Métricas que a API deve consultar

Via Prometheus:

- CPU por workload
- memória por workload
- restarts por pod
- replicas ready/unavailable
- taxa de logs de erro, se houver métrica
- métricas KEDA/HPA
- métricas de broker quando expostas

Métricas de backlog dependem do scaler:

- RabbitMQ: queue length
- Kafka: consumer lag
- Pub/Sub: subscription backlog

A API não deve assumir um formato único para backlog. Ela deve guardar o tipo de scaler e usar queries específicas por tipo quando houver suporte.

## Diferenças que a API precisa considerar por ambiente

### Local

- API pode rodar fora do cluster no host.
- Kubernetes client usa `~/.kube/config` e contexto `k3d-local-rock`.
- URL para chamadas do host: `http://localhost:<porta>`.
- Workloads dentro do k3d podem acessar serviços no host via `host.docker.internal`, quando aplicável.
- Secret backend dev é o namespace `dev-secrets`.
- `ClusterSecretStore` local é `dev-secrets`.
- StorageClass de monitoring é `local-path`.
- Broker/DB normalmente rodam em Docker local ou serviços externos.

### Cloud

- API deve rodar in-cluster em fase futura.
- Kubernetes client usa in-cluster config.
- Deve ter ServiceAccount própria com RBAC mínimo necessário.
- Secrets devem vir de backend real, não de Secrets dummy.
- Workloads devem rodar nos workers com node selector `workerless.io/node-pool=workers`.
- StorageClass de monitoring é `hcloud-volumes`.
- Acesso externo à API exige Ingress, DNS e TLS, ainda não implementados neste Terraform.

## RBAC mínimo da API

A API precisará criar/alterar/remover:

- namespaces
- serviceaccounts
- deployments
- resourcequotas
- limitranges
- networkpolicies
- externalsecrets
- scaledobjects
- triggerauthentications
- clustertriggerauthentications, se suportado
- secrets no namespace `dev-secrets` apenas em local/dev

Também precisará ler:

- pods
- events
- replicasets
- deployments/status
- scaledobjects/status
- externalsecrets/status
- services/endpoints do monitoring, se necessário

Em produção, evite permissão ampla em Secrets. A API deve preferir referenciar `ExternalSecret` em vez de ler/escrever credenciais reais.

## Validações obrigatórias na API

### DNS labels

Validar como Kubernetes DNS label:

- tenant slug
- app id
- plan key
- external secret name
- secret store name

Regex atual usada no Terraform:

```text
^[a-z0-9]([-a-z0-9]*[a-z0-9])?$
```

Também validar tamanho máximo de 63 caracteres.

### Namespace

O namespace gerado:

```text
wl-{tenantSlug}-{appId}
```

deve ter até 63 caracteres.

### Plan

Validar:

- `quota` com chaves aceitas pelo Kubernetes ResourceQuota
- valores de CPU/memória válidos
- `maxReplicas >= minReplicas`
- limites compatíveis com defaults e requests

### Egress

Validar:

- CIDR válido
- portas entre 1 e 65535
- protocolo `TCP` ou `UDP`
- bloquear egress amplo para redes privadas, salvo exceção administrativa explícita

### KEDA

Validar:

- lista de triggers não vazia
- `type` presente
- `metadata` presente
- referências de auth consistentes
- campos obrigatórios por scaler conhecido, quando possível

## Paridade com Terraform

Enquanto `modules/workload` existir, ele deve ser tratado como contrato de referência. A API deve gerar manifestos equivalentes.

Recomendação de teste no repo da API:

1. Criar fixtures de workload.
2. Gerar manifestos pelo `WorkloadSynthesizer`.
3. Comparar com snapshots esperados derivados de `modules/workload`.
4. Cobrir RabbitMQ no teste de aceite e fixtures adicionais para Kafka, Pub/Sub e cron.

Campos que precisam permanecer compatíveis:

- labels
- nome de namespace
- ServiceAccount sem token automount
- ExternalSecret shape
- NetworkPolicies
- SecurityContext
- ResourceQuota
- LimitRange
- ScaledObject

## Seed de plans

No estado atual, plans vivem em `terraform.tfvars`. No estado-alvo:

1. Terraform mantém plans apenas como seed inicial.
2. API lê seed no startup ou recebe por ConfigMap/arquivo.
3. Se tabela `plans` estiver vazia, API popula o DB.
4. Depois disso, CRUD de plans é feito pela API.

Evite usar Terraform para alterações rotineiras de plans quando a API estiver ativa.

## Reconcile e drift

Como Kubernetes pode ser alterado fora da API, implementar reconcile loop:

- DB é a fonte de verdade de negócio.
- Kubernetes é a fonte de verdade de runtime.
- A API compara DB vs cluster periodicamente.
- Drift deve ser marcado e exposto.
- No v1, não auto-corrigir drift destrutivo sem decisão explícita.

Drifts comuns:

- Deployment deletado manualmente.
- ScaledObject alterado manualmente.
- Secret não materializado pelo ESO.
- ResourceQuota diferente do plan.
- NetworkPolicy com regra faltando.
- Pods falhando por imagem inválida ou falta de credenciais.

## Controle de concorrência

Evitar duas operações simultâneas no mesmo workload:

- lock por workload no DB
- optimistic concurrency via `updatedAt` ou `version`
- status `updating` durante operações longas

Operações que devem ser serializadas:

- criação
- alteração de plan
- alteração de triggers
- deleção
- scale override

## Segurança da API

V1 sugerida:

- API key administrativa via header `X-Admin-Key`
- rate limiting
- request id
- logs estruturados
- audit log de operações mutáveis

V2:

- OIDC/JWT
- RBAC por tenant
- roles administrativas
- separação entre operadores e usuários finais

Dados sensíveis:

- não logar payload de credenciais
- não persistir segredo real em produção
- em local, se persistir payload dev, marcar como dev-only e evitar enviar para logs

## Deploy futuro da API

Fase futura deve adicionar `modules/control-plane`, responsável por:

- Namespace `control-plane`
- ServiceAccount da API
- ClusterRole/Role com permissões mínimas
- Deployment da API
- Service ClusterIP
- ExternalSecret para `DATABASE_URL` e `ADMIN_API_KEY`
- ConfigMap de configuração
- ServiceMonitor, se necessário
- Ingress, quando DNS/TLS estiverem definidos

Em local, a API pode rodar fora do cluster para acelerar desenvolvimento. Em cloud, deve rodar in-cluster.

## Fases recomendadas

### Fase 0 - Estado atual

- Terraform cria cluster.
- Terraform instala plataforma.
- Terraform cria workloads declarados em tfvars.
- `modules/workload` é a especificação de referência.

### Fase 1 - API sem mutação Kubernetes

- Criar repo da API.
- Criar schema Postgres.
- CRUD de tenants/plans/workloads apenas no DB.
- Validadores de DNS label, plans, egress e KEDA.
- Healthcheck.

### Fase 2 - Synthesizer

- Implementar geração de manifestos equivalentes ao `modules/workload`.
- Testes snapshot.
- Sem aplicar no cluster ainda.

### Fase 3 - Apply em local

- API aplica manifestos no k3d local.
- API cria Secrets dev em `dev-secrets`.
- `POST/PATCH/DELETE /workloads` funcionam localmente.
- Status e eventos via Kubernetes API.

### Fase 4 - Remover workloads do Terraform local

- `platform/local` mantém core-platform e dev-secrets.
- Workloads deixam de ser declarados em `terraform.tfvars`.
- API passa a ser a única forma de criar workloads localmente.

### Fase 5 - Deploy da API in-cluster

- Adicionar `modules/control-plane`.
- API roda no cluster.
- Config via ExternalSecret/ConfigMap.
- RBAC mínimo.

### Fase 6 - Cloud

- Aplicar o mesmo modelo em Hetzner.
- Postgres gerenciado ou instância externa.
- Secret backend real.
- API exposta via Ingress + TLS.

### Fase 7 - Dia 2

- Reconcile loop.
- Drift detection.
- Métricas Prometheus.
- Logs.
- Scale override.
- Auditoria.

## Não objetivos neste momento

- Criar broker gerenciado dentro do cluster.
- Criar banco de dados de usuário dentro do cluster.
- Buildar imagem do usuário.
- Substituir Terraform para cluster físico.
- Multi-region.
- Operator/CRD próprio, até haver necessidade real.
- UI self-service antes da API estabilizar.

## Pontos em aberto

- Domínio público da API em cloud.
- Ingress controller a ser usado.
- cert-manager e issuer Let's Encrypt.
- Backend de secrets de produção.
- Postgres gerenciado de produção.
- Modelo final de billing/plans.
- Estratégia de isolamento por tenant além de namespace.
- Política para egress privado em workloads que precisem acessar redes internas.
- Como expandir o contrato tipado para Kafka, Pub/Sub e outros scalers sem aceitar YAML livre de cliente.

## Resumo executivo

Em local, o projeto sobe um k3d com a plataforma completa e um backend de secrets simplificado para desenvolvimento. Isso serve para construir e testar a API rapidamente contra um Kubernetes real, sem depender de cloud.

Em cloud, o projeto sobe um k3s HA na Hetzner, com rede privada, firewall restrito, workers separados, snapshots etcd, storage via Hetzner CSI e a mesma plataforma compartilhada. Esse ambiente é o alvo de produção, mas ainda precisa de API in-cluster, Postgres, SecretStore real, Ingress, DNS e TLS.

A API deve nascer copiando fielmente o comportamento de `modules/workload`: namespace por workload, quotas por plan, ExternalSecret, NetworkPolicies, Deployment seguro e ScaledObject KEDA. Terraform continua cuidando do cluster e dos componentes compartilhados; a API assume o ciclo de vida de tenants e workloads.
