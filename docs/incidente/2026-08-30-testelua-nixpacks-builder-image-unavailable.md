# Incidente: deploy "testelua" travado em `ImagePullBackOff` puxando o builder nixpacks próprio

> Documento escrito para outro agente/engenheiro dar continuidade. Contém o diagnóstico
> completo (cluster + banco + código + negócio) e as opções de correção. Nenhum valor de
> secret real foi incluído aqui — apenas nomes de env vars.

## 1. Resumo

O deploy `testelua` **está travado, não falhou** — o `Job` de build foi criado e está
rodando há vários minutos, mas o container principal (`nixpacks`) nunca inicia porque o
Kubernetes não consegue baixar a própria imagem do builder:
`host.docker.internal:5001/workerless-nixpacks-builder:latest`.

Isso acontece por **duas causas empilhadas**, ambas necessárias para destravar:

1. Essa imagem **nunca foi publicada** no registry local (`workerless-registry`,
   `docker-compose.yml`, porta `5001:5000`) — o catálogo do registry está vazio.
2. Mesmo publicando a imagem, o `containerd` do node k3d local **não está configurado**
   para tratar `host.docker.internal:5001` como um registry HTTP inseguro — hoje ele tenta
   HTTPS e recebe uma resposta HTTP, o que produz um erro de protocolo, não de
   autenticação.

Isso é uma **regressão operacional direta** do fix aplicado no incidente
`docs/incidents/2026-08-30-teste24-nixpacks-privileged-blocked-by-kyverno.md`: aquele
incidente trocou a estratégia `nixpacks` para usar uma imagem de builder própria (para não
precisar mais de `privileged: true`, bloqueado pelo Kyverno) — mas o passo operacional de
**publicar essa imagem** e de **configurar o cluster local para puxá-la via HTTP** nunca
foi concluído. `testelua` é, muito provavelmente, o próprio teste de verificação daquele
incidente (seção 6, "Como verificar a correção") — e ele confirma que a correção do
`teste24` ainda não foi validada ponta a ponta.

## 2. Evidência coletada

### 2.1 Cluster (`kubectl`, contexto `k3d-local-rock`)

```
$ kubectl get all -n wl-moiseslopes-7fcd5afd
NAME                                          READY   STATUS             RESTARTS   AGE
pod/build-dpl035066eaa8e40d664890a9ec-jplmz   0/1     ImagePullBackOff   0          8m40s

NAME                                          STATUS    COMPLETIONS   DURATION   AGE
job.batch/build-dpl035066eaa8e40d664890a9ec   Running   0/1           8m44s      8m44s
```

`kubectl describe pod build-dpl035066eaa8e40d664890a9ec-jplmz`:

- Init container `archive-source` (imagem `alpine:3.20`): **`Terminated: Completed`**,
  exit code 0 — baixou o zip do MinIO com sucesso via
  `http://host.docker.internal:9000/workerless-source/...` (presigned URL, MinIO/S3).
  Ou seja: o fix do incidente `2026-08-22-algoaqui-source-archive-url-unreachable.md`
  (endpoint público para presigned URLs) está funcionando corretamente para este deploy —
  não é a causa deste incidente.
- Container principal `nixpacks` (imagem
  `host.docker.internal:5001/workerless-nixpacks-builder:latest`): **`Waiting:
  ImagePullBackOff`**. Eventos:
  ```
  Pulling image "host.docker.internal:5001/workerless-nixpacks-builder:latest"
  Failed to pull image "host.docker.internal:5001/workerless-nixpacks-builder:latest":
    failed to pull and unpack image ...: failed to resolve reference ...:
    failed to do request: Head "https://host.docker.internal:5001/v2/.../manifests/latest":
    http: server gave HTTP response to HTTPS client
  BackOff (x19 over 8m4s): Back-off pulling image "host.docker.internal:5001/workerless-nixpacks-builder:latest"
  ```
  A mensagem `http: server gave HTTP response to HTTPS client` é definitiva: o
  `containerd` do node está tentando TLS contra um endpoint que só fala HTTP puro.

```
$ curl -s http://localhost:5001/v2/_catalog
{"repositories":[]}
```

Confirma a causa raiz #1: **nenhuma imagem foi publicada** no registry local ainda —
inclusive se o problema de TLS fosse resolvido agora, o pull falharia de novo por imagem
inexistente (`NAME_UNKNOWN`).

Há também um Job **anterior e não relacionado** no mesmo namespace,
`build-dpld60eae466068d9949e77b0ed` (app `moiseslopes-testeketh1-a6abf4`, não é
`testelua`), que falhou ~11 minutos antes com `nixpacks: not found` (exit 127) usando a
imagem antiga `ghcr.io/railwayapp/nixpacks:latest`. Isso é o mesmo bug documentado em
`docs/incidents/2026-08-22-teste5-nixpacks-image-missing-binary.md` — evidência de que,
entre essa tentativa e a de `testelua`, `KUBERNETES_NIXPACKS_IMAGE` mudou de valor (ver
§3.3 sobre as duas fontes de configuração local que hoje divergem).

