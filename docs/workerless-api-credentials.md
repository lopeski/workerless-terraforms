# Workerless API Kubernetes credentials

The external integration preserves this contract:

- `KUBERNETES_SERVER_URL`
- `KUBERNETES_BEARER_TOKEN`
- `KUBERNETES_CA_DATA_BASE64`

In production, only `KUBERNETES_SERVER_URL` and
`KUBERNETES_CA_DATA_BASE64` enter the Nest Container. The Cloudflare outbound
handler owns `KUBERNETES_BEARER_TOKEN` and injects it, together with Access
service-token headers, only for the Kubernetes Tunnel hostname. Local
development may still pass all three values directly.

## Local development

`platform/local` creates a persistent `kubernetes.io/service-account-token`
Secret only for the disposable k3d cluster. `build.local.sh` writes the three
values to the gitignored, mode-0600 file
`platform/local/workerless-api.local.env`.

Regenerate that file after recreating the cluster:

```bash
./scripts/generate-workerless-api-env.sh
```

## Production token delivery

`platform/hetzner` creates `workerless-api-runtime`, its bootstrap ClusterRole,
and the namespaced runtime ClusterRole. It deliberately creates no token Secret
and exposes no credential output. CI must:

1. Authenticate with a separate administrative identity.
2. Receive a RoleBinding to `workerless-api-token-issuer` in
   `workerless-system`. The ClusterRole can issue tokens only for the
   `workerless-api-runtime` resource name.
3. Request a bounded token, for example:

   ```bash
   kubectl -n workerless-system create token workerless-api-runtime --duration=1h
   ```

4. Store it as the Worker secret `KUBERNETES_BEARER_TOKEN`. Do not pass it to
   the Container and do not restart the Nest process.
5. Rotate every 20 minutes. Publish only after successful issuance so failure
   leaves the prior token intact; alert on a failed scheduled run, which occurs
   before the one-hour token reaches 25% remaining lifetime.

The separate `cloudflared-connector` module runs the in-cluster connector. It
references a pre-existing Secret containing the Tunnel token; the token value
never enters this repository's Terraform state.

The CI identity and secret-manager binding are environment-specific and are
intentionally not created by this repository.

## Authorization model

Globally, the API may only `get/create` namespaces and create
`SelfSubjectAccessReview`. It has no access to platform namespaces. A
RoleBinding in each `wl-*` namespace grants the `workerless-tenant-runtime`
ClusterRole. Kyverno generates and synchronizes that binding, the build/runtime
ServiceAccounts, and default-deny NetworkPolicy; Terraform also creates these
objects for Terraform-managed workloads.

Kyverno Workerless policies default to `Audit`. After existing namespaces are
backfilled and API tests pass, set `workerless_policy_failure_action =
"Enforce"` in both platform module calls. Do not remove the controls during a
credential rollback; restore only the former binding for the shortest possible
period.

## API migration requirements

Before switching credentials, the API must derive namespace names server-side,
create namespaces with `GET` followed by `CREATE` on 404, wait for the generated
RoleBinding using `SelfSubjectAccessReview`, use server-side apply for managed
resources, and select only `workerless-runtime` or `workerless-build`. Client
provided namespaces must be ignored during compatibility and later removed.
