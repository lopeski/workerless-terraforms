# modules/tailscale-operator

Installs the Tailscale Kubernetes Operator and an HA `kube-apiserver`
`ProxyGroup` for private administrative access. Optionally, when
`guard_grpc_proxy_enabled` is true, it also forwards the
`security-guard-grpc` module's `ClusterIP` Service onto the tailnet. Terraform
owns the full tailnet ACL. No NodePort, public LoadBalancer, Ingress, Gateway,
or public DNS record is created.

## Kubernetes API access

The `workerless-prod` ProxyGroup runs in `auth` mode with at least two replicas
in production. Tagged client devices are impersonated with their Tailscale
tags as Kubernetes groups. Each entry in `tailscale_allowed_device_tags` gets
a `ClusterRoleBinding` to `cluster-admin`; use dedicated tags assigned only to
managed administrator devices. The tailnet policy allows those tags to reach
the proxy tag on TCP 443 and auto-approves the Tailscale Service advertised by
the ProxyGroup.

After apply, run `kubectl get proxygroup workerless-prod` and then
`tailscale configure kubeconfig https://<URL-from-status>` from an authorized
Tailscale client.

The dedicated `tailscale` namespace is labeled with Pod Security
`enforce=privileged`: current proxy pods need `/dev/net/tun` by default. The
exception is namespace-scoped and its NetworkPolicy still defaults to deny,
then permits only DNS, the Kubernetes API, Tailscale control/DERP traffic and,
when enabled, the gRPC backend.

## Two separate Tailscale credential planes

This module touches Tailscale in two structurally different ways, using two
different credentials that must never be confused:

1. **Terraform provider credentials** (`tailscale_tf_oauth_client_id` /
   `tailscale_tf_oauth_client_secret`, both `sensitive = true`). The Terraform
   *process itself* authenticates to the Tailscale API with these to own the
   `tailscale_acl` resource (a full-replace of the tailnet policy file) and to
   read tailnet settings. Sourced like `hcloud_token` — `TF_VAR_*` / a CI
   secret — never through ExternalSecrets, because nothing inside the cluster
   ever needs this credential. **These variables and the `provider
   "tailscale" {}` block live in `platform/<env>`, not in this module** —
   same convention as `modules/core-platform`/`modules/workload` never
   declaring their own `provider "kubernetes"/"helm"/"kubectl"` blocks. This
   module's resources use the inherited default `tailscale` provider.
2. **In-cluster Operator OAuth client** (`tailscale_oauth_secret_ref`, an
   ExternalSecret pointer). The Operator *Pod* authenticates to Tailscale with
   this to register itself and spin up ProxyGroup devices. It is materialized
   as a Kubernetes Secret named literally `operator-oauth` (keys `client_id`/
   `client_secret`) via an `ExternalSecret` this module creates — the
   `tailscale-operator` Helm chart auto-discovers a Secret with that exact
   name in its own namespace when no `oauth.clientId`/`oauth.clientSecret`
   Helm value is set, so the secret value never flows through a `set`/
   `set_sensitive` Helm argument or through Terraform state as a Helm value.

These two credentials are typically issued from two different Tailscale OAuth
clients with different scopes (the Terraform one needs `acl:write`-equivalent
scope; the Operator one needs device-registration scope).

## Full-ACL ownership warning

`tailscale_acl.guard` replaces the **entire** tailnet policy file on every
apply. Once this module is enabled against a tailnet, that tailnet's policy
is sourced exclusively from this Terraform code — any manual edit made in the
Tailscale admin console (another tag, another grant, an auto-approver) will
be silently reverted on the next `terraform apply`. Run this module only
against a tailnet dedicated to (or primarily reserved for) the Security
Guard use case, or extend `local.tailnet_acl` to merge in any other
infrastructure-as-code-managed tailnet configuration before adopting it
against a shared tailnet.

Import the existing policy before the first apply:

```bash
terraform -chdir=platform/hetzner import \
  'module.tailscale_operator[0].tailscale_acl.guard' acl
```

