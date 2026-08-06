# Control Plane — Visão e plano de migração

## TL;DR

Estamos extraindo o gerenciamento de tenants/workloads/plans do Terraform para uma API TypeScript em repo separado (`workerless-control-plane`). Terraform continua dono do cluster físico e da plataforma compartilhada (ESO, KEDA, Kyverno, kube-prometheus-stack, CoreDNS); tenants e workloads viram dados gerenciados em runtime pela API contra Postgres + Kubernetes API. Plans começam como seed em tfvars e migram pro DB.

## Por que mover

Terraform é ótimo para infra que muda raramente, péssimo para multi-tenant em runtime:

- `terraform apply` por tenant leva 10-60s + state lock serializa operações concorrentes.
- Sem auth/audit/rate-limiting nativos — não dá pra expor pra usuário final ou CLI self-service.
- Toda mudança de workload é um diff revisado, não uma operação API.
- `for_each = var.workloads` em tfvars não escala pra dezenas/centenas de apps.
- Estado real do cluster (replicas atuais, conditions, eventos) não vive em tfstate — Terraform é cego pra dia-2.

Uma API resolve tudo isso e ainda dá superfície natural pra UI/CLI/webhook depois.

## Os dois planos

### Data Plane — Terraform (continua)

| Camada | Responsabilidade |
| --- | --- |
| `envs/<env>` | Cluster físico (k3d local, k3s HA Hetzner). Provisionamento de VMs, rede privada, firewall, snapshots etcd. |
| `modules/core-platform` | Plataforma compartilhada: ESO, KEDA, Kyverno (PSS baseline), CoreDNS hardening, kube-prometheus-stack. NetworkPolicies de monitoring. |
| `platform/<env>` | Wrapper: configura providers, instancia `core_platform`, faz seed inicial de plans, (futuro) instala `module "control_plane"`. |
| `dev-secrets` (local-only) | NS + SA + RoleBinding + ClusterSecretStore kind kubernetes — backend de credenciais pra ExternalSecret funcionar localmente sem Vault. |

### Control Plane — API (novo repo)

**Path:** `/Users/moiseslopes/WebstormProjects/workerless-control-plane`

**Stack:** TypeScript + Fastify + Prisma + `@kubernetes/client-node` + `prom-client` (queries Prometheus).

**Estado:** Postgres (externo ao Terraform; Docker em dev, managed em prod).

**O que faz:** CRUDa Namespace + ServiceAccount + Deployment + ScaledObject + ResourceQuota + LimitRange + NetworkPolicy + ExternalSecret diretamente via k8s API, gerando os mesmos manifestos que `modules/workload` emite hoje em HCL.

## Responsabilidades da API

### Tenants
- `POST /tenants` — cria tenant (slug, nome).
- `GET /tenants` / `GET /tenants/:id` — lista/detalha.
- `DELETE /tenants/:id` — bloqueado se houver workloads ativos.

### Workloads
- `POST /tenants/:id/workloads` — provisiona Namespace `wl-{tenant}-{app}` + todos os recursos derivados.
- `GET /workloads` / `GET /workloads/:id` — lista/detalha (junta DB + status do k8s).
- `PATCH /workloads/:id` — atualiza imagem, min_replicas, triggers KEDA, egress, secret ref.
- `DELETE /workloads/:id` — drena (escala pra 0), deleta recursos, marca como deletado no DB.
- `POST /workloads/:id/scale` — override manual de replicas (bypass do ScaledObject por janela X).
- `GET /workloads/:id/status` — replicas desejado/atual/ready, conditions, eventos recentes.
- `GET /workloads/:id/metrics` — proxy de queries pré-canned no Prometheus (RPS, CPU, mem, lag de fila).
- `GET /workloads/:id/logs` — stream de logs via k8s API (proxy).

### Plans
- `POST /plans` / `GET /plans` / `PATCH /plans/:id` / `DELETE /plans/:id` — CRUD.
- Plan deletado só se não houver workloads referenciando.
- Editar plan dispara reconcile dos LimitRange/ResourceQuota dos workloads daquele plan.

### Observabilidade / health
- `GET /cluster/health` — agregação de readiness dos componentes do core-platform.
- `GET /cluster/capacity` — soma de quotas atribuídas vs capacidade do cluster.

### Auth
- v1: API key estática (env `ADMIN_API_KEY`), header `X-Admin-Key`.
- v2: JWT/OIDC para multi-user, RBAC por tenant.

### Sincronização com cluster
- Reconcile loop opcional: a cada N minutos compara DB vs k8s real e flagga drift. Não auto-corrige (humano decide).
- Sem watch/informer no v1 — pull-based pra simplicidade. Migrar pra informers se latência incomodar.

## O que muda do Terraform atual

### Sai (vira responsabilidade da API)

