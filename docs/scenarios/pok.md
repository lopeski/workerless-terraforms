Abaixo está uma implementação Node.js/Express para o **Cenário 1**, com build por ZIP usando **Kaniko Job** e acompanhamento em tempo real via **Kubernetes Watch**. O `Watch` do Kubernetes serve justamente para stream de mudanças em objetos, em vez de polling cego; o client oficial JS roda server-side em Node.js. ([Kubernetes][1]) Kaniko constrói a imagem a partir de um Dockerfile e envia para o registry sem Docker daemon. ([GitHub][2])

## 1. Dependências

```bash
npm i express multer nanoid yauzl @kubernetes/client-node
```

No `package.json`:

```json
{
  "type": "module",
  "scripts": {
    "dev": "node --watch src/server.js",
    "start": "node src/server.js"
  }
}
```

---

## 2. Estrutura sugerida

```txt
src/
├── server.js
├── k8s/
│   └── client.js
└── builds/
    ├── build-routes.js
    ├── build-store.js
    ├── build-service.js
    └── manifests.js
```

---

## 3. Client Kubernetes

`src/k8s/client.js`

```js
import * as k8s from "@kubernetes/client-node";

export const kc = new k8s.KubeConfig();

if (process.env.KUBERNETES_SERVICE_HOST) {
  kc.loadFromCluster();
} else {
  kc.loadFromDefault();
}

export const coreApi = kc.makeApiClient(k8s.CoreV1Api);
export const batchApi = kc.makeApiClient(k8s.BatchV1Api);
export const watchApi = new k8s.Watch(kc);
export const logApi = new k8s.Log(kc);
export const execApi = new k8s.Exec(kc);

export function isK8sStatus(err, code) {
  return (
    err?.response?.statusCode === code ||
    err?.statusCode === code ||
    err?.body?.code === code
  );
}

export async function ignoreAlreadyExists(promise) {
  try {
    return await promise;
  } catch (err) {
    if (isK8sStatus(err, 409)) return null;
    throw err;
  }
}

export async function ignoreNotFound(promise) {
  try {
    return await promise;
  } catch (err) {
    if (isK8sStatus(err, 404)) return null;
    throw err;
  }
}

export function stopK8sWatch(req) {
  req?.abort?.();
  req?.destroy?.();
}
```

---

## 4. Store simples de builds

Troque por Postgres/Prisma depois. Para a Fase 3, isso já permite observar o fluxo.

`src/builds/build-store.js`

```js
import { EventEmitter } from "node:events";

const builds = new Map();
const bus = new EventEmitter();
bus.setMaxListeners(5000);

function view(build) {
  if (!build) return null;

  return {
    buildId: build.buildId,
    tenantId: build.tenantId,
    appId: build.appId,
    status: build.status,
    registry: build.registry,
    imageTag: build.imageTag,
    namespace: build.namespace,
    jobName: build.jobName,
    podName: build.podName,
    pvcName: build.pvcName,
    startedAt: build.startedAt,
    finishedAt: build.finishedAt,
    error: build.error,
    logs: build.logs.slice(-200),
    events: build.events.slice(-80)
  };
}

function emit(buildId) {
  const build = builds.get(buildId);
  bus.emit(`build:${buildId}`, view(build));
}

export function createBuild(data) {
  const build = {
    ...data,
    status: "pending",
    startedAt: new Date().toISOString(),
    finishedAt: null,
    logs: [],
    events: []
  };

  builds.set(build.buildId, build);
  emit(build.buildId);
  return view(build);
}

export function getBuild(buildId) {
  return view(builds.get(buildId));
}

export function getBuildInternal(buildId) {
  return builds.get(buildId);
}

export function patchBuild(buildId, patch) {
  const build = builds.get(buildId);
  if (!build) return null;

  Object.assign(build, patch);
  emit(buildId);
  return view(build);
}

export function appendBuildLog(buildId, message, source = "kaniko") {
  const build = builds.get(buildId);
  if (!build) return;

  build.logs.push({
    ts: new Date().toISOString(),
    source,
    message: String(message).replace(/\n$/, "")
  });

  if (build.logs.length > 1000) {
    build.logs.splice(0, build.logs.length - 1000);
  }

  emit(buildId);
}

export function appendBuildEvent(buildId, event) {
  const build = builds.get(buildId);
  if (!build) return;

  build.events.push({
    ts: new Date().toISOString(),
    ...event
  });

  if (build.events.length > 300) {
    build.events.splice(0, build.events.length - 300);
  }

  emit(buildId);
}

export function onBuild(buildId, listener) {
  const key = `build:${buildId}`;
  bus.on(key, listener);
  return () => bus.off(key, listener);
}
```