### 2.2 Banco de dados (Mongo)

```js
db.apps.findOne({ name: /testelua/i })
// _id: '6a94ab8df0ceaa84da4180aa', status: 'provisioning'
// build: { buildStrategy: 'nixpacks', dockerfilePath: null }
// deployment: { deploymentName: 'testelua', namespace: 'wl-moiseslopes-7fcd5afd' }
// createdAt: 2026-08-30T22:15:41.563Z

db.deployments.findOne({ appId: 'moiseslopes-testelua-2fd648' })
// status: 'pushing', stage: 'pushing', failureReason: null, finishedAt: null
```

`failureReason` está **vazio** porque `ImagePullBackOff` nunca incrementa
`Job.status.failed` — o Kubernetes só fica retentando indefinidamente. A API só vai marcar
o deploy como `failed` quando o watcher de timeout do `RunArchiveDeployPipelineApplication`
estourar (`BUILD_TIMEOUT_MS`, 15 min por padrão) e produzir uma mensagem genérica de
timeout — exatamente o mesmo padrão de sintoma (sem causa real no banco) já documentado em
`docs/incidents/2026-08-22-tenta-ser-feliz-deploy-stuck.md`. **Não espere o timeout para
diagnosticar** — vá direto ao `kubectl describe pod`, como feito aqui.

## 3. Causa raiz — código e configuração

### 3.1 De onde vem a imagem do builder

`src/di/config.providers.ts:204-206` (`kubernetesRuntimeConfigFactory`):

```ts
nixpacksImage:
  optionalConfig(configService, 'KUBERNETES_NIXPACKS_IMAGE') ??
  'host.docker.internal:5001/workerless-nixpacks-builder:latest',
```

`.env:54` usa exatamente esse mesmo valor. Essa imagem é referenciada em
`src/infra/deployments/kubernetes/kubernetes-build-runtime.service.ts`, método
`buildContainer` (branch `nixpacks`, ~linhas 542-561) como a **imagem do próprio
container** que roda `nixpacks build` + `buildctl-daemonless.sh build ... push=true` —
diferente de uma imagem base de app, essa é puxada pelo **kubelet/containerd do node**,
não por `buildctl`, então nenhuma flag de aplicação (env var da API) consegue mudar como
esse pull específico é feito.

Fonte da imagem: `docker/nixpacks-builder/Dockerfile` (novo arquivo, ainda não commitado):

```dockerfile
FROM moby/buildkit:rootless
USER root
RUN apk add --no-cache curl ca-certificates \
    && curl -sSL https://nixpacks.com/install.sh | bash -s -- --yes --bin-dir /usr/local/bin \
    && apk del curl
USER 1000:1000
```

Script para build + publish, `package.json:21`:

```
"docker:nixpacks-image": "docker build -t localhost:5001/workerless-nixpacks-builder:latest docker/nixpacks-builder && docker push localhost:5001/workerless-nixpacks-builder:latest"
```

**Esse script nunca foi executado** — daí o catálogo vazio em §2.1. É o passo que faltou
depois do fix do `teste24`.

### 3.2 Por que o pull falha mesmo depois de publicar a imagem

O registry local (`docker-compose.yml:106-120`, `distribution/distribution:edge`, porta
`5001:5000`) só fala HTTP puro — não há TLS configurado nele. O `containerd` dentro do
node k3d, por padrão, assume HTTPS para qualquer registry que não seja localhost (do
ponto de vista do próprio node, `host.docker.internal:5001` não conta como localhost).
Isso **não é um bug de código da API** — é configuração de infraestrutura do cluster local
(`registries.yaml` / `hosts.toml` do containerd no(s) node(s) k3d), que precisa declarar
`host.docker.internal:5001` como mirror inseguro (HTTP). Nada no `workerless-api` controla
isso; é puramente uma etapa de setup do ambiente local que nunca foi feita (ou foi feita
antes e se perdeu ao recriar o cluster).

### 3.3 Achado colateral — duas fontes de configuração local hoje divergentes

Comparando `.env` (raiz do repo) com a run configuration do IDE
(`.idea/workspace.xml`, "start:dev"):

| Variável | `.env` (usado no deploy de `testelua`) | `.idea/workspace.xml` |
|---|---|---|
| `KUBERNETES_NIXPACKS_IMAGE` | `host.docker.internal:5001/workerless-nixpacks-builder:latest` (correto, pós-`teste24`) | `ghcr.io/railwayapp/nixpacks:latest` (**stale**, bug do `teste5`) |
| `SOURCE_ARCHIVE_S3_PUBLIC_ENDPOINT` | **ausente** no arquivo hoje | `http://host.docker.internal:9000` (correto, pós-`algoaqui`) |

