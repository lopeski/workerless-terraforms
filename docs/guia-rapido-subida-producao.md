# Subida completa do Workerless em produção

Este é o runbook canônico para a primeira implantação e para mudanças planejadas
do Workerless em produção. Ele coordena três repositórios:

- `workerless-terraforms`: cluster k3s na Hetzner e plataforma Kubernetes;
- `workerless-api`: dados gerenciados, Cloudflare Tunnel, Access e API em
  Cloudflare Workers/Containers;
- `workerless-front-painel`: painel Next.js em um Cloudflare Worker.

Os documentos de cada componente continuam sendo a referência para a lista de
variáveis e detalhes internos. Em caso de conflito, este guia e o código atual
prevalecem sobre `hetzner-production-runbook.md`, que descreve partes de uma
arquitetura anterior.

> **Arquitetura vigente:** a API não roda no cluster e não possui IP de saída
> fixo. Kubernetes e Prometheus permanecem sem exposição pública direta e são
> acessados pela API através de Cloudflare Tunnel + Access. Preserve
> `control_plane_cidrs = []` e `prometheus_node_port = null`.

## 1. Ordem obrigatória

Execute a primeira subida nesta ordem:

1. preparar states remotos e GitHub Environments;
2. criar a infraestrutura física em `workerless-terraforms/envs/hetzner`;
3. aplicar o Terraform da API para criar Atlas, Redis, R2, Tunnel e Access;
4. aplicar a plataforma uma vez com o conector `cloudflared` desativado;
5. criar o Secret do Tunnel no cluster e reaplicar com o conector ativado;
6. configurar e testar a rotação do token Kubernetes da API;
7. publicar `workerless-api-gateway`;
8. publicar o painel e seu domínio;
9. executar os gates de go-live.

Pare imediatamente se um plano contiver exclusão ou substituição não explicada,
se apontar para outro ambiente, se houver marcador `CHANGE_ME`, ou se qualquer
credencial aparecer no plano, log ou artifact.

## 2. Pré-requisitos e decisões aprovadas

Antes da janela de mudança, confirme:

- projetos/contas exclusivos de produção na Hetzner, Cloudflare, Atlas e Redis
  Cloud;
- três buckets R2 privados e distintos para os states de cluster, API e painel,
  ou uma separação equivalente por credenciais e chaves aprovada;
- versionamento habilitado nos buckets de state e credenciais S3 limitadas ao
  bucket correspondente;
- zona e hostnames exclusivos para API, painel, Kubernetes e Prometheus;
- Cloudflare Workers Paid com Containers e um Access Service Token;
- projeto Atlas, assinatura Redis Cloud e método de pagamento configurados;
- chave SSH dedicada, Terraform, `kubectl`, `jq`, `curl`, Node 24, Yarn e pnpm;
- pelo menos três servers k3s e dois workers, com capacidade N-1 revisada;
- janela de mudança, responsáveis, comunicação e rollback aprovados.

Os tipos ARM `cax11`/`cax21` exigem imagens `linux/arm64`. Use tamanhos, região,
CIDRs e quantidade de nós aprovados; os arquivos de exemplo não são sizing de
produção.

## 3. Configure os GitHub Environments

Crie os Environments protegidos `production` nos três repositórios. Crie também
`production-destructive` na API e no painel, com aprovação manual obrigatória.

### Cluster e plataforma

Em `workerless-terraforms`, configure os Secrets consumidos pelos workflows:

- `HCLOUD_TOKEN`;
- `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` do state R2;
- `ENVS_HETZNER_BACKEND_HCL` e `ENVS_HETZNER_TFVARS`;
- `PLATFORM_HETZNER_BACKEND_HCL` e `PLATFORM_HETZNER_TFVARS`.

Os quatro secrets de arquivo devem conter o arquivo completo, sem valores de
exemplo. Mantenha `is_production = true`, `workloads = {}`,
`control_plane_cidrs = []` e `prometheus_node_port = null`.