---

## 5. Manifests Kubernetes

`src/builds/manifests.js`

```js
export const BUILD_NAMESPACE = process.env.BUILD_NAMESPACE || "build-system";
export const REGISTRY_SECRET_NAME =
  process.env.REGISTRY_SECRET_NAME || "registry-credentials";

export function buildLabels({ buildId, tenantId, appId }) {
  return {
    "app.kubernetes.io/managed-by": "workerless-control-plane",
    "workerless.io/build-id": buildId,
    "workerless.io/tenant-id": tenantId,
    "workerless.io/app-id": appId
  };
}

export function makeBuildPvc({ pvcName, labels }) {
  return {
    apiVersion: "v1",
    kind: "PersistentVolumeClaim",
    metadata: {
      name: pvcName,
      namespace: BUILD_NAMESPACE,
      labels
    },
    spec: {
      accessModes: ["ReadWriteOnce"],
      resources: {
        requests: {
          storage: process.env.BUILD_PVC_SIZE || "1Gi"
        }
      }
    }
  };
}

export function makeStagingPod({ podName, pvcName, labels }) {
  return {
    apiVersion: "v1",
    kind: "Pod",
    metadata: {
      name: podName,
      namespace: BUILD_NAMESPACE,
      labels
    },
    spec: {
      restartPolicy: "Never",
      securityContext: {
        fsGroup: 1000,
        seccompProfile: {
          type: "RuntimeDefault"
        }
      },
      containers: [
        {
          name: "stager",
          image: "busybox:1.36",
          command: ["sh", "-c", "mkdir -p /workspace && sleep 3600"],
          volumeMounts: [
            {
              name: "workspace",
              mountPath: "/workspace"
            }
          ],
          securityContext: {
            runAsNonRoot: true,
            runAsUser: 1000,
            runAsGroup: 1000,
            allowPrivilegeEscalation: false,
            capabilities: {
              drop: ["ALL"]
            }
          },
          resources: {
            requests: {
              cpu: "10m",
              memory: "32Mi"
            },
            limits: {
              cpu: "100m",
              memory: "128Mi"
            }
          }
        }
      ],
      volumes: [
        {
          name: "workspace",
          persistentVolumeClaim: {
            claimName: pvcName
          }
        }
      ]
    }
  };
}

export function makeKanikoJob({
  jobName,
  pvcName,
  imageTag,
  labels
}) {
  return {
    apiVersion: "batch/v1",
    kind: "Job",
    metadata: {
      name: jobName,
      namespace: BUILD_NAMESPACE,
      labels
    },
    spec: {
      backoffLimit: 0,
      activeDeadlineSeconds: Number(process.env.BUILD_TIMEOUT_SECONDS || 1800),
      ttlSecondsAfterFinished: Number(process.env.BUILD_TTL_SECONDS || 3600),
      template: {
        metadata: {
          labels
        },
        spec: {
          restartPolicy: "Never",
          securityContext: {
            fsGroup: 1000,
            seccompProfile: {
              type: "RuntimeDefault"
            }
          },
          initContainers: [
            {
              name: "unzip-source",
              image: "busybox:1.36",
              command: [
                "sh",
                "-c",
                [
                  "rm -rf /workspace/context",
                  "mkdir -p /workspace/context",
                  "unzip -q /workspace/source.zip -d /workspace/context",
                  "test -f /workspace/context/Dockerfile"
                ].join(" && ")
              ],
              volumeMounts: [
                {
                  name: "workspace",
                  mountPath: "/workspace"
                }
              ],
              securityContext: {
                runAsNonRoot: true,
                runAsUser: 1000,
                runAsGroup: 1000,
                allowPrivilegeEscalation: false,
                capabilities: {
                  drop: ["ALL"]
                }
              }
            }
          ],
          containers: [
            {
              name: "kaniko",
              image:
                process.env.KANIKO_IMAGE ||
                "gcr.io/kaniko-project/executor:v1.23.2-debug",
              args: [
                "--context=dir:///workspace/context",
                "--dockerfile=/workspace/context/Dockerfile",
                `--destination=${imageTag}`,
                "--snapshot-mode=redo",
                "--verbosity=info"
              ],
              volumeMounts: [
                {
                  name: "workspace",
                  mountPath: "/workspace"
                },
                {
                  name: "docker-config",
                  mountPath: "/kaniko/.docker",
                  readOnly: true
                }
              ],
              securityContext: {
                allowPrivilegeEscalation: false,
                capabilities: {
                  drop: ["ALL"]
                }
              },
              resources: {
                requests: {
                  cpu: process.env.KANIKO_CPU_REQUEST || "250m",
                  memory: process.env.KANIKO_MEMORY_REQUEST || "512Mi"
                },
                limits: {
                  cpu: process.env.KANIKO_CPU_LIMIT || "2",
                  memory: process.env.KANIKO_MEMORY_LIMIT || "2Gi"
                }
              }
            }
          ],
          volumes: [
            {
              name: "workspace",
              persistentVolumeClaim: {
                claimName: pvcName
              }
            },
            {
              name: "docker-config",
              secret: {
                secretName: REGISTRY_SECRET_NAME,
                items: [
                  {
                    key: ".dockerconfigjson",
                    path: "config.json"
                  }
                ]
              }
            }
          ]
        }
      }
    }
  };
}
```