| Hoje | Vira |
| --- | --- |
| `var.workloads` em `platform/local/main.tf:43-86` (declaração) e `platform/local/terraform.tfvars` (instâncias) | Tabela `workloads` no Postgres; criados via `POST /tenants/:id/workloads`. |
| `module "workload"` for_each em `platform/local/main.tf:124` | Removido. API materializa os mesmos recursos via `@kubernetes/client-node`. |
| `locals.workload_event_source_egress_rules` em `platform/local/main.tf:88-92` (agregação para `core_platform.event_source_egress_rules`) | API gera NetworkPolicies por workload em runtime; agregação cluster-wide deixa de existir (NetworkPolicies de monitoring continuam em core-platform). |
| `kubernetes_secret_v1.dev_workload_credentials` for_each em `platform/local/main.tf` | API cria/atualiza esses Secrets em `dev-secrets` ns junto com cada workload, espelhando as credenciais informadas no `POST /workloads`. |

### Fica como está

| Componente | Por quê |
| --- | --- |
| `envs/local`, `envs/hetzner` | Cluster físico não muda com workloads; lifecycle é diferente (mudanças raras, blast radius enorme). |
| `modules/core-platform` | Plataforma compartilhada é declarativa e idempotente; cabe bem em Terraform. |
| `kubectl_manifest.dev_cluster_secret_store`, ns `dev-secrets`, SA + RBAC | Precisam existir antes da API subir; bootstrap de plataforma. |
| `platform/<env>/main.tf` (provider config + module.core_platform + dev-secrets infra) | Continua sendo o ponto de entrada do build script. |

### Refatora / muda forma

| Componente | Mudança |
| --- | --- |
| `var.plans` em `platform/local/main.tf:20-41` + valores em `terraform.tfvars` | Continua existindo como **seed inicial**. No startup da API, se a tabela `plans` estiver vazia, lê de um endpoint/configmap exportado por Terraform e popula. Depois disso, CRUD migra pra API. |
| `modules/workload` | Vira **referência viva da spec**. Não é mais instanciado por `platform/<env>`. Pode virar fixture de teste do `WorkloadSynthesizer` (snapshot do que o módulo gerava == output da API). Eventualmente pode ser removido se a paridade ficar comprovada por testes. |
| `platform/local/terraform.tfvars` | Mantém só `plans` (seed). Toda parte `workloads` sai. |

### Novo Terraform a adicionar (Fase 4+)

- `modules/control-plane` — Deployment da API + SA + ClusterRole (CRUD em Namespace/Deployment/ScaledObject/ResourceQuota/LimitRange/NetworkPolicy/ExternalSecret/ServiceAccount/Role/RoleBinding cluster-wide; read em Pod/Event/ConfigMap) + ExternalSecret pro DATABASE_URL + Service ClusterIP + (opcional) Ingress.
- `platform/<env>` instancia `module.control_plane` depois de `core_platform`.

## Fluxo end-to-end (estado-alvo)

1. `terraform apply` em `envs/<env>` → cluster sobe.
2. `terraform apply` em `platform/<env>` → core-platform + dev-secrets store + control-plane API rodando.
3. API faz seed dos plans no Postgres (se vazio).
4. `POST /tenants` → linha no DB.
5. `POST /tenants/:id/workloads` → API valida plan, gera manifests, aplica no cluster, persiste workload no DB.
6. KEDA escala / Prometheus monitora.
7. Admin via API consulta status, métricas, escala, atualiza imagem.
8. `DELETE /workloads/:id` → API escala pra 0, espera drain, deleta recursos, soft-delete no DB.

## Schema de domínio (preview)

```prisma
model Plan {
  id           String   @id @default(cuid())
  key          String   @unique  // "starter", "growth"
  quota        Json     // { "requests.cpu": "2", ... }
  container    Json     // { default_cpu, max_cpu, ... }
  maxReplicas  Int
  workloads    Workload[]
  createdAt    DateTime @default(now())
  updatedAt    DateTime @updatedAt
}

model Tenant {
  id         String   @id @default(cuid())
  slug       String   @unique  // DNS label
  name       String
  workloads  Workload[]
  createdAt  DateTime @default(now())
}

model Workload {
  id                     String   @id @default(cuid())
  appId                  String   // DNS label, unique per tenant
  tenantId               String
  tenant                 Tenant   @relation(fields: [tenantId], references: [id])
  planId                 String
  plan                   Plan     @relation(fields: [planId], references: [id])
  workerImage            String
  minReplicas            Int      @default(0)
  kedaTriggers           Json
  eventSourceEgressRules Json     @default("[]")
  externalSecretRef      Json     // { name, secretStoreName, secretStoreKind }
  credentialsPayload     Json?    // dev-only: o que a API escreve no Secret em dev-secrets ns
  status                 String   @default("pending") // pending | active | draining | deleted
  createdAt              DateTime @default(now())
  updatedAt              DateTime @updatedAt
  @@unique([tenantId, appId])
}
```