### API e painel

Cadastre todos os valores documentados em:

- [ambiente de produção da API](../../workerless-api/.github/production-environment.md);
- [ambiente de produção do painel](../../workerless-front-painel/.github/production-environment.md).

Não confunda estes valores:

- `CF_ACCESS_SERVICE_TOKEN_ID` é o ID do recurso autorizado pelas policies;
- `CF_ACCESS_CLIENT_ID` e `CF_ACCESS_CLIENT_SECRET` são enviados nos headers;
- `KUBERNETES_TOKEN_ISSUER_BEARER_TOKEN` pertence à identidade limitada de CI;
- `KUBERNETES_BEARER_TOKEN` é temporário e é publicado pelo workflow de rotação,
  nunca cadastrado manualmente no GitHub.

O domínio usado em `ALLOWED_FRONTEND_ORIGIN` deve ser exatamente
`https://<FRONTEND_HOSTNAME>`, sem barra final.

## 4. Prepare o state do cluster

Na raiz de `workerless-terraforms`:

```bash
cp envs/hetzner/backend.hcl.example envs/hetzner/backend.hcl
cp platform/hetzner/backend.hcl.example platform/hetzner/backend.hcl
cp envs/hetzner/terraform.tfvars.example envs/hetzner/terraform.tfvars
cp platform/hetzner/terraform.tfvars.example platform/hetzner/terraform.tfvars
```

Configure o mesmo bucket e endpoint R2 nos dois backends, mas preserve as chaves
distintas:

```text
workerless-terraforms/envs/hetzner/terraform.tfstate
workerless-terraforms/platform/hetzner/terraform.tfstate
```

Mantenha `encrypt = true`, `use_lockfile = true` e faça
`remote_state_env_key` apontar exatamente para a chave de `envs/hetzner`.
Confirme que os arquivos estão ignorados:

```bash
git check-ignore envs/hetzner/backend.hcl envs/hetzner/terraform.tfvars \
  platform/hetzner/backend.hcl platform/hetzner/terraform.tfvars
```

Exporte credenciais somente no shell da mudança:

```bash
ssh-add ~/.ssh/workerless-prod
export TF_VAR_hcloud_token='<TOKEN_HETZNER>'
export AWS_ACCESS_KEY_ID='<R2_ACCESS_KEY_ID>'
export AWS_SECRET_ACCESS_KEY='<R2_SECRET_ACCESS_KEY>'
export AWS_DEFAULT_REGION='auto'
```

## 5. Crie e valide o cluster

Em `envs/hetzner/terraform.tfvars`, use o `/32` atual do operador somente em
`admin_cidrs` e preserve:

```hcl
control_plane_cidrs = []
prometheus_node_port = null
```

O endpoint público administrativo ainda é necessário durante o Terraform da
plataforma. Nunca use `0.0.0.0/0` ou `::/0`. Planeje e aplique manualmente no
primeiro deploy:

```bash
terraform -chdir=envs/hetzner fmt -check
terraform -chdir=envs/hetzner init -reconfigure -backend-config=backend.hcl
terraform -chdir=envs/hetzner validate
terraform -chdir=envs/hetzner plan -out=tfplan
terraform -chdir=envs/hetzner show tfplan
terraform -chdir=envs/hetzner apply tfplan
```

Não use `./build.hetzner.sh` nesta primeira subida: ele aplica as duas camadas
sem uma pausa entre elas. Exporte o kubeconfig temporário:

```bash
terraform -chdir=envs/hetzner output -raw kubeconfig_raw > /tmp/workerless-prod-kubeconfig
chmod 600 /tmp/workerless-prod-kubeconfig
export KUBECONFIG=/tmp/workerless-prod-kubeconfig

kubectl get --raw /readyz
kubectl get nodes -o wide
kubectl get nodes -l workerless.io/node-pool=workers
```

Continue somente com `/readyz` igual a `ok`, três servers e todos os workers
esperados em `Ready`.

## 6. Crie os recursos de produção da API