---

## 6. Serviço de build com Watch do Kubernetes

`src/builds/build-service.js`

```js
import crypto from "node:crypto";
import fs from "node:fs";
import { PassThrough } from "node:stream";
import yauzl from "yauzl";
import { nanoid } from "nanoid";

import {
  coreApi,
  batchApi,
  watchApi,
  logApi,
  execApi,
  ignoreAlreadyExists,
  ignoreNotFound,
  stopK8sWatch
} from "../k8s/client.js";

import {
  appendBuildEvent,
  appendBuildLog,
  createBuild,
  getBuildInternal,
  patchBuild
} from "./build-store.js";

import {
  BUILD_NAMESPACE,
  buildLabels,
  makeBuildPvc,
  makeKanikoJob,
  makeStagingPod
} from "./manifests.js";

const DNS_LABEL_RE = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;

export async function startKanikoZipBuild({
  tenantId,
  appId,
  registry,
  zipPath
}) {
  if (!DNS_LABEL_RE.test(appId)) {
    throw new Error("appId inválido. Use DNS label: ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$");
  }

  if (!registry) {
    throw new Error("Campo registry é obrigatório.");
  }

  await validateZipHasRootDockerfile(zipPath);

  const sha = await sha256File(zipPath);
  const buildId = `bld_${nanoid(10).toLowerCase()}`;
  const shortSha = sha.slice(0, 12);
  const imageTag = withShaTag(registry, shortSha);

  const safeBuildSuffix = buildId.replace("_", "-").toLowerCase();
  const pvcName = `src-${safeBuildSuffix}`;
  const stagingPodName = `stage-${safeBuildSuffix}`;
  const jobName = `kaniko-${safeBuildSuffix}`;

  const labels = buildLabels({ buildId, tenantId, appId });

  const build = createBuild({
    buildId,
    tenantId,
    appId,
    registry,
    imageTag,
    namespace: BUILD_NAMESPACE,
    pvcName,
    stagingPodName,
    jobName
  });

  appendBuildLog(buildId, "Build recebido pela API.", "api");
  appendBuildLog(buildId, `Image tag calculada: ${imageTag}`, "api");

  try {
    await ensureBuildNamespace();

    appendBuildLog(buildId, `Criando PVC ${pvcName}.`, "k8s");
    await ignoreAlreadyExists(
      coreApi.createNamespacedPersistentVolumeClaim({
        namespace: BUILD_NAMESPACE,
        body: makeBuildPvc({ pvcName, labels })
      })
    );

    appendBuildLog(buildId, `Criando staging pod ${stagingPodName}.`, "k8s");
    await ignoreAlreadyExists(
      coreApi.createNamespacedPod({
        namespace: BUILD_NAMESPACE,
        body: makeStagingPod({
          podName: stagingPodName,
          pvcName,
          labels
        })
      })
    );

    appendBuildLog(buildId, "Aguardando staging pod ficar Running.", "watch");
    await waitForPodRunning(stagingPodName, 120);

    appendBuildLog(buildId, "Copiando ZIP para o PVC via pod/exec.", "k8s");
    await copyZipToStagingPod({
      podName: stagingPodName,
      zipPath
    });

    appendBuildLog(buildId, "Removendo staging pod.", "k8s");
    await ignoreNotFound(
      coreApi.deleteNamespacedPod({
        namespace: BUILD_NAMESPACE,
        name: stagingPodName
      })
    );

    appendBuildLog(buildId, `Criando Kaniko Job ${jobName}.`, "k8s");
    await batchApi.createNamespacedJob({
      namespace: BUILD_NAMESPACE,
      body: makeKanikoJob({
        jobName,
        pvcName,
        imageTag,
        labels
      })
    });

    patchBuild(buildId, { status: "running" });

    watchKanikoJob(buildId).catch((err) => {
      appendBuildLog(buildId, `Erro no watch do Job: ${err.message}`, "watch");
    });

    watchKanikoPod(buildId).catch((err) => {
      appendBuildLog(buildId, `Erro no watch do Pod: ${err.message}`, "watch");
    });

    return build;
  } catch (err) {
    patchBuild(buildId, {
      status: "failed",
      error: err.message,
      finishedAt: new Date().toISOString()
    });

    appendBuildLog(buildId, `Build falhou: ${err.message}`, "api");
    throw err;
  }
}

async function ensureBuildNamespace() {
  await ignoreAlreadyExists(
    coreApi.createNamespace({
      body: {
        metadata: {
          name: BUILD_NAMESPACE
        }
      }
    })
  );
}

function withShaTag(imageRepo, shortSha) {
  const lastSlash = imageRepo.lastIndexOf("/");
  const lastColon = imageRepo.lastIndexOf(":");
  const hasTag = lastColon > lastSlash;
  const repoWithoutTag = hasTag ? imageRepo.slice(0, lastColon) : imageRepo;

  return `${repoWithoutTag}:sha-${shortSha}`;
}

async function sha256File(filePath) {
  const hash = crypto.createHash("sha256");

  await new Promise((resolve, reject) => {
    fs.createReadStream(filePath)
      .on("data", (chunk) => hash.update(chunk))
      .on("error", reject)
      .on("end", resolve);
  });

  return hash.digest("hex");
}

async function validateZipHasRootDockerfile(filePath) {
  await new Promise((resolve, reject) => {
    let hasDockerfile = false;

    yauzl.open(filePath, { lazyEntries: true }, (err, zip) => {
      if (err) return reject(new Error("Arquivo enviado não é um ZIP válido."));

      zip.readEntry();

      zip.on("entry", (entry) => {
        const name = entry.fileName.replaceAll("\\", "/");

        if (
          name.startsWith("/") ||
          name.includes("../") ||
          name === ".."
        ) {
          zip.close();
          return reject(new Error(`ZIP contém path inseguro: ${entry.fileName}`));
        }

        if (name === "Dockerfile") {
          hasDockerfile = true;
        }

        zip.readEntry();
      });

      zip.on("end", () => {
        if (!hasDockerfile) {
          return reject(new Error("Dockerfile obrigatório na raiz do ZIP."));
        }

        resolve();
      });

      zip.on("error", reject);
    });
  });
}

async function waitForPodRunning(podName, timeoutSeconds) {
  const existing = await ignoreNotFound(
    coreApi.readNamespacedPod({
      namespace: BUILD_NAMESPACE,
      name: podName
    })
  );

  if (existing?.status?.phase === "Running") return;

  await new Promise(async (resolve, reject) => {
    let req;
    const timer = setTimeout(() => {
      stopK8sWatch(req);
      reject(new Error(`Timeout aguardando Pod ${podName} ficar Running.`));
    }, timeoutSeconds * 1000);

    req = await watchApi.watch(
      `/api/v1/namespaces/${BUILD_NAMESPACE}/pods`,
      {
        fieldSelector: `metadata.name=${podName}`,
        timeoutSeconds
      },
      (_type, pod) => {
        const phase = pod?.status?.phase;

        if (phase === "Running") {
          clearTimeout(timer);
          stopK8sWatch(req);
          resolve();
        }

        if (phase === "Failed" || phase === "Succeeded") {
          clearTimeout(timer);
          stopK8sWatch(req);
          reject(new Error(`Pod ${podName} terminou em phase=${phase}.`));
        }
      },
      (err) => {
        clearTimeout(timer);
        if (err) reject(err);
      }
    );
  });
}

async function copyZipToStagingPod({ podName, zipPath }) {
  await new Promise((resolve, reject) => {
    const stdout = new PassThrough();
    const stderr = new PassThrough();
    const stdin = fs.createReadStream(zipPath);

    let stderrText = "";

    stdout.on("data", (chunk) => {
      appendBuildLogFromStagingPod(podName, chunk.toString());
    });

    stderr.on("data", (chunk) => {
      stderrText += chunk.toString();
    });

    execApi.exec(
      BUILD_NAMESPACE,
      podName,
      "stager",
      ["sh", "-c", "cat > /workspace/source.zip && ls -lh /workspace/source.zip"],
      stdout,
      stderr,
      stdin,
      false,
      (status) => {
        if (status?.status === "Success" || status?.code === 0) {
          resolve();
        } else {
          reject(
            new Error(
              `Falha copiando ZIP para staging pod. ${stderrText || JSON.stringify(status)}`
            )
          );
        }
      }
    );
  });
}

function appendBuildLogFromStagingPod(podName, text) {
  for (const build of ["noop"]) {
    void build;
  }

  const lines = text.split("\n").filter(Boolean);
  for (const line of lines) {
    // Log apenas técnico; o buildId é conhecido no fluxo principal pelos watchers.
    console.debug(`[${podName}] ${line}`);
  }
}

async function watchKanikoJob(buildId) {
  const build = getBuildInternal(buildId);
  if (!build) return;

  appendBuildLog(buildId, `Iniciando watch do Job ${build.jobName}.`, "watch");

  let req;

  req = await watchApi.watch(
    `/apis/batch/v1/namespaces/${BUILD_NAMESPACE}/jobs`,
    {
      fieldSelector: `metadata.name=${build.jobName}`,
      timeoutSeconds: Number(process.env.BUILD_TIMEOUT_SECONDS || 1800)
    },
    (_type, job) => {
      const status = job?.status || {};
      const conditions = status.conditions || [];

      const failed = conditions.find(
        (c) => c.type === "Failed" && c.status === "True"
      );

      const complete = conditions.find(
        (c) => c.type === "Complete" && c.status === "True"
      );

      appendBuildEvent(buildId, {
        kind: "Job",
        name: job.metadata?.name,
        active: status.active || 0,
        succeeded: status.succeeded || 0,
        failed: status.failed || 0
      });

      if (complete) {
        patchBuild(buildId, {
          status: "success",
          finishedAt: new Date().toISOString()
        });

        appendBuildLog(buildId, `Build concluído: ${build.imageTag}`, "kaniko");
        stopK8sWatch(req);
      }

      if (failed) {
        patchBuild(buildId, {
          status: "failed",
          error: failed.message || failed.reason || "Kaniko Job failed",
          finishedAt: new Date().toISOString()
        });

        appendBuildLog(
          buildId,
          `Build falhou: ${failed.message || failed.reason || "Job failed"}`,
          "kaniko"
        );

        stopK8sWatch(req);
      }
    },
    (err) => {
      if (err) {
        appendBuildLog(buildId, `Watch do Job encerrou com erro: ${err.message}`, "watch");
      }
    }
  );
}

async function watchKanikoPod(buildId) {
  const build = getBuildInternal(buildId);
  if (!build) return;

  appendBuildLog(buildId, "Iniciando watch do Pod do Kaniko.", "watch");

  let logStarted = false;
  let eventsStarted = false;
  let req;

  req = await watchApi.watch(
    `/api/v1/namespaces/${BUILD_NAMESPACE}/pods`,
    {
      labelSelector: `workerless.io/build-id=${buildId}`,
      timeoutSeconds: Number(process.env.BUILD_TIMEOUT_SECONDS || 1800)
    },
    (_type, pod) => {
      const podName = pod.metadata?.name;
      const phase = pod.status?.phase;

      if (!podName) return;

      patchBuild(buildId, { podName });

      appendBuildEvent(buildId, {
        kind: "Pod",
        name: podName,
        phase
      });

      if (!eventsStarted) {
        eventsStarted = true;
        watchPodEvents(buildId, podName).catch((err) => {
          appendBuildLog(buildId, `Watch de events falhou: ${err.message}`, "watch");
        });
      }

      const hasKanikoContainer = pod.spec?.containers?.some(
        (container) => container.name === "kaniko"
      );

      if (hasKanikoContainer && !logStarted) {
        logStarted = true;

        followKanikoLogs(buildId, podName).catch((err) => {
          appendBuildLog(buildId, `Log stream falhou: ${err.message}`, "logs");
        });
      }

      if (phase === "Succeeded" || phase === "Failed") {
        stopK8sWatch(req);
      }
    },
    (err) => {
      if (err) {
        appendBuildLog(buildId, `Watch do Pod encerrou com erro: ${err.message}`, "watch");
      }
    }
  );
}

async function followKanikoLogs(buildId, podName) {
  appendBuildLog(buildId, `Seguindo logs do Pod ${podName}.`, "logs");

  const stream = new PassThrough();

  stream.on("data", (chunk) => {
    const lines = chunk.toString().split("\n").filter(Boolean);

    for (const line of lines) {
      appendBuildLog(buildId, line, "kaniko");
    }
  });

  await logApi.log(
    BUILD_NAMESPACE,
    podName,
    "kaniko",
    stream,
    {
      follow: true,
      pretty: false,
      timestamps: true
    }
  );
}

async function watchPodEvents(buildId, podName) {
  let req;

  req = await watchApi.watch(
    `/api/v1/namespaces/${BUILD_NAMESPACE}/events`,
    {
      fieldSelector: `involvedObject.name=${podName}`,
      timeoutSeconds: Number(process.env.BUILD_TIMEOUT_SECONDS || 1800)
    },
    (_type, event) => {
      appendBuildEvent(buildId, {
        kind: "Event",
        name: event.metadata?.name,
        reason: event.reason,
        message: event.message,
        type: event.type,
        count: event.count
      });
    },
    (err) => {
      if (err) {
        appendBuildLog(buildId, `Watch de Events encerrou: ${err.message}`, "watch");
      }
    }
  );
}
```

