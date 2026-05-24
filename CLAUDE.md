# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Terraform IaC project that provisions a local Kubernetes cluster demonstrating event-driven autoscaling. It creates a k3d cluster, deploys KEDA and RabbitMQ, and runs a worker consumer that scales (0–10 replicas) based on RabbitMQ queue length.

## Commands

```bash
# Initialize providers
terraform init

# Preview changes
terraform plan

# Apply infrastructure
terraform apply

# Tear down
terraform destroy
```

## Architecture

Single `startbuild.tf` file containing all resources:

1. **k3d cluster** (`null_resource`) — creates a local Kubernetes cluster (`k3d-local-rock`) via `local-exec`, API on port 6550
2. **KEDA** (Helm chart 2.19.0) — deployed to `keda` namespace for event-driven scaling
3. **RabbitMQ** (Bitnami Helm chart) — deployed to `brokers` namespace; queue `minha-fila-de-eventos`, credentials `user/password`
4. **Worker Deployment** (`kubernetes_deployment`) — consumer app in `default` namespace, scales 0–10 pods via KEDA `ScaledObject` when queue length > 5

Resource creation order enforced via `depends_on`: k3d cluster → RabbitMQ → Worker/KEDA.

Provider config (kubeconfig path, context) hard-coded to `k3d-local-rock` cluster.

## Key Values

| Item | Value |
|------|-------|
| k3d cluster name | `k3d-local-rock` |
| k3d API port | `6550` |
| RabbitMQ namespace | `brokers` |
| RabbitMQ queue | `minha-fila-de-eventos` |
| KEDA namespace | `keda` |
| Scale trigger threshold | 5 messages |
| Max replicas | 10 |