### 6.1 Bootstrap do state

Em `workerless-api`, aplique `infra/bootstrap` uma única vez, mantendo seu state
local protegido até confirmar o bucket:

```bash
export TF_VAR_cloudflare_api_token='<TOKEN_CLOUDFLARE>'
export TF_VAR_cloudflare_account_id='<ACCOUNT_ID>'
export TF_VAR_state_bucket_name='<BUCKET_STATE_API>'

terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap plan -out=tfplan
terraform -chdir=infra/bootstrap apply tfplan
```

Crie credenciais R2 restritas ao bucket e mantenha o arquivo de backend fora do
repositório, por exemplo em um diretório protegido do operador. Não copie o
arquivo para `workerless-api`, pois esse caminho não é ignorado pelo Git.

### 6.2 Primeiro apply de produção

O primeiro Terraform da API deve ser executado manualmente antes do primeiro
push que dispara deploy, pois o Tunnel precisa existir antes da plataforma e o
deploy exige um token Kubernetes já rotacionado. Exporte todas as variáveis
`TF_VAR_*` equivalentes ao Environment `production` e as credenciais R2:

```bash
terraform -chdir=infra/production fmt -check
terraform -chdir=infra/production init -reconfigure \
  -backend-config=/CAMINHO/PROTEGIDO/workerless-api-backend.hcl
terraform -chdir=infra/production validate
terraform -chdir=infra/production plan -out=production.tfplan
terraform -chdir=infra/production show production.tfplan
terraform -chdir=infra/production apply production.tfplan
```

Esse apply cria o bucket de archives, Atlas, Redis Cloud, Tunnel, DNS e Access.
O Atlas aceita `0.0.0.0/0` porque Cloudflare Containers tem egress dinâmico;
TLS, credenciais exclusivas e rotação são controles obrigatórios.

Registre sem expor os valores:

```bash
terraform -chdir=infra/production output source_archive_bucket
terraform -chdir=infra/production output tunnel_id
```

Configure na API:

- `SOURCE_ARCHIVE_S3_BUCKET` com `source_archive_bucket`;
- `MONGO_URL` com URI `mongodb+srv://` do usuário criado;
- `REDIS_URL` com URI `rediss://` e TLS habilitado;
- credenciais R2 de archives limitadas ao bucket, diferentes das do state;
- `KUBERNETES_CA_DATA_BASE64` com o output `kube_ca`, obtido na raiz de
  `workerless-terraforms` por
  `terraform -chdir=envs/hetzner output -raw kube_ca`.

## 7. Instale a plataforma em duas fases

Volte à raiz de `workerless-terraforms`.

Complete os `plans` e o snapshot N-1 em
`platform/hetzner/terraform.tfvars`. Para a primeira fase use:

```hcl
is_production                 = true
workloads                     = {}
prometheus_node_port          = null
cloudflared_connector_enabled = false
```

Valores `0` no snapshot de capacidade são marcadores inválidos. Siga
[`capacity-admission-and-n-minus-one.md`](capacity-admission-and-n-minus-one.md)
e registre CPU, memória, DaemonSets, margem, PVCs, pods pendentes e restrições
de posicionamento.

Planeje e aplique a fase 1:

```bash
terraform -chdir=platform/hetzner fmt -check
terraform -chdir=platform/hetzner init -reconfigure -backend-config=backend.hcl
terraform -chdir=platform/hetzner validate
terraform -chdir=platform/hetzner plan -out=tfplan
terraform -chdir=platform/hetzner show tfplan
terraform -chdir=platform/hetzner apply tfplan
```

### 7.1 Secret store e acesso administrativo

A fase 1 instala o External Secrets Operator, mas não cria o backend de
segredos. Crie o `SecretStore`/`ClusterSecretStore` aprovado, confirme a
condição `Ready` e teste uma sincronização e uma rotação antes de ativar módulos
que o referenciem. Credenciais de workloads, Tailscale e Security Guard não
devem passar por `terraform.tfvars` nem pelo state.