Eventos Kubernetes são úteis para diagnóstico, mas devem ser tratados como sinal suplementar, porque a própria API diz que eventos têm retenção limitada e podem mudar. ([Kubernetes][3])

---

## 7. Rotas HTTP

`src/builds/build-routes.js`

```js
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import express from "express";
import multer from "multer";

import { getBuild, onBuild } from "./build-store.js";
import { startKanikoZipBuild } from "./build-service.js";

const upload = multer({
  dest: path.join(os.tmpdir(), "workerless-builds"),
  limits: {
    fileSize: Number(process.env.MAX_BUILD_ZIP_BYTES || 100 * 1024 * 1024)
  }
});

export function buildRoutes() {
  const router = express.Router();

  router.post(
    "/tenants/:tenantId/workloads/:appId/build",
    upload.single("source"),
    async (req, res, next) => {
      try {
        if (!req.file) {
          return res.status(400).json({
            error: "Campo multipart source é obrigatório."
          });
        }

        const build = await startKanikoZipBuild({
          tenantId: req.params.tenantId,
          appId: req.params.appId,
          registry: req.body.registry,
          zipPath: req.file.path
        });

        fs.rm(req.file.path, { force: true }, () => {});

        res.status(202).json({
          buildId: build.buildId,
          status: build.status,
          startedAt: build.startedAt
        });
      } catch (err) {
        if (req.file?.path) {
          fs.rm(req.file.path, { force: true }, () => {});
        }

        next(err);
      }
    }
  );

  router.get("/builds/:buildId", async (req, res) => {
    const build = getBuild(req.params.buildId);

    if (!build) {
      return res.status(404).json({
        error: "Build não encontrado."
      });
    }

    res.json(build);
  });

  router.get("/builds/:buildId/watch", async (req, res) => {
    const build = getBuild(req.params.buildId);

    if (!build) {
      return res.status(404).json({
        error: "Build não encontrado."
      });
    }

    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no"
    });

    const send = (payload) => {
      res.write(`event: build\n`);
      res.write(`data: ${JSON.stringify(payload)}\n\n`);
    };

    send(build);

    const off = onBuild(req.params.buildId, send);

    req.on("close", () => {
      off();
      res.end();
    });
  });

  return router;
}
```

