# Workerless API Kubernetes credentials

The API always consumes the same contract:

- `KUBERNETES_SERVER_URL`
- `KUBERNETES_BEARER_TOKEN`
- `KUBERNETES_CA_DATA_BASE64`

It does not access a secret manager directly.

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

4. Store it in the production secret manager under the API's existing
   `KUBERNETES_BEARER_TOKEN` key and trigger a rolling restart.
5. Rotate before 50% of its lifetime and alert if 25% or less remains.

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
