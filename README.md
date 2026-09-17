# Workerless Terraforms

Terraform infrastructure for a Kubernetes-based platform that runs event-driven consumer workloads and scales them automatically from broker demand.

This repository is the infrastructure foundation for a future PaaS. The goal is to let a user bring their consumer application and broker configuration, while the platform handles deployment, secure runtime defaults, observability, and autoscaling. The first Terraform-supported scaler contract is RabbitMQ queue depth via KEDA.

## What It Provisions

The project is split into infrastructure and platform layers:

- `envs/<env>/`: physical infrastructure entrypoints. `envs/local` creates a k3d cluster; `envs/hetzner` creates the Hetzner/k3s base.
- `platform/<env>/`: provider configuration and orchestration for each environment. These wrappers call the shared modules.
- `modules/core-platform/`: shared platform services, including KEDA, External Secrets Operator, monitoring, Kyverno, CoreDNS hardening, and the internal build registry.
- `modules/workload/`: the consumer workload, Kubernetes security defaults, network egress rules, External Secrets references, and the KEDA `ScaledObject`.

## Platform Direction

The intended product model is a PaaS for event consumers:

- The user provides a container image for their consumer.
- The user provides broker credentials and scaler configuration for their event source.
- The platform deploys the workload into Kubernetes with hardened defaults.
- KEDA watches the configured broker metric, such as RabbitMQ queue length, Kafka consumer lag, or another supported KEDA scaler.
- The platform scales the consumer from zero up to the configured maximum based on real backlog.

Tenant workloads are background consumers. Terraform does not expose them through `Service`, `Ingress`, or public HTTP routing. Optional HTTP probes and metrics ports are internal health/observability hooks only.

Today this is implemented as Terraform modules and environment wrappers. Over time, these modules can become the control plane behind a self-service product where users connect brokers and deploy consumers without operating Kubernetes directly.

## Supported Broker Model

Autoscaling is broker-driven through typed KEDA trigger descriptors. RabbitMQ is the local acceptance scenario, but the module does not hard-code KEDA to RabbitMQ. It generates the `ScaledObject` plus namespaced `TriggerAuthentication` internally; tenant workloads cannot submit arbitrary KEDA resource YAML or `ClusterTriggerAuthentication`.

Broker-specific credentials stay outside Terraform state. Workloads reference an `ExternalSecret`, and External Secrets Operator materializes the Kubernetes `Secret` from the configured `SecretStore` or `ClusterSecretStore`. The backend key and target Secret name are generated from `tenant_id` and `app_id`; users do not choose arbitrary secret paths. Real `terraform.tfvars` files are local-only and must not be committed.

## Development Commands

- `./build.local.sh`: formats, initializes, validates, plans, and applies `envs/local` followed by `platform/local`.
- `./build.hetzner.sh`: same workflow for Hetzner; requires `TF_VAR_hcloud_token`.
- `terraform fmt -check <dir>`: verify formatting for a specific Terraform directory.
- `terraform validate`: run inside an initialized Terraform directory to validate configuration.
- `terraform plan -out=tfplan`: create a reviewed execution plan before applying.

Destroy in reverse order:

```bash
cd platform/local && terraform destroy
cd envs/local && terraform destroy
```

## Configuration

Copy the relevant example file and provide real values locally:

```bash
cp platform/local/terraform.tfvars.example platform/local/terraform.tfvars
```

For Hetzner, also provide the cloud token:

```bash
export TF_VAR_hcloud_token=<your-token>
cp envs/hetzner/terraform.tfvars.example envs/hetzner/terraform.tfvars
cp platform/hetzner/terraform.tfvars.example platform/hetzner/terraform.tfvars
```

Set `admin_cidrs` in `envs/hetzner/terraform.tfvars` to real administrative CIDRs for SSH and the Kubernetes API. The configuration rejects `0.0.0.0/0`.

Do not commit secrets, state files, provider binaries, kubeconfigs, or cloud tokens.

### Workerless API local

`./build.local.sh` also creates the gitignored file
`platform/local/workerless-api.local.env`. It contains the Kubernetes endpoint,
CA and the persistent token of `workerless-api-runtime`, an identity limited to
namespace bootstrap and explicitly bound Workerless namespaces. No secret
manager is required locally.

Load it before starting the API:

```bash
set -a
source ../workerless-terraforms/platform/local/workerless-api.local.env
set +a
yarn start:dev
```

Alternatively, copy its three variables to the API `.env` or IDE Run
Configuration. Run `./scripts/generate-workerless-api-env.sh` again whenever
the k3d cluster is recreated. The legacy Terraform outputs `paas_sa_token` and
`paas_sa_token_base64` remain temporary local aliases and are deprecated.

Production does not create or export a persistent API token. See
`docs/workerless-api-credentials.md` for TokenRequest rotation and migration.

## Hetzner Etcd Restore

The Hetzner k3s servers write embedded etcd snapshots to `/var/lib/rancher/k3s/server/db/snapshots` on the configured cron schedule. Keep an out-of-band copy of these files and the k3s token from `/var/lib/rancher/k3s/server/token`; both are required for a reliable restore.

Minimum restore flow on a replacement bootstrap server:

```bash
systemctl stop k3s || true
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<k3s-version> K3S_TOKEN=<saved-token> sh -s - server \
  --cluster-init \
  --cluster-reset \
  --cluster-reset-restore-path /var/lib/rancher/k3s/server/db/snapshots/<snapshot-file> \
  --node-taint CriticalAddonsOnly=true:NoSchedule
```

After the restored bootstrap is healthy, recreate or rejoin the other servers and workers with the same token and private-network settings from `envs/hetzner/main.tf`, then verify `kubectl get nodes` and `kubectl get --raw /readyz`.