---

## 8. Server Express

`src/server.js`

```js
import express from "express";
import { buildRoutes } from "./builds/build-routes.js";

const app = express();

const ADMIN_KEY = process.env.ADMIN_KEY || "troca-isso-em-producao";

app.use(express.json());

app.use((req, res, next) => {
  if (req.header("X-Admin-Key") !== ADMIN_KEY) {
    return res.status(401).json({
      error: "X-Admin-Key inválido."
    });
  }

  next();
});

app.use(buildRoutes());

app.use((err, _req, res, _next) => {
  console.error(err);

  res.status(500).json({
    error: err.message || "Erro interno."
  });
});

const port = Number(process.env.PORT || 3000);

app.listen(port, () => {
  console.log(`workerless-control-plane ouvindo em :${port}`);
});
```

---

## 9. RBAC mínimo para o control-plane criar e observar builds

Ajuste o namespace/serviceAccount do seu control-plane.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: build-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: workerless-build-controller
  namespace: build-system
rules:
  - apiGroups: [""]
    resources:
      - pods
      - pods/log
      - pods/exec
      - persistentvolumeclaims
      - events
    verbs:
      - get
      - list
      - watch
      - create
      - delete
  - apiGroups: ["batch"]
    resources:
      - jobs
    verbs:
      - get
      - list
      - watch
      - create
      - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: workerless-build-controller
  namespace: build-system
