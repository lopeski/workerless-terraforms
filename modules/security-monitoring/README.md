# modules/security-monitoring

Falco (syscall/runtime detection) + Vector (log/alert pipeline) + a Kubernetes
Audit webhook receiver + a narrowly-scoped security collector, all inside one
namespace (`var.namespace`, default `security-monitoring`).

## Required cross-module follow-up (not covered by this module)

**Kyverno's `pss-baseline` ClusterPolicy** (in `modules/core-platform/main.tf`)
validates every namespace *except* an explicit exclusion list
(`namespaceSelector.matchExpressions`, currently `kube-system`, `kube-public`,
`kube-node-lease`, `kyverno`, `monitoring`). Falco's DaemonSet below runs with
host-level access that cannot satisfy even the `baseline` Pod Security
Standard (see "Falco pod-security deviation" below). The namespace label this
module sets (`pod-security.kubernetes.io/enforce: privileged`) only disables
the *native* PSS admission controller for this namespace — it does **not**
exempt the namespace from Kyverno's separate, cluster-wide admission policy.
**Before applying this module, `var.namespace`'s value (default
`security-monitoring`) must be added to that Kyverno ClusterPolicy's exclusion
list in `modules/core-platform/main.tf`**, or Falco's pods will be rejected at
admission regardless of anything in this module. This module cannot make that
change itself (the ClusterPolicy lives in a different module).

**Kubernetes Audit → this module's webhook** also requires a change outside
this module: `envs/hetzner/main.tf`'s node `user_data` needs
`--kube-apiserver-arg=audit-policy-file=...` /
`--kube-apiserver-arg=audit-webhook-config-file=...` flags plus the two
heredoc'd YAML files (mirroring how `registries.yaml` is already injected
there), with the audit policy excluding Secret request/response bodies. This
module only stands up the receiver side (`vector_aggregator`'s `audit_events`
source) — it has no way to reach into `envs/hetzner` to wire the control
plane itself, and that change cannot be retrofitted onto an already-running
cluster via `terraform apply` alone (it needs a manual SSH +
`systemctl restart k3s` step).

## Falco

- Chart: `falcosecurity/falco` (`https://falcosecurity.github.io/charts`),
  pinned via `var.falco_chart_version` (default `9.2.0`, appVersion `0.45.0`
  at time of writing).
- **Digest pinning**: the chart's image helper always renders
  `<repository>:<tag>` — there is no separate `image.digest` field. This
  module pins by digest anyway by setting `image.repository =
  "falcosecurity/falco@sha256"` and `image.tag = var.falco_image_digest`
  (a bare 64-hex-char digest, validated), which the helper concatenates into
  `docker.io/falcosecurity/falco@sha256:<digest>` — a valid digest reference.
  `var.falco_image_digest` has no default; callers must pin explicitly.
- **Driver**: `var.falco_driver` is validated to `kmod` or `modern_ebpf` only.
  The chart's own values.yaml documents only these two plus `auto` as
  supported kinds; `auto` is excluded here because it resolves differently
  per node and isn't deterministic across a fleet. There is no distinct
  `ebpf` (non-modern) option in the current chart — the original plan draft
  listed one, but the actual chart doesn't expose it.
- **Custom rules**: `var.falco_custom_rules` (`map(string)`, filename →
  content) passes straight through to the chart's `customRules` value — keep
  these files under version control in whatever tfvars source feeds this
  variable.
- **Output channel — corrected from the original plan**: Falco has no gRPC
  *output* worth using here (its gRPC API is for local/sidecar consumers, not
  a push channel, and this chart version exposes no `grpc_output` TLS wiring
  suitable for mTLS to Vector). Instead, Falco pushes JSON alerts to Vector
  via its documented `http_output` channel with `mtls = true`, using a
  cert-manager-issued client certificate (`certs.existingClientSecret =
  "falco-vector-client-tls"`). Because cert-manager's `Certificate` resource
  always writes `tls.crt`/`tls.key`/`ca.crt` (it cannot rename those keys),
  `http_output.client_cert`/`client_key`/`ca_cert` are explicitly overridden
  to `/etc/falco/certs/client/tls.crt` etc. instead of the chart's own
  `client.crt`/`client.key` defaults (which only exist when Falco's chart
  generates the secret itself from inline values — not the case here).