## Repo layout (control plane)

```
workerless-control-plane/
├── prisma/
│   ├── schema.prisma
│   └── migrations/
├── src/
│   ├── server.ts                 # Fastify bootstrap
│   ├── routes/
│   │   ├── plans.ts
│   │   ├── tenants.ts
│   │   ├── workloads.ts
│   │   └── health.ts
│   ├── k8s/
│   │   ├── client.ts             # @kubernetes/client-node loader (kubeconfig | in-cluster)
│   │   ├── synthesizer.ts        # workload spec → array de manifests
│   │   └── reconcile.ts          # apply + drain helpers
│   ├── prometheus/
│   │   └── client.ts             # queries pré-canned
│   ├── domain/                   # services entre routes e prisma/k8s
│   │   ├── workloads.service.ts
│   │   ├── plans.service.ts
│   │   └── tenants.service.ts
│   ├── auth/
│   │   └── adminKey.ts
│   └── lib/
│       ├── logger.ts
│       └── errors.ts
├── test/
│   └── synthesizer.spec.ts       # snapshot tests vs output de modules/workload
├── docker-compose.yml            # postgres pra dev
├── .env.example
├── package.json
├── tsconfig.json
└── README.md
```

## Fases de migração

| Fase | Estado |
| --- | --- |
| **0** — Cluster + core-platform + 1 workload placeholder em Terraform | ✅ atual |
| **1** — Scaffold do repo `workerless-control-plane`: Fastify, Prisma, k8s client, schema, CRUD básico (sem aplicar no cluster ainda) | próxima |
| **2** — Implementar `WorkloadSynthesizer` + `POST/PATCH/DELETE /workloads` que efetivamente aplicam no k3d local | |
| **3** — Remover `var.workloads` e `module "workload"` de `platform/local/main.tf`; API passa a ser a única forma de criar workload | |
| **4** — Adicionar `modules/control-plane` e fazer deploy da API in-cluster (via `platform/<env>`) | |
| **5** — Mesmo padrão em `platform/hetzner` (Postgres externo gerenciado, API in-cluster) | |
| **6** — (Opcional) Migrar pra CRD + operator se latência/drift virarem problema sério | |

## Não-objetivos (por agora)

- UI self-service (API primeiro; UI depois consome a API).
- Multi-region.
- CRD/operator (Fase 6+; complexidade não compensa pra 1 cluster, 1 admin).
- Pipeline de build de imagens (usuário traz imagem pronta).
- Substituir Terraform no provisioning físico do cluster (continua Terraform).

## Riscos / pontos abertos

- **Drift DB ↔ cluster.** Alguém com kubectl pode mexer direto no cluster e o DB não saber. Mitigar com Kyverno ClusterPolicy bloqueando edição direta em `wl-*` por SAs que não sejam da API + reconcile loop que flagga drift.
- **Transação distribuída.** Criar workload = INSERT no DB + N applies no k8s. Se k8s falhar no meio, DB fica inconsistente. Padrão: 2-phase — INSERT com status=pending, aplica no k8s, UPDATE para status=active. Em falha: rollback do DB e cleanup best-effort do k8s.
- **Paridade com `modules/workload`.** Mudanças no módulo Terraform têm que ser refletidas no synthesizer. Mitigar com snapshot tests no repo da API que comparam output do synthesizer com `terraform show -json` do módulo.
- **Secrets em dev.** API escreve `credentialsPayload` direto em `dev-secrets` ns. Em prod o backend é Vault e a API só registra o `external_secret_ref` (não toca em credencial). Caminhos diferentes; testar ambos.
- **State store da API.** Postgres em Docker é OK pra dev, mas se o container morrer o DB some. Volume nomeado no compose resolve. Em prod, Postgres gerenciado é mandatório.



⏺ Local (dev): API roda no host (fora do cluster). Sugestão: porta 3000. SDK    
aponta para:
- Do seu código no host: http://localhost:3000
- De dentro de um pod no k3d (se um workload precisar chamar a API):
  http://host.docker.internal:3000

Produção (Hetzner): API roda in-cluster (Fase 4+). Precisa de:
1. Ingress controller (ainda não está em modules/core-platform — adicionar    
   quando chegar a fase).
2. DNS A record pra um domínio teu (ex.: api.workerless.seudominio.com) → IP  
   do LB Hetzner.
3. cert-manager + Let's Encrypt para TLS.

SDK aponta pro domínio que você escolher. Service in-cluster será             
http://control-plane.control-plane.svc.cluster.local:3000 (workloads internos
podem usar isso e pular o ingress).

Você tem domínio? Se sim, fixo api.<seudominio> no doc e na Fase 4 já adiciono
ingress + cert-manager no modules/core-platform.                           