O acesso administrativo privado usa o módulo Tailscale. Siga
[`modules/tailscale-operator/README.md`](../modules/tailscale-operator/README.md),
use uma tailnet dedicada, habilite HTTPS/MagicDNS e crie credenciais distintas
para o provider Terraform e para o Operator no cluster. A ACL é substituída por
inteiro pelo Terraform. Depois de configurar
`tailscale_operator_enabled = true`, pelo menos duas réplicas, tags exclusivas
de dispositivos administrativos e a referência do secret store, importe a
policy existente antes do primeiro `plan/apply`:

```bash
export TF_VAR_tailscale_tf_oauth_client_id='<OAUTH_TERRAFORM_ID>'
export TF_VAR_tailscale_tf_oauth_client_secret='<OAUTH_TERRAFORM_SECRET>'
terraform -chdir=platform/hetzner import \
  'module.tailscale_operator[0].tailscale_acl.guard' acl
```

Se as credenciais, o secret store ou a adoção da ACL ainda não estiverem
prontos, mantenha o módulo desativado e não conclua o go-live.

### 7.2 Ative o conector Cloudflare

Agora `workerless-system` existe. Leia o token do state da API sem imprimi-lo e
crie o Secret esperado pelo conector:

```bash
TUNNEL_TOKEN="$(terraform -chdir=../workerless-api/infra/production output -raw tunnel_token)"
kubectl -n workerless-system create secret generic workerless-cloudflared-tunnel \
  --from-literal=token="$TUNNEL_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
unset TUNNEL_TOKEN
```

O Secret é operacional e não pertence ao state da plataforma. Em seguida,
altere somente:

```hcl
cloudflared_connector_enabled        = true
cloudflared_tunnel_token_secret_name = "workerless-cloudflared-tunnel"
```

Gere um plano novo, revise e aplique novamente. Não reutilize o plano da fase 1.
Valide:

```bash
kubectl -n workerless-system rollout status deployment/workerless-cloudflared
kubectl -n workerless-system get pods -l app.kubernetes.io/name=workerless-cloudflared
kubectl get crd scaledobjects.keda.sh externalsecrets.external-secrets.io
kubectl get clusterpolicy
terraform -chdir=platform/hetzner output n_minus_one_capacity_status
```

O status N-1 deve mostrar `reserved = true`. Isso prova somente a reserva
matemática; recuperação real ainda precisa ser testada.

Quando Tailscale estiver ativado, espere o `ProxyGroup` ficar pronto, gere um
kubeconfig a partir da URL exibida e valide de um dispositivo autorizado:

```bash
kubectl get proxygroup workerless-prod
tailscale configure kubeconfig https://workerless-prod.<TAILNET>.ts.net
kubectl auth can-i '*' '*' --all-namespaces
kubectl get nodes
```

## 8. Configure a identidade e a rotação Kubernetes

`platform/hetzner` cria `workerless-api-runtime` e a ClusterRole
`workerless-api-token-issuer`, mas não cria credencial de CI. Provisione uma
identidade separada no mecanismo de autenticação Kubernetes adotado e vincule-a
somente ao emissor:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: workerless-api-token-issuer-ci
  namespace: workerless-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: workerless-api-token-issuer
subjects:
  - kind: User
    name: REPLACE_WITH_CI_IDENTITY
    apiGroup: rbac.authorization.k8s.io
```

Não use o kubeconfig administrativo, não vincule essa role a
`workerless-api-runtime` e não conceda acesso a outros ServiceAccounts. Grave o
bearer da identidade de CI em `KUBERNETES_TOKEN_ISSUER_BEARER_TOKEN`.

Valide a emissão pelo Tunnel com Access sem imprimir os tokens:

```bash
ISSUE_RESPONSE="$(curl --fail --silent --show-error \
  -X POST "https://$KUBERNETES_HOSTNAME/api/v1/namespaces/workerless-system/serviceaccounts/workerless-api-runtime/token" \
  -H "Authorization: Bearer $KUBERNETES_TOKEN_ISSUER_BEARER_TOKEN" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  -H 'Content-Type: application/json' \
  --data '{"apiVersion":"authentication.k8s.io/v1","kind":"TokenRequest","spec":{"expirationSeconds":3600}}')"
