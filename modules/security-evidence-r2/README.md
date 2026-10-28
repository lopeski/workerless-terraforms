# modules/security-evidence-r2

Dedicated, exclusive-per-environment Cloudflare R2 bucket for Workerless Security Guard
evidence, with a Bucket Lock enforcing a minimum retention period before any object can
be overwritten or deleted.

## What this module creates

- `cloudflare_r2_bucket.evidence` — a private bucket. No `cloudflare_r2_managed_domain`
  and no `cloudflare_r2_custom_domain` resource is ever created by this module. "No
  public domain" is satisfied **by omission** — there's nothing to misconfigure into
  public, because the resource that would expose it simply doesn't exist here.
- `cloudflare_r2_bucket_lock.evidence_retention` — one `Age`-type lock rule,
  `max_age_seconds = r2_evidence_retention_days * 86400`, scoped by `r2_evidence_key_prefix`.
  This is enforced server-side by Cloudflare: while an object is inside the lock window,
  R2 rejects overwrite and delete attempts outright, regardless of what credential or
  API call tries it.
- `cloudflare_r2_bucket_lifecycle.evidence_expiry` — a `delete_objects_transition` rule
  with `max_age = (r2_evidence_retention_days + 1) * 86400`, i.e. **strictly after** the
  lock period. This exists only to avoid unbounded accumulation of evidence past the
  required retention; the Bucket Lock above is what actually prevents early deletion —
  this rule cannot and does not race it.
- `kubectl_manifest.r2_evidence_external_secret` — an `ExternalSecret` CR materializing
  the Security Guard API's own R2 access-key credential into
  `var.r2_evidence_namespace`, backed by `var.r2_evidence_token_secret_ref`.

## Provider wiring (important — read before calling this module)

This module intentionally contains **no `provider "cloudflare" {}` block of its own**.
Terraform hard-errors ("Module is incompatible with count, for_each, and depends_on")
if a module with its own provider configuration is called with `count`/`for_each` — and
this module is meant to be instantiated conditionally (`count = var.r2_evidence_enabled ? 1 : 0`)
from `platform/<env>`. The caller must configure the provider and pass it explicitly:

```hcl
# platform/<env>/main.tf
provider "cloudflare" {
  alias     = "r2_evidence"
  api_token = var.cloudflare_r2_api_token # this module's own bootstrap credential
}

module "security_evidence_r2" {
  count  = var.r2_evidence_enabled ? 1 : 0
  source = "../../modules/security-evidence-r2"

  providers = {
    cloudflare = cloudflare.r2_evidence
  }

  cloudflare_account_id        = var.cloudflare_account_id
  r2_evidence_bucket_name      = var.r2_evidence_bucket_name
  r2_evidence_retention_days   = var.r2_evidence_retention_days
  r2_evidence_token_secret_ref = var.r2_evidence_token_secret_ref
  is_production                = var.is_production
}
```

`modules/cloudflare-operational-blocking` needs the exact same treatment with its **own**
alias (different Cloudflare token, same account) — do not reuse the `r2_evidence` alias
for it.

## Two separate Cloudflare credentials

- The Terraform-operator bootstrap credential (`var.cloudflare_r2_api_token` at
  `platform/<env>`, `sensitive = true`, supplied like `hcloud_token` via `TF_VAR_*`/CI
  secret) — broad enough to create/manage the bucket, lock, and lifecycle rule. **This is
  not the same token** as `modules/cloudflare-operational-blocking`'s own bootstrap
  credential — they are two distinct credentials, scoped independently, even though both
  target the same Cloudflare account.
- The R2 **access key** the Security Guard API actually uses at runtime to `PutObject`/
  `HeadObject` is never created by Terraform. It is provisioned out-of-band, scoped to
  put+head on this one bucket only (no bucket-wide `ListObjects` grant, since the API
  only ever writes then verifies by key), stored in the secrets backend, and referenced
  — never created — via `r2_evidence_token_secret_ref`.

## Encryption — two layers, one of them out of Terraform's reach

- **Server-side**: R2 encrypts data at rest by default; no Terraform configuration is
  needed or exposed for this (Cloudflare manages it transparently for every bucket).
- **Client-side**: the spec also calls for encryption "on the client" in addition to the
  provider's. That is an **application-layer responsibility of the Security Guard API /
  cron** (encrypt before `PutObject`), not something this Terraform module can own —
  there is no bucket-level Terraform knob for it.

## CORS

No `cloudflare_r2_bucket_cors`-equivalent resource is created. R2 buckets have no CORS
rules by default, which is exactly what "CORS disabled/minimal, no access from the Mac
app" requires — satisfied by omission, not by creating a CORS resource and setting it to
something restrictive that could later be loosened by mistake.

## Production retention floor

`r2_evidence_retention_days` defaults to `365` and has a cross-variable validation:
whenever `is_production = true`, it must be `>= 365`. Staging/local can set it lower if
needed for faster lock-expiry testing, since `is_production` defaults `false`.

## When `r2_evidence_enabled = false`

The caller (`platform/<env>`) must not instantiate this module at all (`count = 0`) —
no bucket, no lock, no lifecycle rule, no ExternalSecret exist, and no live Cloudflare
API call is attempted. `platform/<env>` must still surface a `r2_evidence_enabled =
false` capability output so the Security Guard API can report the evidence-storage
capability as explicitly unavailable, rather than silently behaving as if uploads were
succeeding.

## Verified against the Cloudflare provider (v5.27.0, confirmed via registry docs)

- `cloudflare_r2_bucket`: `account_id`, `name` required; `location`, `jurisdiction`,
  `storage_class` optional. `location` is only honored on first creation of a given
  bucket name.
- `cloudflare_r2_bucket_lock`: `rules[].condition.type` ∈ `{Age, Date, Indefinite}`;
  this module always uses `Age` + `max_age_seconds`.
- `cloudflare_r2_bucket_lifecycle`: confirmed to exist in this provider version (it was
  flagged as unconfirmed in the original plan — it does exist, with
  `delete_objects_transition.condition.{type,max_age,date}` and also supports
  `storage_class_transitions`/`abort_multipart_uploads_transition`, unused here).
- Neither `cloudflare_r2_bucket_lock` nor `cloudflare_r2_bucket_lifecycle` currently
  support `terraform import` per the provider docs — plan accordingly for any future
  drift-recovery procedure (recreate rather than import).
