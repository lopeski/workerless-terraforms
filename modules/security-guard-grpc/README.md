# modules/security-guard-grpc

Runs the Workerless Security Guard's gRPC admin API as a `ClusterIP`-only Deployment, never exposed via NodePort, LoadBalancer, or Ingress. The only intended path in is through `modules/tailscale-operator`'s ProxyGroup, bound to this module's Service by name (`guard_grpc_service_name`/`guard_grpc_namespace`/`guard_grpc_port`).

## Two independent PKI trees

This module owns **two separate cert-manager CA domains**. They never share a root, by design (spec: "CA de clientes Mac separada de CAs genéricas do cluster").

```
cert-manager namespace                          security-guard-grpc namespace
┌─────────────────────────────┐                  ┌──────────────────────────┐
│ Issuer (selfSigned)          │                  │                          │
│   └─ Certificate (isCA)      │──ClusterIssuer──▶│ Certificate (leaf)        │
│      "server-root-ca"        │  "server-ca"     │  dnsNames=[tailnet_hostname]│
│                              │                  │  auto-renews             │
├─────────────────────────────┤                  │                          │
│ Issuer (selfSigned)          │                  │                          │
│   └─ Certificate (isCA)      │──ClusterIssuer──▶│  (no leaf — see below)   │
│      "mac-client-root-ca"    │  "mac-clients"   │                          │
└─────────────────────────────┘                  └──────────────────────────┘
```

- **Server-cert tree**: fully Terraform-managed end to end. The leaf `Certificate` (`dnsNames = [var.tailnet_hostname]`) auto-renews via cert-manager (`duration`/`renewBefore`), mounted read-only (`0440`) into the Deployment.
- **Mac-client tree**: Terraform stops at the `ClusterIssuer` (output as `mac_client_cluster_issuer_name`). **No per-device leaf `Certificate` is ever created here.** The admin CLI issues per-device certificates out-of-band (e.g. a `CertificateRequest` against this `ClusterIssuer`), which is what keeps device private keys out of Terraform state entirely — Terraform never sees them.

Both root CAs' `Certificate` resources are created in `var.cert_manager_namespace` (default `cert-manager`), not in this module's own namespace. This is required by cert-manager's `ClusterIssuer.spec.ca.secretName`, which resolves against cert-manager's `clusterResourceNamespace` (defaults to the namespace cert-manager itself runs in). The namespace must already exist — `platform/<env>` wires `depends_on = [module.core_platform]` for that reason.

## NetworkPolicy vs. RBAC — read this before assuming the Secret is "protected by NetworkPolicy"

The default-deny + allow NetworkPolicy pair here only shapes **L3/L4 reachability** — which namespaces/CIDRs the gRPC pods can talk to. It is **not** what prevents some other workload from reading the `guard-grpc-server-tls` or `guard-grpc-db-credentials` Secrets. That protection is **RBAC**: no `Role`/`RoleBinding` anywhere in this cluster grants `get` on these specific Secret names outside the kubelet's own Secret-volume mechanism for the owning Pod. Treat the NetworkPolicy as defense-in-depth against lateral network movement, not as a Secret-access control.

## Probe design

All three probes (`startup`, `readiness`, `liveness`) are gRPC health checks against `guard_grpc_port` only. None of them depend on the database or any external service — a transient outage of the security database must not cause a restart loop (spec §11: "Probes não devem depender de provedores externos lentos").

## Variables of note

- `tailnet_hostname` — required, no default. Must match the MagicDNS name the Tailscale ProxyGroup will expose.
- `db_egress_cidr` — required, validated to reject a bare `0.0.0.0/0`.
- `authorized_egress_rules` — same shape as `modules/workload`'s `event_source_egress_rules`; also rejects bare `0.0.0.0/0` entries.
- `tailscale_namespace` — default `"tailscale"`; the only namespace the allow-NetworkPolicy ever accepts ingress from.

## Outputs

Only non-sensitive names: `guard_grpc_service_name`, `guard_grpc_namespace`, `guard_grpc_port`, `mac_client_cluster_issuer_name`. No certificate, key, or credential material is ever output.