RUNTIME_TOKEN="$(jq -er '.status.token' <<<"$ISSUE_RESPONSE")"

# Deve retornar 200: a API pode listar namespaces.
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  "https://$KUBERNETES_HOSTNAME/api/v1/namespaces" \
  -H "Authorization: Bearer $RUNTIME_TOKEN" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET"

# Deve retornar 403: a API não pode ler secrets de kube-system.
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  "https://$KUBERNETES_HOSTNAME/api/v1/namespaces/kube-system/secrets" \
  -H "Authorization: Bearer $RUNTIME_TOKEN" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET"

unset ISSUE_RESPONSE RUNTIME_TOKEN
```

Depois execute manualmente o workflow `rotate-kubernetes-token.yml`. Ele emite
um token de uma hora e o publica como Worker Secret; a agenda renova a cada 20
minutos e preserva o token anterior quando a emissão falha.

Confirme no diretório `workerless-api/edge`, sem exibir valores:

```bash
npx wrangler secret list | jq -e \
  'map(.name) | index("KUBERNETES_BEARER_TOKEN") != null'
```

## 9. Publique e valide a API

Revise o [runbook Cloudflare da API](../../workerless-api/docs/runbooks/cloudflare-production.md)
e confirme que todos os valores do Environment `production` estão preenchidos.
Faça merge/push em `main`; o workflow `Production` não possui disparo manual.
Ele executa qualidade, segurança, plano Terraform, apply não destrutivo,
sincronização de secrets, deploy e readiness.

A API precisa ser publicada primeiro com o nome `workerless-api-gateway`, pois
o painel depende desse Service Binding. Valide:

```bash
curl --fail --retry 12 --retry-all-errors --retry-delay 5 \
  "https://<API_HOSTNAME>/health/ready"
```

Confirme também:

- o Container recebe URL interna e CA, mas não recebe Access credentials;
- o Worker injeta bearer e headers Access somente nos hostnames Kubernetes e
  Prometheus;
- Atlas usa `mongodb+srv://` e Redis usa `rediss://`;
- criação, consulta e remoção de um workload canário funcionam com o RBAC
  `workerless-api-runtime`;
- um token sem permissão não acessa namespaces da plataforma.

## 10. Publique o painel

### 10.1 Bootstrap do state

Em `workerless-front-painel`, aplique `infra/bootstrap` uma única vez:

```bash
export TF_VAR_cloudflare_api_token='<TOKEN_CLOUDFLARE>'
export TF_VAR_cloudflare_account_id='<ACCOUNT_ID>'
export TF_VAR_state_bucket_name='<BUCKET_STATE_FRONTEND>'

terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap plan -out=tfplan
terraform -chdir=infra/bootstrap apply tfplan
```

Crie credenciais R2 restritas ao bucket do painel, configure o backend remoto
com `infra/production/backend.hcl` (esse arquivo é ignorado neste repositório) e
cadastre o Environment conforme o documento do frontend.

### 10.2 Deploy

Confirme antes do merge:

- `workerless-api-gateway` já está publicado;
- `WORKERLESS_API` aponta para esse serviço no Wrangler;
- `API_HOSTNAME` corresponde à API pública;
- `ALLOWED_FRONTEND_ORIGIN` da API corresponde ao domínio final do painel.

Faça merge/push em `main`. O workflow do painel executa testes, build
Cloudflare, plano Terraform, deploy do Worker, aplicação do custom domain e
verificação. Valide:

```bash
curl --fail "https://<FRONTEND_HOSTNAME>/api/health/ready"
curl --fail "https://<FRONTEND_HOSTNAME>/login"
```

