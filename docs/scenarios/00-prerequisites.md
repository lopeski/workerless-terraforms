# Pré-requisitos — Workerless Platform

Este documento cobre o que precisa estar em pé antes de executar qualquer cenário de deploy.
Todos os cenários partem do estado descrito aqui.

---

## 1. Cluster Kubernetes (v2 Pulumi)

### Local (k3d)

```bash
# Dentro de v2/envs/local
cd v2/envs/local
pulumi stack select local
pulumi up

# Dentro de v2/platform/local
cd v2/platform/local
pulumi stack select local
pulumi up
```

Componentes instalados pela plataforma local:

| Componente | Namespace | Função |
|------------|-----------|--------|
| External Secrets Operator | `external-secrets` | Materializa Secrets de backends externos |
| KEDA | `keda` | Autoscaling orientado a eventos |
| Kyverno | `kyverno` | Pod Security Standards (baseline) |
| kube-prometheus-stack | `monitoring` | Prometheus, Alertmanager, Grafana |
| CoreDNS hardening | `kube-system` | Resolvers Cloudflare anti-malware |
| dev-secrets backend | `dev-secrets` | ClusterSecretStore para desenvolvimento local |

Verificação:

```bash
kubectl --context k3d-local-rock get pods -A
# Todos os pods devem estar Running/Completed
```

### Cloud (Hetzner) — opcional para dev

```bash
export TF_VAR_hcloud_token=<seu_token>

cd v2/envs/hetzner
pulumi stack select hetzner
pulumi up

cd v2/platform/hetzner
pulumi stack select hetzner
pulumi up
```

---

## 2. API de Controle (workerless-control-plane)

O repo da API fica em `/Users/moiseslopes/WebstormProjects/workerless-control-plane`.
Veja `CONTROL_PLANE.md` para o layout e stack recomendados (Fastify + Prisma + @kubernetes/client-node).

### Subir localmente

```bash
cd workerless-control-plane

# Postgres via Docker
docker compose up -d postgres

# Dependências
npm install

# Migrations
npx prisma migrate deploy

# Seed de plans (lê do Pulumi config e popula DB se vazio)
npm run seed

# API na porta 3000
npm run dev
```

Variáveis de ambiente obrigatórias (`.env`):

```env
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/workerless
ADMIN_API_KEY=troca-isso-em-producao
KUBECONFIG=~/.kube/config
KUBE_CONTEXT=k3d-local-rock
```

Verificação:

```bash
curl http://localhost:3000/health
# { "status": "ok" }

curl http://localhost:3000/cluster/health \
  -H "X-Admin-Key: troca-isso-em-producao"
# Retorna readiness de KEDA, ESO, Kyverno, Prometheus
```

---

## 3. Container Registry

Os workloads precisam de uma imagem de container acessível pelo cluster.

### Opção A — GitHub Container Registry (ghcr.io) — recomendado

```bash
# Login local
echo $GITHUB_TOKEN | docker login ghcr.io -u SEU_USUARIO --password-stdin

# Tornar o pacote público (repositório Settings > Packages) ou configurar pull secret
# Para cluster privado, criar ImagePullSecret no namespace do workload
kubectl --context k3d-local-rock create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=SEU_USUARIO \
  --docker-password=$GITHUB_TOKEN \
  -n wl-<tenant>-<appId>
```

### Opção B — Docker Hub

```bash
docker login -u SEU_USUARIO
# Use docker.io/SEU_USUARIO/nome-da-imagem:tag nos payloads da API
```

### Opção C — Harbor in-cluster (avançado)

Harbor pode ser instalado na plataforma como Helm release adicional.
Ainda não está no `modules/core-platform`; adicionar quando necessário.

---

## 4. Criar Tenant

```bash
curl -s -X POST http://localhost:3000/tenants \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: troca-isso-em-producao" \
  -d '{
    "slug": "acme",
    "name": "Acme Corp"
  }' | jq .
```

Resposta esperada:

```json
{
  "id": "clxxxx",
  "slug": "acme",
  "name": "Acme Corp",
  "createdAt": "2026-01-01T00:00:00.000Z"
}
```

Guarde o `id` — você vai precisar dele nos cenários.

Regras de validação para `slug`:
- DNS label: `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
- Máximo 63 caracteres
- Junto com `appId`, o namespace `wl-{slug}-{appId}` também deve ter até 63 caracteres

---

## 5. Criar ou verificar Plan

Os plans são semeados no startup da API a partir do Pulumi config (`v2/platform/local/Pulumi.local.yaml`).
Verifique os plans disponíveis:

```bash
curl -s http://localhost:3000/plans \
  -H "X-Admin-Key: troca-isso-em-producao" | jq .
```

Para criar um plan customizado:

```bash
curl -s -X POST http://localhost:3000/plans \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: troca-isso-em-producao" \
  -d '{
    "key": "starter",
    "quota": {
      "requests.cpu": "200m",
      "requests.memory": "256Mi",
      "limits.cpu": "500m",
      "limits.memory": "512Mi",
      "pods": "5"
    },
    "container": {
      "defaultCpu": "50m",
      "defaultMemory": "64Mi",
      "defaultRequestCpu": "10m",
      "defaultRequestMemory": "16Mi",
      "maxCpu": "100m",
      "maxMemory": "128Mi"
    },
    "maxReplicas": 3
  }' | jq .
```

---

## 6. SecretStore para o workload

Em local, o `ClusterSecretStore` chamado `dev-secrets` já é criado pela plataforma.
Ele lê Kubernetes Secrets nativos do namespace `dev-secrets`.

Crie um Secret dummy com as credenciais do broker (preencha depois):

```bash
kubectl --context k3d-local-rock create secret generic meu-consumer-credentials \
  -n dev-secrets \
  --from-literal=BROKER_URL=amqp://user:pass@localhost:5672 \
  --from-literal=QUEUE_NAME=minha-fila
```

Em produção, o `ClusterSecretStore` aponta para Vault ou AWS Secrets Manager.
Esse Secret nunca passa pelo Terraform nem pela API em cloud.

---

## 7. Checklist final

Antes de avançar para qualquer cenário:

- [ ] `pulumi up` em `v2/envs/local` concluído sem erros
- [ ] `pulumi up` em `v2/platform/local` concluído sem erros
- [ ] `GET /health` retorna `{ "status": "ok" }`
- [ ] `GET /cluster/health` retorna todos os componentes como `ready`
- [ ] Tenant criado e `id` anotado
- [ ] Plan `starter` visível em `GET /plans`
- [ ] Registry configurado e acessível
- [ ] Secret de credenciais do broker criado em `dev-secrets` (local)