A evidência do cluster (§2.1) mostra que o processo que rodou o deploy de `testelua` tinha
**os dois valores corretos em memória** no momento do boot (imagem nova + endpoint
público correto) — então isso não é a causa do travamento atual de `testelua`. Mas como
`ConfigService` só lê env uma vez, na subida do processo (já registrado no incidente
`zuco-env-diff.md`), isso é uma **bomba-relógio**: o próximo `yarn start:dev` (seja via
terminal lendo `.env`, seja via run configuration do IDE) pode reintroduzir um dos dois
bugs já resolvidos (`teste5` ou `algoaqui`), dependendo de qual fonte for usada — e é
exatamente isso que aconteceu com o Job anterior de `testeketh1` no mesmo namespace
(§2.1), que usou a imagem antiga. **Recomendação: unificar as duas fontes antes de
qualquer novo teste.**

### 3.4 Achado colateral #2 — `KUBERNETES_REGISTRY_INSECURE` está declarado mas não é lido em lugar nenhum

`.env`, `.env.example:71` e `.idea/workspace.xml` definem `KUBERNETES_REGISTRY_INSECURE=true`,
mas:
- `KubernetesRuntimeConfig` (`src/infra/config/kubernetes-runtime.config.ts`) não tem
  campo `registryInsecure`.
- `kubernetesRuntimeConfigFactory` nunca lê essa variável.
- Os argumentos de push do `buildctl-daemonless.sh` em `buildContainer()`
  (`kubernetes-build-runtime.service.ts`, ambas as estratégias) sempre emitem
  `--output type=image,name=<ref>,push=true`, sem `registry.insecure=true`.

Isso **não é a causa do travamento atual** (o build nem chega a rodar), mas é o próximo
domino: assim que os itens 3.1/3.2 forem corrigidos e a imagem do builder subir, o
`buildctl-daemonless.sh` vai tentar dar `push` da imagem final gerada de volta para o
mesmo registry HTTP-inseguro (`host.docker.internal:5001`, também usado como
`PLATFORM_REGISTRY_URL`) e provavelmente falhar do mesmo jeito, só que na etapa de push em
vez de pull.

## 4. Causa raiz — negócio / blueprint

Toda estratégia de build atual passa a exigir uma imagem de builder auto-hospedada no
registry local — decisão correta para não violar `pss-baseline` (Kyverno), mas que criou
uma **dependência operacional nova** (build + publish local + configuração de registry
inseguro no cluster) que ainda não está automatizada nem documentada em nenhum lugar do
repositório (`AGENTS.md` não menciona nada sobre isso). Efeito de negócio: **todo app
enviado por upload usa `buildStrategy: 'nixpacks'` incondicionalmente**
(`src/core/apps/usecases/resolve-uploaded-app-defaults.usecase.ts`, hardcoded, sem
detecção de Dockerfile) — ou seja, **100% dos uploads locais estão bloqueados** até esse
setup ser feito, não é uma falha específica do app `testelua`.

Separadamente, `docs/API_PLATFORM_BLUEPRINT.md` ainda descreve a "Fase 1: API + DB CRUD
only, no Kubernetes apply yet" — desatualizado, já apontado antes em
`docs/incidents/2026-08-22-tenta-ser-feliz-deploy-stuck.md` §4, e ainda sem correção.

## 5. Como resolver

### Passo 1 (obrigatório, resolve a causa #1)

Publicar a imagem do builder no registry local:

```
yarn docker:nixpacks-image
```

Confirmar com `curl http://localhost:5001/v2/workerless-nixpacks-builder/tags/list`.

### Passo 2 (obrigatório, resolve a causa #2)

Configurar o `containerd` do(s) node(s) k3d para tratar `host.docker.internal:5001` como
registry HTTP inseguro. Duas formas:

- **Recriar o cluster** com um `registries.yaml` de mirror inseguro passado via
  `k3d cluster create --registry-config <arquivo>`, por exemplo:
  ```yaml
  mirrors:
    "host.docker.internal:5001":
      endpoint:
        - "http://host.docker.internal:5001"
  ```
- **Ou editar o node existente sem recriar** (mais rápido para desbloquear agora):
  criar/editar
  `/var/lib/rancher/k3s/agent/etc/containerd/certs.d/host.docker.internal:5001/hosts.toml`
  dentro do node com:
  ```toml
  server = "http://host.docker.internal:5001"
  [host."http://host.docker.internal:5001"]
    capabilities = ["pull", "resolve", "push"]
    skip_verify = true
  ```
  e reiniciar o `containerd`/`k3s` do node (ou o pod/container do node, dependendo de como
  o k3d local foi provisionado).