The Terraform OAuth client needs the `policy_file` scope.

The ACL itself is a single `grants` entry: only `tailscale_allowed_device_tags`
can reach `tailscale_proxy_tag` devices, and only on `guard_grpc_port`/tcp.
Tailscale ACLs default-deny anything not explicitly granted, so this one
entry is the entire authorization surface — no separate "deny" entries exist
or are needed.

## How the gRPC Service reaches the tailnet without becoming a LoadBalancer

`modules/security-guard-grpc` keeps its own Service a plain `ClusterIP`. This
module creates a **separate** `ExternalName` Service
(`guard-grpc-tailnet-proxy`) in the `tailscale` namespace whose
`externalName` is the gRPC Service's cluster-internal DNS name
(`guard-grpc.security-guard-grpc.svc.cluster.local`), annotated with
`tailscale.com/expose: "true"` and `tailscale.com/proxy-group: <name>`. The
Operator reconciles this into a proxy that forwards tailnet TCP connections
into the cluster and onward to the gRPC ClusterIP. This is the officially
documented `ExternalName` + `tailscale.com/expose` pattern Tailscale publishes
for reaching a TCP endpoint reachable from inside the cluster (its published
example targets an external database over VPC peering) — here it is applied
to an in-cluster `ClusterIP` backend instead. **This specific application
(in-cluster backend, not an external DB) was not found in Tailscale's own
published examples during implementation and should be verified end-to-end
against a real tailnet (connect from an authorized device, confirm the
hostname resolves and the TCP proxy reaches the gRPC Service) before being
relied on in production.** If it doesn't work as expected, the fallback is to
have `security-guard-grpc` annotate its own Service directly with
`spec.type = "LoadBalancer"` + `spec.loadBalancerClass = "tailscale"` (the
Tailscale-documented pattern that unambiguously works) — note that even then
no real cloud load balancer is ever provisioned, because no Hetzner
cloud-controller-manager is installed in this cluster to fulfill a
`LoadBalancer` Service; the Tailscale Operator's own controller is the only
thing that reconciles it, and it provisions a tailnet device, not a public IP.

At no point does this module or `security-guard-grpc` create an `Ingress`,
`Gateway`, `NodePort`, or public DNS record.

## Hostname / certificate SAN coordination

`security-guard-grpc`'s server certificate SAN (`var.tailnet_hostname`) must
match the MagicDNS hostname Tailscale assigns to the forwarding Service.
Tailscale's default naming convention is `<namespace>-<service-name>`
(here, `tailscale-guard-grpc-tailnet-proxy`), suffixed with the tailnet's own
`.ts.net` domain. Set `tailscale_hostname_override` on this module if you
need a specific hostname instead, and keep it in sync with whatever is passed
as `tailnet_hostname` to `security-guard-grpc` — `platform/<env>` is
responsible for passing a consistent literal to both modules.

## HA

`proxy_group_replicas` must be `>= 2` whenever `is_production = true`
(enforced by variable validation), matching spec's "ProxyGroup HA em
produção" requirement. `proxy_group.spec.type = "ingress"`: proxies accept
tailnet-originated connections and forward them in, as opposed to `egress`
(cluster-initiated outbound) or `kube-apiserver` modes.

## Variables of note

- `tailscale_operator_enabled` — the caller (`platform/<env>`) must gate
  module instantiation with `count`/`for_each` on this flag; this module does
  not no-op internally, since the `tailscale` provider block always attempts
  to configure itself.
- `tailscale_oauth_secret_ref` — reuses `modules/workload`'s
  `external_secret_ref` object shape/validation verbatim.
- `tailnet` — defaults to `"-"`, which the Tailscale provider resolves to
  whichever tailnet owns the supplied OAuth client credentials; override only
  if managing a tailnet the credential doesn't default to.

## Outputs

Only names, never credentials or tokens: `tailscale_operator_namespace`,
`proxy_group_name`, `tailnet_acl_tags`, `guard_grpc_tailnet_proxy_service_name`.