subjects:
  - kind: ServiceAccount
    name: workerless-control-plane
    namespace: workerless-system
roleRef:
  kind: Role
  name: workerless-build-controller
  apiGroup: rbac.authorization.k8s.io
```

O secret do registry deve existir no `build-system`:

```bash
kubectl -n build-system create secret docker-registry registry-credentials \
  --docker-server=ghcr.io \
  --docker-username=SEU_USUARIO \
  --docker-password=SEU_TOKEN \
  --docker-email=dev@example.com
```

---

## 10. Como ver o que está acontecendo

Polling compatível com seu cenário:

```bash
watch -n 3 "curl -s http://localhost:3000/builds/${BUILD_ID} \
  -H 'X-Admin-Key: troca-isso-em-producao' \
  | jq '{status, imageTag, podName, logs: .logs[-10:], events: .events[-10:]}'"
```

Stream em tempo real via SSE:

```bash
curl -N "http://localhost:3000/builds/${BUILD_ID}/watch" \
  -H "X-Admin-Key: troca-isso-em-producao"
```

Debug direto no cluster:

```bash
kubectl get pods -w -n build-system \
  -l workerless.io/build-id=${BUILD_ID}

kubectl logs -f -n build-system \
  -l workerless.io/build-id=${BUILD_ID} \
  -c kaniko
```

Resultado final esperado em `GET /builds/:id`:

```json
{
  "buildId": "bld_abc123",
  "status": "success",
  "imageTag": "ghcr.io/minha-org/meu-consumer:sha-a1b2c3d4e5f6",
  "finishedAt": "2026-07-01T12:00:00.000Z",
  "logs": [],
  "events": []
}
```

Com isso, o `Passo 3` do cenário passa a funcionar com `watch curl`, e o endpoint `/builds/:id/watch` permite UI/CLI em tempo real sem precisar ficar consultando a API a cada poucos segundos.

[1]: https://kubernetes.io/docs/reference/using-api/api-concepts/?utm_source=chatgpt.com "Kubernetes API Concepts"
[2]: https://github.com/GoogleContainerTools/kaniko?utm_source=chatgpt.com "GoogleContainerTools/kaniko: Build Container Images In ..."
[3]: https://kubernetes.io/docs/reference/kubernetes-api/core/event-v1/?utm_source=chatgpt.com "Event"