Isso é infraestrutura do ambiente local, fora do código do `workerless-api` — não requer
mudança em `src/`.

### Passo 3 (recomendado, evita repetir o bug #2/#3 do teste24/teste5)

Reconciliar `.env` e a run configuration do IDE (§3.3) para os dois terem os mesmos
valores corretos de `KUBERNETES_NIXPACKS_IMAGE` e `SOURCE_ARCHIVE_S3_PUBLIC_ENDPOINT`.
Considerar documentar em `AGENTS.md` (ou um script `yarn setup:local-k8s`) os pré-requisitos
de ambiente local: subir `docker-compose`, rodar `docker:nixpacks-image`, e configurar o
registry inseguro no k3d — hoje isso não está escrito em lugar nenhum, o que já causou
pelo menos dois incidentes de drift.

### Passo 4 (recomendado, próximo domino esperado — §3.4)

Adicionar `registryInsecure: boolean` a `KubernetesRuntimeConfig`, ler
`KUBERNETES_REGISTRY_AUTH_REQUIRED`-style de `KUBERNETES_REGISTRY_INSECURE` em
`kubernetesRuntimeConfigFactory`, e passar `registry.insecure=true` no `--output` do
`buildctl-daemonless.sh` em `buildContainer()` (ambas as estratégias,
`kubernetes-build-runtime.service.ts`, e no runner v2 se também usar esse registry local).
Atualizar os specs correspondentes
(`test/unit/infra/deployments/kubernetes/kubernetes-build-runtime.service.spec.ts`,
`test/unit/infra/deployments/v2/infra.spec.ts`, `test/unit/di/config.providers.spec.ts`).

## 6. Como verificar a correção

1. Repetir passos 1 e 2 acima.
2. Restart do processo da API (env só é lido no boot).
3. Novo deploy de teste com um app `buildStrategy: 'nixpacks'` e observar:
   ```
   kubectl get jobs,pods -n wl-moiseslopes-7fcd5afd -w
   ```
   Esperado: o container `nixpacks` sai de `ImagePullBackOff`, o Job completa
   (`COMPLETIONS 1/1`).
4. Se completar o build mas falhar no `push` (indício da causa #3.4), aplicar o Passo 4 e
   repetir.
5. Confirmar no Mongo que `deployments.status` chega a `succeeded`, não só que o
   `ImagePullBackOff` desapareceu.
6. Rodar `yarn lint`, `yarn test`, `yarn test:cov` antes de considerar qualquer mudança de
   código (Passo 4) concluída.

## 7. Fora de escopo deste incidente (registrar como itens separados)

- `docs/API_PLATFORM_BLUEPRINT.md` "Fase 1" desatualizado — já flagado antes, ainda sem
  dono.
- Ausência de detecção de Dockerfile em uploads (`resolve-uploaded-app-defaults.usecase.ts`
  hardcoda `nixpacks` sempre) — decisão de produto, não bug.
- `getBuildJobStatus`/`getRolloutStatus` (variantes de polling) parecem código morto face
  aos `watch*` usados de fato pelo pipeline — limpeza, não bug.
- Falta de provisionamento real do secret `registry-credentials` (Opção B do incidente
  `tenta-ser-feliz`) — hoje contornado tornando o mount opcional; só vira problema se
  `KUBERNETES_REGISTRY_AUTH_REQUIRED=true` for ativado sem esse trabalho.

## 8. Arquivos-chave

- `src/infra/deployments/kubernetes/kubernetes-build-runtime.service.ts` — `buildContainer`
  (~linhas 505-569, branch nixpacks ~542-561), `submitBuildJob`, `watchBuildJobUntilDone`.
- `src/di/config.providers.ts` (linhas ~185-216, `kubernetesRuntimeConfigFactory`).
- `src/infra/config/kubernetes-runtime.config.ts` (tipo `KubernetesRuntimeConfig`).
- `docker/nixpacks-builder/Dockerfile` e `package.json:21` (`docker:nixpacks-image`).
- `docker-compose.yml:106-120` (`workerless-registry`, `distribution/distribution:edge`).
- `.env` vs `.idea/workspace.xml` (drift descrito em §3.3).
- `docs/incidents/2026-08-30-teste24-nixpacks-privileged-blocked-by-kyverno.md` (fix que
  originou a dependência desta imagem própria).
- `docs/incidents/2026-08-22-tenta-ser-feliz-deploy-stuck.md`,
  `docs/incidents/2026-08-22-teste5-nixpacks-image-missing-binary.md`,
  `docs/incidents/2026-08-22-algoaqui-source-archive-url-unreachable.md` — bugs
  relacionados/anteriores na mesma cadeia de pipeline.
