# Cenário 1 — Deploy por ZIP

Deploy de uma aplicação consumer a partir de um arquivo ZIP contendo o código-fonte
e um `Dockerfile`. A plataforma constrói a imagem em cluster usando Kaniko e faz o deploy
sem expor o código fora do ambiente.

> **Fase de implementação:** Este cenário depende do componente de build (Fase 3+
> da API — veja `CONTROL_PLANE.md`). Os endpoints `/build` e `/builds/:id`
> precisam ser construídos no repo `workerless-control-plane`.

---

## Visão geral

```
Developer
   │
   │ 1. POST /tenants/:id/workloads/:appId/build  (ZIP multipart)
   ▼
Control Plane API
   │
   │ 2. Cria PVC + copia ZIP → lança Kaniko Job no namespace build-system
   ▼
Kaniko Job (in-cluster, sem docker daemon, PSS-baseline compliant)
   │
   │ 3. docker build → docker push
   ▼
Internal Registry (10.43.100.100:5000)
   │
   │ 4. image tag (SHA) retornado ao polling da API
   ▼
Control Plane API
   │
   │ 5. POST /tenants/:id/workloads (1ª vez)
   │    ou PATCH /workloads/:id    (atualização)
   ▼
Kubernetes
   ├── Namespace wl-{tenant}-{app}
   ├── Deployment (rolling update)
   └── ScaledObject KEDA → autoscaling pelo broker
```

---

## Pré-requisitos específicos

- [00-prerequisites.md](./00-prerequisites.md) completo.
- Cluster com namespace `build-system` criado pelo `modules/core-platform`.
- Registry interno criado pelo `modules/core-platform`, acessível apenas dentro do
  cluster em `10.43.100.100:5000`.
- Neste primeiro corte o registry não tem autenticação, NodePort ou Ingress. O
  Kaniko Job deve fazer push usando HTTP interno, por exemplo com
  `--insecure-registry 10.43.100.100:5000`.
- Seu projeto deve conter um `Dockerfile` na raiz do ZIP.

Estrutura mínima do ZIP:

```
meu-consumer.zip
├── Dockerfile          # obrigatório
├── package.json        # ou go.mod, requirements.txt, etc.
└── src/
    └── index.js
```

Exemplo de `Dockerfile` compatível com PSS baseline (não-root, sem privilégios):

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY src/ ./src/
USER 1000
EXPOSE 3000
CMD ["node", "src/index.js"]
```

---

## Deploy inicial — passo a passo

### Passo 1 — Preparar o ZIP

```bash
# Na raiz do projeto do usuário
zip -r meu-consumer.zip . -x "*.git*" -x "node_modules/*" -x ".env"
```

### Passo 2 — Iniciar o build

```bash
TENANT_ID="clxxxx"       # id obtido em 00-prerequisites.md
APP_ID="meu-consumer"    # DNS label: ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$
REGISTRY="10.43.100.100:5000/workerless/${TENANT_ID}/${APP_ID}"

curl -s -X POST \
  "http://localhost:3000/tenants/${TENANT_ID}/workloads/${APP_ID}/build" \
  -H "X-Admin-Key: troca-isso-em-producao" \
  -F "source=@meu-consumer.zip" \
  -F "registry=${REGISTRY}" | jq .
```

Resposta:

```json
{
  "buildId": "bld_xyz",
  "status": "pending",
  "startedAt": "2026-01-01T00:00:00.000Z"
}
```

### Passo 3 — Aguardar conclusão do build

```bash
BUILD_ID="bld_xyz"

watch -n 5 "curl -s http://localhost:3000/builds/${BUILD_ID} \
  -H 'X-Admin-Key: troca-isso-em-producao' | jq '{status, imageTag, logs}'"
```

Quando `status` for `success`, o campo `imageTag` conterá a referência completa:

```json
{
  "status": "success",
  "imageTag": "10.43.100.100:5000/workerless/clxxxx/meu-consumer:sha-a1b2c3d",
  "finishedAt": "2026-01-01T00:05:00.000Z"
}
```

### Passo 4 — Criar o workload

```bash
IMAGE_TAG="10.43.100.100:5000/workerless/clxxxx/meu-consumer:sha-a1b2c3d"

curl -s -X POST \
  "http://localhost:3000/tenants/${TENANT_ID}/workloads" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: troca-isso-em-producao" \
  -d "{
    \"appId\": \"${APP_ID}\",
    \"planKey\": \"starter\",
    \"workerImage\": \"${IMAGE_TAG}\",
    \"minReplicas\": 0,
    \"externalSecretRef\": {
      \"name\": \"meu-consumer-credentials\",
      \"secretStoreName\": \"dev-secrets\",
      \"secretStoreKind\": \"ClusterSecretStore\"
    },
    \"eventSourceEgressRules\": [
      {
        \"cidr\": \"203.0.113.10/32\",
        \"ports\": [{ \"port\": 5672, \"protocol\": \"TCP\" }]
      }
    ],
    \"kedaTriggers\": [
      {
        \"type\": \"rabbitmq\",
        \"metadata\": {
          \"protocol\": \"amqp\",
          \"queueName\": \"minha-fila\",
          \"mode\": \"QueueLength\",
          \"value\": \"10\",
          \"activationValue\": \"1\",
          \"host\": \"BROKER_URL\"
        }
      }
    ]
  }" | jq .
