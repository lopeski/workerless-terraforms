# Permissoes RBAC do control-plane da PaaS

Este documento registra as permissoes Kubernetes necessarias para o service account
`system:serviceaccount:kube-system:paas-admin-sa`, usado pela API Workerless para
provisionar apps, executar builds e operar workloads no cluster.

Fonte de verdade no Terraform:

- `modules/core-platform/main.tf`
- resource `kubernetes_cluster_role_v1.paas_control_plane`
- binding `kubernetes_cluster_role_binding_v1.paas_admin_binding`

## Sintoma comum

Quando a API cria o namespace do app, mas nenhum `Job`, `Deployment` ou pod aparece
depois, verifique primeiro se o `paas-admin-sa` recebeu `403 Forbidden`.

Exemplo real:

```text
jobs.batch "build-dpl..." is forbidden:
User "system:serviceaccount:kube-system:paas-admin-sa" cannot patch resource "jobs"
in API group "batch" in the namespace "wl-..."
```

Esse erro acontece porque a API usa server-side apply para alguns manifests. Na pratica,
alem de `create`, ela precisa de `patch` no recurso aplicado.

## Matriz de permissoes

| API group | Resources | Verbs | Uso |
| --- | --- | --- | --- |
| `""` | `namespaces` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Criar e gerenciar namespaces de tenant/app. |
| `""` | `serviceaccounts`, `secrets`, `resourcequotas`, `limitranges` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Criar identidade do workload, segredos, quotas e limites do namespace. |
| `""` | `configmaps`, `pods`, `pods/log`, `events` | `get`, `list`, `watch` | Ler estado, logs e eventos para diagnostico e tela operacional. |
| `events.k8s.io` | `events` | `get`, `list`, `watch` | Ler eventos Kubernetes novos, alem do core/v1 events. |
| `apps` | `deployments` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Criar, atualizar, observar e remover o consumidor. |
| `apps` | `deployments/scale` | `get`, `update`, `patch` | Pausar, retomar, reiniciar e ajustar replicas. |
| `batch` | `jobs` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Criar e acompanhar Jobs de build dos fluxos legado e v2. |
| `autoscaling` | `horizontalpodautoscalers` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Compatibilidade com autoscaling nativo quando usado. |
| `networking.k8s.io` | `networkpolicies` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Aplicar isolamento e egress permitido por workload. |
| `external-secrets.io` | `externalsecrets`, `externalsecrets/status` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Materializar credenciais do workload via External Secrets Operator. |
| `external-secrets.io` | `secretstores`, `clustersecretstores` | `get`, `list`, `watch` | Validar stores usados pelos `ExternalSecret`. |
| `keda.sh` | `scaledobjects`, `scaledobjects/status`, `triggerauthentications` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Criar e operar autoscaling KEDA por broker. |
| `monitoring.coreos.com` | `podmonitors`, `servicemonitors` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Expor metricas de workloads para Prometheus quando habilitado. |
| `rbac.authorization.k8s.io` | `roles`, `rolebindings` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Criar RBAC namespaced quando o workload precisar de permissao propria. |

## Checklist de diagnostico

Identificar o contexto e o namespace:

```bash
kubectl config current-context
kubectl get ns | grep '^wl-'
```

Conferir o estado do namespace do app:

```bash
kubectl get all -n <namespace>
kubectl get events -n <namespace> --sort-by=.lastTimestamp
```

Testar a permissao exata que falhou:

```bash
kubectl auth can-i patch jobs.batch \
  -n <namespace> \
  --as=system:serviceaccount:kube-system:paas-admin-sa
```

Validar as permissoes principais do fluxo de deploy:

```bash
kubectl auth can-i create namespaces \
  --as=system:serviceaccount:kube-system:paas-admin-sa

kubectl auth can-i create jobs.batch \
  -n <namespace> \
  --as=system:serviceaccount:kube-system:paas-admin-sa

kubectl auth can-i patch jobs.batch \
  -n <namespace> \
  --as=system:serviceaccount:kube-system:paas-admin-sa

kubectl auth can-i patch deployments.apps \
  -n <namespace> \
  --as=system:serviceaccount:kube-system:paas-admin-sa

kubectl auth can-i patch scaledobjects.keda.sh \
  -n <namespace> \
  --as=system:serviceaccount:kube-system:paas-admin-sa
```

Inspecionar o ClusterRole aplicado:

```bash
kubectl get clusterrole paas-control-plane -o yaml
kubectl get clusterrolebinding paas-admin-binding -o yaml
```

## Como corrigir

Nao corrigir apenas com `kubectl edit`, porque a mudanca se perde no proximo apply.
Adicione ou ajuste a regra em `modules/core-platform/main.tf`, valide e aplique pelo
entrypoint do ambiente.

Para ambiente local:

```bash
cd platform/local
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Se existir drift fora do problema investigado e for necessario destravar somente RBAC,
aplique temporariamente com target no ClusterRole:

```bash
terraform apply \
  -target=module.core_platform.kubernetes_cluster_role_v1.paas_control_plane \
  -auto-approve
```

Depois rode um `terraform plan` normal para revisar qualquer mudanca pendente que ficou
fora do target.

## Observacoes importantes

- Server-side apply exige `patch`; para recursos aplicados pela API, `create` sozinho
  nao basta.
- O deploy por upload legado e o deploy v2 criam `batch/v1 Job` para build, entao ambos
  dependem de `batch/jobs`.
- Namespace criado e vazio normalmente indica falha depois de `namespaces` e antes de
  `jobs`/`deployments`.
- Logs persistidos pela API podem confirmar a causa exata no Mongo (`deploy_logs`) ou no
  Redis (`deploy:v2:*`), dependendo do fluxo usado.
