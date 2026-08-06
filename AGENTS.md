# Repository Guidelines

## Project Purpose

This repository is Terraform IaC for a Kubernetes-based platform that will evolve into a PaaS for event-driven consumer workloads. Users bring their consumer image and broker configuration, and the platform deploys the workload with secure defaults, observability, and KEDA autoscaling based on the user's broker signals, such as RabbitMQ queue length, Kafka consumer lag, Google Pub/Sub subscription size, or other supported scalers.

## Project Structure & Module Organization

This repository is Terraform IaC for Kubernetes platform provisioning. It is organized in three layers:

- `envs/<env>/`: physical infrastructure entrypoints. `envs/local` creates a k3d cluster; `envs/hetzner` creates the Hetzner/k3s base.
- `platform/<env>/`: provider configuration and orchestration for each environment. These wrappers call the shared modules.
- `modules/core-platform/`: shared platform resources, including KEDA, RabbitMQ, PostgreSQL, monitoring, Kyverno, and CoreDNS hardening.
- `modules/workload/`: application workload resources and KEDA `ScaledObject`.

Example variable files live at `platform/*/terraform.tfvars.example`. Real `terraform.tfvars` files are local-only and must not be committed.

## Build, Test, and Development Commands

- `./build.local.sh`: formats, initializes, validates, plans, and applies `envs/local` followed by `platform/local`.
- `./build.hetzner.sh`: same workflow for Hetzner; requires `TF_VAR_hcloud_token`.
- `terraform fmt -check <dir>`: verify formatting for a specific Terraform directory.
- `terraform validate`: run inside an initialized Terraform directory to validate configuration.
- `terraform plan -out=tfplan`: create a reviewed execution plan before applying.

Destroy in reverse order, for example: `cd platform/local && terraform destroy`, then `cd envs/local && terraform destroy`.

## Coding Style & Naming Conventions

Use standard Terraform formatting via `terraform fmt`. Keep resources grouped by concern, and prefer explicit module inputs/outputs over path-based coupling. Use lowercase, underscore-separated Terraform names such as `core_platform`, `rabbitmq_password`, and `cluster_service_cidr`. Keep sensitive variables marked with `sensitive = true`, and pass chart credentials through sensitive mechanisms.

## Testing Guidelines

There is no separate unit test suite in this repository. Treat `terraform fmt -check`, `terraform init`, `terraform validate`, and `terraform plan` as the required verification path. Run plans from the relevant entrypoint (`envs/<env>` or `platform/<env>`) after changing providers, resources, variables, or module outputs.

## Commit & Pull Request Guidelines

Recent commits use concise, imperative messages, for example `Add Kubernetes resources for consumer app and supporting platform components`. Follow that style and keep each commit focused on one logical change.

Pull requests should describe the target environment, summarize Terraform changes, mention any required variables or secrets, and include the relevant `terraform plan` result or notable diff. Include screenshots only when changing user-visible Kubernetes dashboards or monitoring assets.

## Security & Configuration Tips

Never commit `terraform.tfvars`, state files, provider binaries, kubeconfigs, or cloud tokens. Provide secrets with `terraform.tfvars` or `TF_VAR_*` environment variables. Keep local and Hetzner state handling separate, and preserve the apply order: infrastructure first, platform second.