```

Guarde o `id` retornado — `WORKLOAD_ID`.

### Passo 5 — Verificar criação dos recursos Kubernetes

```bash
NAMESPACE="wl-acme-meu-consumer"

kubectl --context k3d-local-rock get all -n ${NAMESPACE}
# Deployment, ReplicaSet, Pod(s), ScaledObject
```

### Passo 6 — Verificar status via API

```bash
curl -s "http://localhost:3000/workloads/${WORKLOAD_ID}/status" \
  -H "X-Admin-Key: troca-isso-em-producao" | jq .
```

Esperado quando broker tem mensagens:

```json
{
  "namespace": "wl-acme-meu-consumer",
  "desiredReplicas": 1,
  "readyReplicas": 1,
  "kedaActive": true
}
```

### Passo 7 — Verificar logs

```bash
curl -s "http://localhost:3000/workloads/${WORKLOAD_ID}/logs" \
  -H "X-Admin-Key: troca-isso-em-producao"
```

---

## Atualização — passo a passo

Quando o código do consumer muda, repita o ciclo de build e faça patch apenas na imagem.

### Passo 1 — Gerar novo ZIP com o código atualizado

```bash
zip -r meu-consumer-v2.zip . -x "*.git*" -x "node_modules/*" -x ".env"
```

### Passo 2 — Iniciar novo build

```bash
curl -s -X POST \
  "http://localhost:3000/tenants/${TENANT_ID}/workloads/${APP_ID}/build" \
  -H "X-Admin-Key: troca-isso-em-producao" \
  -F "source=@meu-consumer-v2.zip" \
  -F "registry=${REGISTRY}" | jq .
```

### Passo 3 — Aguardar novo `imageTag`

Mesmo fluxo do Passo 3 do deploy inicial. Aguarde `status: success`.

### Passo 4 — Atualizar workload (rolling update)

```bash
NEW_IMAGE="10.43.100.100:5000/workerless/clxxxx/meu-consumer:sha-e5f6g7h"

curl -s -X PATCH \
  "http://localhost:3000/workloads/${WORKLOAD_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: troca-isso-em-producao" \
  -d "{
    \"workerImage\": \"${NEW_IMAGE}\"
  }" | jq .
```

O Kubernetes faz rolling update: novos pods com a nova imagem sobem antes dos antigos terminarem.
Zero downtime se `minReplicas >= 1`.

### Passo 5 — Confirmar que a atualização está completa

```bash
kubectl --context k3d-local-rock rollout status \
  deployment/${APP_ID} -n wl-acme-meu-consumer
# Waiting for deployment "meu-consumer" rollout to finish...
# deployment "meu-consumer" successfully rolled out
```

---

## Rollback

Reverte para uma tag de imagem anterior sem reconstruir:

```bash
PREVIOUS_IMAGE="10.43.100.100:5000/workerless/clxxxx/meu-consumer:sha-a1b2c3d"

curl -s -X PATCH \
  "http://localhost:3000/workloads/${WORKLOAD_ID}" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: troca-isso-em-producao" \
  -d "{
    \"workerImage\": \"${PREVIOUS_IMAGE}\"
  }" | jq .
```

Para rollback de emergência direto no cluster (sem passar pela API):

```bash
kubectl --context k3d-local-rock set image \
  deployment/meu-consumer \
  meu-consumer=${PREVIOUS_IMAGE} \
  -n wl-acme-meu-consumer
```

> A API detectará drift na próxima reconciliação e reportará divergência entre
> DB e cluster. Faça o patch via API para sincronizar o estado.

---

## Troubleshooting

### Build falha: "Dockerfile not found"

O ZIP deve ter o `Dockerfile` na raiz (não em subpastas).

```bash
unzip -l meu-consumer.zip | grep Dockerfile
# Esperado: Dockerfile  (sem path prefix)
```

### Build falha: "permission denied" no Kaniko

O Kaniko Job usa UID não-root. Certifique-se de que o `Dockerfile` não tenta
escrever em diretórios do sistema.

```bash
# Verificar logs do Job Kaniko
kubectl --context k3d-local-rock logs -n build-system \
  -l build-id=bld_xyz
```

### Pod não sobe: "ImagePullBackOff"

O cluster não consegue baixar a imagem do registry interno.

```bash
kubectl --context k3d-local-rock describe pod \
  -n wl-acme-meu-consumer -l app=meu-consumer
# Procure por "Failed to pull image"

# Verificar se o registry interno está pronto
kubectl --context k3d-local-rock get deploy,svc,pvc -n build-system
```

### KEDA não escala: "ScaledObject not ready"

```bash
kubectl --context k3d-local-rock describe scaledobject \
  meu-consumer-scaledobject -n wl-acme-meu-consumer
# Verificar "Active Triggers" e "Conditions"
```

Causa comum: `BROKER_URL` no Secret do workload está incorreto ou o CIDR
de egress não cobre o broker.

### ExternalSecret não materializa o Secret

```bash
kubectl --context k3d-local-rock get externalsecret \
  meu-consumer-credentials -n wl-acme-meu-consumer -o yaml
# Verificar campo "status.conditions"
```

Causa comum em local: Secret em `dev-secrets` não foi criado. Veja
[00-prerequisites.md](./00-prerequisites.md) Seção 6.
