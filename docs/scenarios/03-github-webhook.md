# Cenário 3 — GitHub Webhook (Deploy Automático por Push)

Configura a plataforma para receber eventos de push do GitHub. A cada push na branch
configurada, a plataforma detecta a mudança e faz deploy automático — via build
in-cluster (Kaniko) ou via disparo de um GitHub Actions workflow do repositório.

---

## Visão geral

```
Developer
   │
   │ git push origin main
   ▼
GitHub
   │
   │ POST /webhooks/github  (HMAC-SHA256 assinado)
   ▼
Control Plane API
   │
   ├── Valida assinatura HMAC
   ├── Lookup WebhookRegistration → (tenantId, appId, branch)
   │
   ├── [Modo A] Build in-cluster:
   │     └── Clona repo → Kaniko Job → push para registry
   │
   └── [Modo B] Dispara CI externo:
         └── POST https://api.github.com/repos/:owner/:repo/dispatches
               → GitHub Actions roda build + deploy
   │
   │ POST /tenants/:id/workloads  (1ª vez)
   │ PATCH /workloads/:id         (atualizações)
   ▼
Kubernetes (wl-{tenant}-{app})
   ├── Deployment — rolling update
   └── ScaledObject KEDA
```

**Modo A** (build in-cluster): Plataforma constrói a imagem sozinha. Requer Kaniko
no cluster. Dependência: Fase 3+ da API (`workerless-control-plane`).

**Modo B** (dispatch CI): Plataforma apenas notifica o GitHub Actions para
rodar o workflow de build/deploy existente. Mais simples de implementar.
**Recomendado para começar.**

---

## Pré-requisitos específicos

- [00-prerequisites.md](./00-prerequisites.md) completo.
- Tenant e plan criados.
- **Para Modo A (build in-cluster):** Kaniko disponível no cluster (veja Fase 3 da API).
- **Para Modo B (dispatch CI):** GitHub Actions workflow configurado no repo do usuário
  (veja Passo 6b abaixo), GitHub token com permissão `repo` salvo como secret na API.
- Workload já existente ou será criado no primeiro push.

---

## Setup — passo a passo

### Passo 1 — Registrar o webhook na plataforma

```bash
TENANT_ID="clxxxx"
APP_ID="billing-consumer"

REGISTRATION=$(curl -s -X POST \
  "http://localhost:3000/webhooks/register" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -d "{
    \"tenantId\": \"${TENANT_ID}\",
    \"appId\": \"${APP_ID}\",
    \"repoUrl\": \"https://github.com/minha-org/billing-consumer\",
    \"branch\": \"main\",
    \"buildMode\": \"dispatch\"
  }" | jq .)

echo "$REGISTRATION"

WEBHOOK_ID=$(echo "$REGISTRATION" | jq -r '.id')
WEBHOOK_SECRET=$(echo "$REGISTRATION" | jq -r '.secret')

echo "Webhook ID: ${WEBHOOK_ID}"
echo "Webhook Secret: ${WEBHOOK_SECRET}"
```

> O campo `secret` é retornado **apenas uma vez** nesta resposta.
> Salve-o imediatamente — a API armazena apenas o hash.

Resposta esperada:

```json
{
  "id": "wh_abc123",
  "secret": "whsec_xxxxxxxxxxxxxxxx",
  "webhookUrl": "https://api.workerless.example/webhooks/github",
  "tenantId": "clxxxx",
  "appId": "billing-consumer",
  "repoUrl": "https://github.com/minha-org/billing-consumer",
  "branch": "main",
  "buildMode": "dispatch"
}
```

### Passo 2 — Configurar webhook no GitHub

No repositório do usuário:

1. Acesse: `Settings` → `Webhooks` → `Add webhook`
2. Preencha:
   - **Payload URL:** `https://api.workerless.example/webhooks/github`
     (ou `https://<ngrok-url>/webhooks/github` em desenvolvimento local)
   - **Content type:** `application/json`
   - **Secret:** o valor de `WEBHOOK_SECRET` obtido no Passo 1
   - **Which events:** selecione `Just the push event`
   - **Active:** marcado
3. Clique em `Add webhook`

GitHub vai enviar um ping imediatamente. Verifique nos logs da API:

```bash
# Logs da API local
npm run dev  # observar saída

# Ou em produção
kubectl --context k3d-local-rock logs -n control-plane \
  -l app=control-plane -f | grep webhook
```

### Passo 3 — Criar o workload inicial (primeira vez)

Se o workload ainda não existe, crie-o antes do primeiro push automático:

```bash
curl -s -X POST \
  "http://localhost:3000/tenants/${TENANT_ID}/workloads" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -d '{
    "appId": "billing-consumer",
    "planKey": "starter",
    "workerImage": "ghcr.io/minha-org/billing-consumer:placeholder",
    "minReplicas": 0,
    "externalSecretRef": {
      "name": "billing-consumer-credentials",
      "secretStoreName": "dev-secrets",
      "secretStoreKind": "ClusterSecretStore"
    },
    "eventSourceEgressRules": [
      {
        "cidr": "203.0.113.20/32",
        "ports": [{ "port": 9092, "protocol": "TCP" }]
      }
    ],
    "kedaTriggers": [
      {
        "type": "kafka",
        "metadata": {
          "bootstrapServers": "203.0.113.20:9092",
          "consumerGroup": "billing-group",
          "topic": "billing-events",
          "lagThreshold": "20"
        }
      }
    ]
  }' | jq .
```

> A imagem `placeholder` será substituída automaticamente no primeiro push.

### Passo 4 — Testar o webhook com push local

```bash
git commit --allow-empty -m "test: trigger webhook"
git push origin main
```

Observe nos logs da API:

```
[webhook] Received push event from github.com/minha-org/billing-consumer
[webhook] Branch: refs/heads/main — matched registration wh_abc123
[webhook] HMAC validated OK
[webhook] Dispatching build for tenant=acme app=billing-consumer
```

### Passo 5a — Modo A: Build in-cluster (Kaniko)

A API clona o repositório via HTTPS (usando `GITHUB_APP_TOKEN` ou deploy key),
lança um Kaniko Job e aguarda conclusão:

```bash
# Monitorar build jobs no cluster
kubectl --context k3d-local-rock get jobs -n build-system -w
```

Quando concluído, a API faz PATCH no workload com a nova imagem.

> Requer credenciais de acesso ao repositório na API.
> Adicione como secret: `GITHUB_CLONE_TOKEN` no `.env` da API.

### Passo 5b — Modo B: Dispatch para GitHub Actions (recomendado)

A API envia um `repository_dispatch` event para o GitHub:

```bash
# O que a API faz internamente:
curl -s -X POST \
  "https://api.github.com/repos/minha-org/billing-consumer/dispatches" \
  -H "Authorization: token ${GITHUB_DISPATCH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "workerless-deploy",
    "client_payload": {
      "workload_id": "wl_xxx",
      "tenant_id": "clxxxx",
      "app_id": "billing-consumer",
      "sha": "a1b2c3d4"
    }
  }'
```

No repositório do usuário, crie `.github/workflows/workerless-deploy.yml`:

```yaml
name: Workerless Deploy

on:
  repository_dispatch:
    types: [workerless-deploy]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.client_payload.sha }}

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.event.client_payload.sha }}

      - name: Update platform workload
        run: |
          IMAGE="${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.event.client_payload.sha }}"
          curl -s -X PATCH \
            "${{ secrets.PLATFORM_API_URL }}/workloads/${{ github.event.client_payload.workload_id }}" \
            -H "Content-Type: application/json" \
            -H "X-Admin-Key: ${{ secrets.PLATFORM_API_KEY }}" \
            -d "{\"workerImage\": \"${IMAGE}\"}"
```

Adicione nos secrets do repositório GitHub:
- `PLATFORM_API_URL`
- `PLATFORM_API_KEY`

### Passo 6 — Verificar deploy automático

```bash
# Status do workload
curl -s "http://localhost:3000/workloads/${WORKLOAD_ID}/status" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" | jq .

# Pods no cluster
kubectl --context k3d-local-rock get pods -n wl-acme-billing-consumer -w
```

---

## Atualização — passo a passo

Após o setup inicial, toda atualização é automática:

1. Developer faz alteração no código
2. `git commit -m "feat: ..."`
3. `git push origin main`
4. GitHub envia webhook para a plataforma
5. Plataforma valida HMAC e identifica o workload
6. **Modo A:** Kaniko reconstrói e faz push da nova imagem
   **Modo B:** `repository_dispatch` dispara GitHub Actions
7. Após nova imagem disponível, API faz `PATCH /workloads/:id`
8. Kubernetes faz rolling update
9. KEDA continua escalando normalmente

Não é necessária nenhuma ação manual após o setup.

---

## Atualizar configuração do webhook

Para mudar a branch monitorada ou o modo de build:

```bash
curl -s -X PATCH \
  "http://localhost:3000/webhooks/${WEBHOOK_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -d '{
    "branch": "production",
    "buildMode": "kaniko"
  }' | jq .
```

Para rotacionar o secret do webhook:

```bash
NEW_SECRET=$(curl -s -X POST \
  "http://localhost:3000/webhooks/${WEBHOOK_ID}/rotate-secret" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" | jq -r '.secret')

echo "Novo secret: ${NEW_SECRET}"
# Atualize no GitHub: Settings > Webhooks > editar o webhook > novo secret
```

---

## Rollback

### Via API

```bash
PREVIOUS_IMAGE="ghcr.io/minha-org/billing-consumer:sha-a1b2c3d"

curl -s -X PATCH "http://localhost:3000/workloads/${WORKLOAD_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -d "{\"workerImage\": \"${PREVIOUS_IMAGE}\"}" | jq .
```

### Reverter o commit no Git e triggerar re-deploy

```bash
git revert HEAD --no-edit
git push origin main
# Webhook dispara → build + deploy da versão anterior
```

### Pausar o webhook temporariamente

No GitHub: `Settings > Webhooks > editar > desmarcar Active`.

Ou via API:

```bash
curl -s -X PATCH "http://localhost:3000/webhooks/${WEBHOOK_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -d '{"active": false}' | jq .
```

---

## Modelo de dados do webhook (referência para implementação da API)

```prisma
model WebhookRegistration {
  id          String   @id @default(cuid())
  repoUrl     String
  branch      String   @default("main")
  tenantId    String
  appId       String
  workloadId  String?
  buildMode   String   @default("dispatch")  // "dispatch" | "kaniko"
  secretHash  String   // bcrypt do webhook secret
  active      Boolean  @default(true)
  createdAt   DateTime @default(now())
  updatedAt   DateTime @updatedAt
  @@unique([repoUrl, branch])
}
```

Endpoints novos necessários na API (`workerless-control-plane`):

| Método | Rota | Função |
|--------|------|--------|
| `POST` | `/webhooks/register` | Registra mapeamento repo → workload |
| `POST` | `/webhooks/github` | Recebe eventos do GitHub (validação HMAC) |
| `GET` | `/webhooks` | Lista registrations |
| `PATCH` | `/webhooks/:id` | Atualiza branch, buildMode, active |
| `DELETE` | `/webhooks/:id` | Remove registration |
| `POST` | `/webhooks/:id/rotate-secret` | Gera novo secret e retorna para reconfiguração |

Lógica de validação HMAC no handler:

```typescript
// src/routes/webhooks.ts (esboço)
import crypto from "crypto";

function verifyGithubSignature(
  payload: string,
  signature: string,
  secret: string
): boolean {
  const expected = `sha256=${crypto
    .createHmac("sha256", secret)
    .update(payload)
    .digest("hex")}`;
  return crypto.timingSafeEqual(
    Buffer.from(signature),
    Buffer.from(expected)
  );
}
```

---

## Troubleshooting

### GitHub mostra "Recent Deliveries" com status vermelho

Clique na entrega com erro e veja a resposta. Causas comuns:

| HTTP retornado | Causa |
|---------------|-------|
| 401 | Assinatura HMAC inválida — secret diverge |
| 404 | URL do webhook está incorreta |
| 500 | Erro interno na API — ver logs |

Verificar logs em desenvolvimento:

```bash
npm run dev  # observar a saída para cada entrega
```

### Webhook chega mas workload não atualiza

```bash
# Ver eventos no workload
curl -s "http://localhost:3000/workloads/${WORKLOAD_ID}/events" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" | jq .
```

Causas comuns:
- `WebhookRegistration.workloadId` não aponta para o workload correto
  → verificar via `GET /webhooks`
- Branch configurada no registro difere da branch do push
  → confirmar com `GET /webhooks/:id`

### Modo Dispatch: GitHub Actions não dispara

- Verificar se `GITHUB_DISPATCH_TOKEN` na API tem permissão `repo`
- Verificar se o workflow tem `on: repository_dispatch` com o event_type correto
- No GitHub: `Actions > Workflows` — o workflow deve aparecer como habilitado

### Modo Kaniko: build falha por acesso negado ao repositório

```bash
# Logs do Job Kaniko no namespace build-system
kubectl --context k3d-local-rock logs -n build-system \
  -l app=kaniko-build -c kaniko
```

A API precisa de um `GITHUB_CLONE_TOKEN` com permissão `contents: read`
para clonar o repositório. Em repos privados, adicione como deploy key
ou use um GitHub App token.

### Assinatura HMAC falha após `rotate-secret`

O secret no GitHub ainda usa o valor antigo.
Atualize imediatamente após a rotação: `GitHub > Settings > Webhooks > editar`.
O GitHub não invalida as entregas em fila com o secret antigo — apenas as
próximas usam o novo secret.
