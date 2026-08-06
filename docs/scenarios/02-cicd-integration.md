# Cenário 2 — Integração CI/CD

O pipeline de CI do usuário constrói a imagem Docker, faz push para o registry e
chama a API da plataforma para criar ou atualizar o workload. A plataforma não
precisa ter acesso ao código-fonte — só recebe a referência da imagem já construída.

Este é o cenário mais simples e o recomendado para times que já têm CI configurado.

---

## Visão geral

```
Developer
   │
   │ git push
   ▼
CI Pipeline (GitHub Actions / GitLab CI / Jenkins / qualquer CI)
   │
   ├── 1. docker build -t ghcr.io/org/app:$SHA .
   ├── 2. docker push ghcr.io/org/app:$SHA
   │
   │ 3a. workload não existe → POST /tenants/:id/workloads
   │ 3b. workload existe     → PATCH /workloads/:id { workerImage }
   ▼
Control Plane API
   │
   │ 4. Aplica recursos Kubernetes
   ▼
Kubernetes (wl-{tenant}-{app})
   ├── Deployment — rolling update para nova imagem
   └── ScaledObject KEDA — autoscaling pelo broker
```

---

## Pré-requisitos específicos

- [00-prerequisites.md](./00-prerequisites.md) completo.
- Tenant e plan já criados.
- `WORKLOAD_ID` disponível se for atualização (obtido no primeiro deploy).
- Secrets configurados no CI: `PLATFORM_API_KEY`, `REGISTRY_TOKEN`.

---

## Deploy inicial — passo a passo

### Passo 1 — Criar o workload manualmente (primeira vez)

Antes de automatizar, crie o workload via curl para obter o `WORKLOAD_ID`
que o CI vai usar nas atualizações:

```bash
TENANT_ID="clxxxx"
APP_ID="orders-consumer"
IMAGE="ghcr.io/minha-org/orders-consumer:sha-a1b2c3d"

WORKLOAD_ID=$(curl -s -X POST \
  "http://localhost:3000/tenants/${TENANT_ID}/workloads" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -d "{
    \"appId\": \"${APP_ID}\",
    \"planKey\": \"starter\",
    \"workerImage\": \"${IMAGE}\",
    \"minReplicas\": 0,
    \"externalSecretRef\": {
      \"name\": \"orders-consumer-credentials\",
      \"secretStoreName\": \"dev-secrets\",
      \"secretStoreKind\": \"ClusterSecretStore\"
    },
    \"eventSourceEgressRules\": [
      {
        \"cidr\": \"203.0.113.10/32\",
        \"ports\": [{ \"port\": 5671, \"protocol\": \"TCP\" }]
      }
    ],
    \"kedaTriggers\": [
      {
        \"type\": \"rabbitmq\",
        \"metadata\": {
          \"protocol\": \"amqp\",
          \"queueName\": \"orders\",
          \"mode\": \"QueueLength\",
          \"value\": \"30\",
          \"activationValue\": \"5\",
          \"host\": \"BROKER_URL\"
        }
      }
    ]
  }" | jq -r '.id')

echo "WORKLOAD_ID=${WORKLOAD_ID}"
```

Salve `WORKLOAD_ID` como secret no CI (`PLATFORM_WORKLOAD_ID`).

### Passo 2 — Configurar secrets no CI

No GitHub (Settings > Secrets and Variables > Actions):

| Secret | Valor |
|--------|-------|
| `PLATFORM_API_URL` | `https://api.workerless.example` (ou `http://localhost:3000` em dev) |
| `PLATFORM_API_KEY` | Valor de `ADMIN_API_KEY` |
| `PLATFORM_WORKLOAD_ID` | `id` do workload obtido no Passo 1 |
| `REGISTRY_TOKEN` | Token do GitHub para push em `ghcr.io` |

### Passo 3 — Configurar o workflow de CI

#### GitHub Actions