Teste login, REST/BFF, Socket.IO, criação de app e acompanhamento de deployment
no domínio final. O navegador deve usar a origem do painel; não deve depender
diretamente do hostname público da API.

## 11. Gates de go-live

Não libere tenants até todos os itens estarem concluídos:

- states R2 privados, versionados e com lock funcionando;
- planos novos de cluster e plataforma retornam `No changes`;
- workflows de drift da API e do painel retornam sem mudanças;
- todos os nós estão `Ready`, PVCs `Bound` e pods sem erros persistentes;
- `cloudflared` tem pelo menos duas réplicas disponíveis;
- Kubernetes e Prometheus não possuem exposição pública direta;
- Tailscale administrativo e caminho de recuperação foram testados;
- Atlas e Redis exigem TLS, possuem backup/HA conforme política e restore
  testado;
- rotação Kubernetes passou mais de um ciclo e existe alerta para falha;
- RBAC/Kyverno passaram testes positivos e negativos;
- workload canário completou build, deploy, escala e remoção;
- snapshots etcd foram copiados para destino remoto e o restore foi ensaiado;
- health checks da API e painel passam pelo domínio final;
- secret scan não encontrou credenciais no Git, planos ou artifacts;
- alertas de nodes, etcd, PVCs, KEDA, Kyverno, ESO, Tunnel e tokens estão ativos.

Execute os planos finais sem reutilizar arquivos aplicados:

```bash
terraform -chdir=envs/hetzner plan -detailed-exitcode
terraform -chdir=platform/hetzner plan -detailed-exitcode
```

Código `0` significa `No changes`, `1` erro e `2` mudança pendente.

## 12. Operação contínua

Depois do primeiro deploy, mudanças seguem PR + plano revisado. O workflow de
`workerless-terraforms` pode usar `./build.hetzner.sh` porque o Secret do Tunnel
já existe. Mantenha:

- Environment `production-destructive` protegido e usado somente para mudanças
  explicitamente aprovadas;
- drift agendado da API e painel acompanhado por alertas;
- rotação do token Kubernetes a cada 20 minutos;
- rotação periódica de Atlas, Redis, R2, Access e chaves de assinatura;
- `admin_cidrs` atualizado para o `/32` do operador antes de cada Terraform que
  acesse o endpoint público;
- plano salvo aplicado apenas na mesma janela e contra o mesmo state.

## 13. Rollback e recuperação

Não execute `terraform destroy` como rollback.

- **API ou painel:** reverta o commit para a última versão saudável e execute o
  workflow normal. Preserve os states e os dados gerenciados.
- **Terraform:** restaure a configuração anterior, gere um plano novo e revise.
  Nunca aplique um plano antigo nem restaure state para desfazer recursos
  saudáveis.
- **Token Kubernetes:** uma rotação com falha não substitui o token anterior.
  Corrija a identidade emissora e rode o workflow antes da expiração.
- **Tunnel:** preserve o Secret e as rotas anteriores durante rollback. Só
  desative o conector depois de confirmar outro caminho funcional.
- **Cluster:** use snapshots etcd e o procedimento de recuperação ensaiado.
  Restauração de state R2 é somente para corrupção/perda do state, seguida de
  `state pull` e `plan` antes de qualquer apply.

Mudanças destrutivas exigem plano separado, aprovação manual e confirmação do
alvo exato. Registre o resultado e qualquer desvio no relatório da mudança.

## 14. Limpeza da estação

Ao terminar:

```bash
rm -f /tmp/workerless-prod-kubeconfig
unset KUBECONFIG TF_VAR_hcloud_token AWS_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION TUNNEL_TOKEN \
  TF_VAR_cloudflare_api_token TF_VAR_cloudflare_account_id \
  TF_VAR_state_bucket_name
```

Remova tokens temporários adicionais do shell, confirme que nenhum arquivo
sensível entrou no Git e arquive apenas planos sanitizados e aprovações exigidas
pelo processo de mudança.