- `podPriorityClassName = "system-node-critical"`.

### Falco pod-security deviation (documented, permanent, narrowly scoped)

Falco's DaemonSet needs `hostPID` and, depending on `var.falco_driver`,
either `privileged: true` (kmod) or specific elevated capabilities
(`CAP_SYS_RESOURCE`, `CAP_BPF`, `CAP_PERFMON`, `CAP_SYS_PTRACE` for
`modern_ebpf` with least-privilege mode) to read kernel syscall events. This
cannot fit any Pod Security Standard above `privileged`. The deviation is
scoped to exactly this DaemonSet's pods — no other workload in this
namespace (Vector, the collector) needs or receives elevated access. See the
Kyverno cross-module note above for the second half of what makes this
actually work at admission time.

## Vector

Two Helm releases from the same `vector` chart (`https://helm.vector.dev`,
pinned `var.vector_chart_version`, confirmed current `0.59.0`):

- **`vector-agent`** (`role: Agent` → DaemonSet): collects node-local logs
  and forwards them to the aggregator over the chart's own `vector` protocol
  (port 6000, cluster-internal, no mTLS — add TLS here if node log content
  warrants it beyond what the aggregator-side mTLS already protects).
- **`vector-aggregator`** (`role: Stateless-Aggregator` → **Deployment**, not
  the chart's `Aggregator` role, which maps to a **StatefulSet**). Nothing
  here needs stable network identity or a PVC per replica, so
  `Stateless-Aggregator` is the correct role for an HA, PDB/topology-spread
  friendly deployment; `var.vector_aggregator_replicas` (`>= 2`),
  `podDisruptionBudget.enabled`, and `topologySpreadConstraints` are all set.

### Pipeline (aggregator `customConfig`)

```
sources:
  falco_alerts   (http_server, TLS+mTLS, port 9000)   -- Falco's http_output
  audit_events   (http_server, TLS, port var.audit_webhook_port) -- k3s audit webhook
  from_agent     (vector protocol, port 6000)          -- vector-agent DaemonSet
transforms:
  redact            (remap)  -- strips known secret-bearing fields/headers
  route_quarantine  (route)  -- splits well-formed events (`.ok`) from anything
                                 the redact step's assumptions didn't match (`._unmatched`)
sinks:
  collector        (http, mTLS to the collector's ingest port, disk buffer,
                     when_full = drop_newest)
  kafka            (only when var.kafka_security_bootstrap_servers is non-empty;
                     SASL creds from the vector-kafka-credentials ExternalSecret,
                     disk buffer, when_full = drop_newest)
  quarantine_dlq   (file sink under /vector-data-dir/dlq/ — sanitized because it
                     sits downstream of `redact`; no built-in rotation, same
                     operational caveat Falco's own file_output carries)
  prometheus_metrics (internal_metrics -> prometheus_exporter :9598, scraped by
                      the native podMonitor.enabled on both releases)
```

Redaction is a floor, not a substitute for upstream data minimization — field
names in the `remap` script are best-effort and should be extended if the
actual Falco/audit payloads carry other sensitive fields in practice.

### Audit webhook — what this module does and doesn't do

`vector_aggregator`'s `audit_events` HTTP source is the receiver. Its
Service (created by the chart, `service.ports` explicitly set to match
`containerPorts`) is `ClusterIP` only — the NetworkPolicy
(`vector_aggregator_policy`) restricts ingress on `var.audit_webhook_port` to
`var.audit_ingestion_allowed_cidr` (validated `!= "0.0.0.0/0"`). This module
cannot make the k3s control plane actually send events here — see the
cross-module section above.

## Kubernetes Audit / internal mTLS CA

A single, self-contained CA chain (fully independent from any other module's
CA — `security-guard-grpc` has its own): self-signed `Issuer` → root
`Certificate` (`isCA: true`) → a second `Issuer` of type `ca` referencing that
root's Secret. **Implemented as a namespaced `Issuer`, not a `ClusterIssuer`**
— every consumer of this CA (Vector, Falco, the collector) lives in this same
namespace, and cert-manager's `ClusterIssuer` of type `ca` resolves its
`secretName` against the controller's single, cluster-wide "cluster resource
namespace" (default `kube-system`), which would mean promoting this CA's
Secret out of this module's own namespace for no benefit. Leaf certificates
issued from it: `vector-aggregator-server-tls`, `falco-vector-client-tls`,
`security-collector-server-tls`, `vector-collector-client-tls`. All use
ECDSA P-256 keys, 90-day duration with 15-day renew-before (cert-manager
rotates automatically).

## Collector

- `kubernetes_service_account_v1.security_collector`:
  `automount_service_account_token = false`.
- `kubernetes_cluster_role_v1.security_collector`: built from
  `var.collector_watched_resources` via `dynamic "rule"`. Three validations
  enforce the spec §3.4 contract: every verb is `get`/`list`/`watch` only, no
  entry's `resources` ever contains `"secrets"`, and neither `api_groups` nor
  `resources` may contain a wildcard (`"*"`). **Verify with**:
  ```
  kubectl auth can-i --as=system:serviceaccount:<namespace>:security-collector get secrets -A
  ```
  which must print `no`.
- **Lease coordination is namespaced, not cluster-scoped**: a
  `kubernetes_role_v1`/`kubernetes_role_binding_v1` pair scoped to
  `var.collector_coordination_namespace` (defaults to this module's own
  namespace) grants `get`/`update` on `coordination.k8s.io/leases` only
  within that one namespace — the collector has no cluster-wide reach for
  its own leader-election bookkeeping.
- `kubernetes_deployment_v1.security_collector`: standard non-root/seccomp/
  drop-ALL-caps/read-only-rootfs security context (same shape as
  `modules/workload`), startup/readiness/liveness HTTP probes via
  `var.collector_probes` (all optional — the collector's own health endpoint
  should not depend on Kafka/Postgres reachability, consistent with spec §11
  "Probes não devem depender de provedores externos lentos"), PDB when
  `var.collector_replicas > 1`.
- `kubernetes_service_v1.security_collector`: `ClusterIP` only, two named
  ports (`ingest` = `var.collector_ingest_port`, `metrics` =
  `var.collector_metrics_port`).
- `kubectl_manifest` `PodMonitor` feeding `kube-prometheus-stack`. Falco and
  both Vector releases use the charts' own native `serviceMonitor.create` /
  `podMonitor.enabled` values instead of a hand-rolled manifest.

**PodMonitor/ServiceMonitor names feeding `kube-prometheus-stack`**: Falco's
chart-native `ServiceMonitor` (release name `falco`), both Vector releases'
chart-native `PodMonitor`s (release names `vector-agent`,
`vector-aggregator`), and this module's own `security-collector` `PodMonitor`.

## Outputs

Names only — `namespace`, `collector_service_account_name`,
`collector_cluster_role_name`, `security_collector_service_name`,
`vector_aggregator_audit_webhook_service_name`. Nothing sensitive (no certs,
no Kafka credentials) is ever output.

## NetworkPolicies

One `default-deny-all` (empty `pod_selector`) plus four allow policies, each
scoped to a specific component's own selector label (`app.kubernetes.io/name`
or `.../instance`) rather than one blanket namespace-wide allow — this
namespace hosts three workloads with materially different legitimate flows:

| Policy | Scope | Allows |
|---|---|---|
| `falco-egress-allow` | Falco pods | → vector-aggregator:9000, DNS |
| `vector-agent-egress-allow` | vector-agent pods | → vector-aggregator:6000, DNS |
| `vector-aggregator-allow` | vector-aggregator pods | ingress from Falco/agent/audit-CIDR/`monitoring`; egress → collector ingest port, Kafka (only when enabled), DNS |
| `security-collector-allow` | collector pods | ingress from vector-aggregator and `monitoring`; egress → kube-apiserver (6443), DNS |

No policy anywhere grants ingress from outside this namespace except the
`monitoring` namespace (metrics scrape) and the explicit audit-ingestion
CIDR.