Arquivo `.github/workflows/deploy.yml`:

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]

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

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.REGISTRY_TOKEN }}

      - name: Build and push Docker image
        id: build
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
          labels: |
            org.opencontainers.image.revision=${{ github.sha }}

      - name: Update workload on platform
        run: |
          IMAGE="${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}"
          echo "Deploying image: ${IMAGE}"

          RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH \
            "${{ secrets.PLATFORM_API_URL }}/workloads/${{ secrets.PLATFORM_WORKLOAD_ID }}" \
            -H "Content-Type: application/json" \
            -H "X-Admin-Key: ${{ secrets.PLATFORM_API_KEY }}" \
            -d "{\"workerImage\": \"${IMAGE}\"}")

          HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
          BODY=$(echo "$RESPONSE" | head -n-1)

          echo "Response: ${BODY}"

          if [ "$HTTP_CODE" -ne 200 ]; then
            echo "Deploy failed with HTTP $HTTP_CODE"
            exit 1
          fi

      - name: Wait for rollout
        run: |
          # Polling de status por até 3 minutos
          for i in $(seq 1 18); do
            STATUS=$(curl -s \
              "${{ secrets.PLATFORM_API_URL }}/workloads/${{ secrets.PLATFORM_WORKLOAD_ID }}/status" \
              -H "X-Admin-Key: ${{ secrets.PLATFORM_API_KEY }}" | jq -r '.status')
            echo "Status: ${STATUS} (attempt ${i}/18)"
            if [ "$STATUS" = "active" ]; then
              echo "Deploy successful"
              exit 0
            fi
            sleep 10
          done
          echo "Deploy timed out"
          exit 1
```

#### GitLab CI

Arquivo `.gitlab-ci.yml`:

```yaml
stages:
  - build
  - deploy

variables:
  IMAGE_TAG: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA

build:
  stage: build
  image: docker:24
  services:
    - docker:24-dind
  before_script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
  script:
    - docker build -t $IMAGE_TAG .
    - docker push $IMAGE_TAG
  only:
    - main

deploy:
  stage: deploy
  image: curlimages/curl:latest
  script:
    - |
      RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH \
        "${PLATFORM_API_URL}/workloads/${PLATFORM_WORKLOAD_ID}" \
        -H "Content-Type: application/json" \
        -H "X-Admin-Key: ${PLATFORM_API_KEY}" \
        -d "{\"workerImage\": \"${IMAGE_TAG}\"}")
      HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
      [ "$HTTP_CODE" -eq 200 ] || exit 1
  only:
    - main
```

#### Script curl genérico (qualquer CI)

```bash
#!/bin/bash
# deploy.sh — executar no passo de deploy do CI
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG obrigatório}"
WORKLOAD_ID="${PLATFORM_WORKLOAD_ID:?PLATFORM_WORKLOAD_ID obrigatório}"
API_URL="${PLATFORM_API_URL:?PLATFORM_API_URL obrigatório}"
API_KEY="${PLATFORM_API_KEY:?PLATFORM_API_KEY obrigatório}"

echo "Deploying ${IMAGE_TAG} to workload ${WORKLOAD_ID}..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
  "${API_URL}/workloads/${WORKLOAD_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${API_KEY}" \
  -d "{\"workerImage\": \"${IMAGE_TAG}\"}")

if [ "$HTTP_CODE" -ne 200 ]; then
  echo "Deploy failed: HTTP ${HTTP_CODE}"
  exit 1
fi

echo "Deploy triggered. Checking status..."
for i in $(seq 1 18); do
  STATUS=$(curl -s "${API_URL}/workloads/${WORKLOAD_ID}/status" \
    -H "X-Admin-Key: ${API_KEY}" | jq -r '.status')
  [ "$STATUS" = "active" ] && echo "Active." && exit 0
  echo "  [${i}/18] status=${STATUS}, waiting..."
  sleep 10
done
echo "Timeout waiting for active status"
exit 1
```

### Passo 4 — Verificar o deploy

```bash
# Status do workload
curl -s "http://localhost:3000/workloads/${WORKLOAD_ID}/status" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" | jq .

# Pods no cluster
kubectl --context k3d-local-rock get pods -n wl-acme-orders-consumer
```

---

## Atualização — passo a passo

Em push subsequentes, o pipeline já executa o PATCH automaticamente.
O fluxo é:

1. Developer faz `git push origin main`
2. CI dispara automaticamente
3. `docker build` + `docker push` com nova SHA
4. `PATCH /workloads/:id { workerImage: "...:<novaShA>" }`
5. Kubernetes faz rolling update
6. Pods antigos terminam após novos estarem Ready

Não é necessária nenhuma ação manual após o setup inicial.

### Alterar outras propriedades do workload

Para mudar plan, triggers KEDA ou regras de egress, faça PATCH diretamente:

```bash
# Mudar plan
curl -s -X PATCH "http://localhost:3000/workloads/${WORKLOAD_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -d '{"planKey": "growth"}' | jq .

# Mudar triggers KEDA
curl -s -X PATCH "http://localhost:3000/workloads/${WORKLOAD_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -d '{
    "kedaTriggers": [
      {
        "type": "rabbitmq",
        "metadata": {
          "protocol": "amqp",
          "queueName": "orders",
          "mode": "QueueLength",
          "value": "50",
          "activationValue": "10",
          "host": "BROKER_URL"
        }
      }
    ]
  }' | jq .
```

Campos que podem ser atualizados via PATCH:

| Campo | Ação Kubernetes |
|-------|----------------|
| `workerImage` | Patch no Deployment (rolling update) |
| `planKey` | Patch ResourceQuota, LimitRange, Deployment resources, ScaledObject maxReplicas |
| `minReplicas` | Patch ScaledObject minReplicaCount |
| `kedaTriggers` | Patch ScaledObject triggers |
| `eventSourceEgressRules` | Patch NetworkPolicies do workload e do namespace keda |
| `externalSecretRef` | Patch ExternalSecret |

---

## Rollback

### Via API (recomendado)

Passe a tag da imagem anterior diretamente:

```bash
PREVIOUS_TAG="ghcr.io/minha-org/orders-consumer:sha-a1b2c3d"

curl -s -X PATCH "http://localhost:3000/workloads/${WORKLOAD_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -d "{\"workerImage\": \"${PREVIOUS_TAG}\"}" | jq .
```

### Via kubectl (emergência)

```bash
kubectl --context k3d-local-rock rollout undo \
  deployment/orders-consumer -n wl-acme-orders-consumer
```

> kubectl undo não atualiza o DB da API. Faça o patch via API para sincronizar.

### Listar imagens disponíveis no registry

```bash
# GitHub Container Registry
gh api /user/packages/container/orders-consumer/versions | \
  jq '.[] | {id: .id, tags: .metadata.container.tags, created: .created_at}'
```

---

## Troubleshooting

### CI retorna HTTP 401

```
HTTP 401 Unauthorized
```

Verifique o secret `PLATFORM_API_KEY` — deve coincidir exatamente com o `ADMIN_API_KEY`
da API. Sem espaços ou quebras de linha.

### CI retorna HTTP 404 em PATCH

O `WORKLOAD_ID` está incorreto ou o workload foi deletado. Consulte:

```bash
curl -s "http://localhost:3000/workloads" \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" | jq '.[].id'
```

### Rollout fica em "Waiting" indefinidamente

```bash
kubectl --context k3d-local-rock describe deployment orders-consumer \
  -n wl-acme-orders-consumer
# Procure por "FailedCreate", "Insufficient resources", "ImagePullBackOff"
```

Causas comuns:
- Imagem não existe no registry ou credenciais inválidas
- Namespace sem recursos disponíveis (ResourceQuota esgotada)
- Kyverno bloqueando pod (violação PSS baseline)

### Kyverno bloqueia o deploy

```bash
kubectl --context k3d-local-rock get events -n wl-acme-orders-consumer \
  --sort-by='.lastTimestamp' | grep -i kyverno
```

O Deployment deve satisfazer PSS baseline:
- `runAsNonRoot: true`
- `readOnlyRootFilesystem: true`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`

Esses campos são injetados pela API automaticamente ao criar o workload.
Se o pod foi criado manualmente, verificar o manifesto.
