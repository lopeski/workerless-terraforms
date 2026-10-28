# modules/cloudflare-operational-blocking

Creates a Cloudflare list + firewall ruleset dedicated exclusively to the Workerless
Security Guard's operational IP blocking, and the `ExternalSecret` that delivers the
Security Guard API's Cloudflare runtime token into the cluster. It does **not** create
or manage the IP/CIDR items themselves — those are inserted and removed by the running
API at runtime via its own token.

## Two separate Cloudflare credentials — do not conflate them

| Credential | Who holds it | Scope | Created by |
|---|---|---|---|
| Terraform-operator bootstrap token | CI (same plane as `hcloud_token`) | Broad enough to manage Rulesets + Lists on the target account/zones | Manually, stored as a CI secret; **this module never sees it directly** (see "Provider wiring" below) |
| Security Guard API runtime token | The running API, via `cloudflare_guard_token_secret_ref` → `ExternalSecret` | Minimal: Rulesets + Lists **edit** only, scoped to this account/zone — cannot touch DNS, Workers, or other rulesets | Manually/out-of-band in the secrets backend, **never by Terraform** |

Terraform deliberately never creates the API's runtime token as a `cloudflare_api_token`
resource: doing so would put the token value in Terraform state with no clean
secret-export path (this repo has no Vault/secrets-manager provider to hand it off to
without violating "secrets never appear in outputs"). If a Vault-style provider is
adopted later, creating this token declaratively becomes an option — until then it is a
manual, documented provisioning step, verified once per rotation (see spec §13 — this is
one of the checks that is inherently outside CI's reach, since it requires calling the
live Cloudflare API with the real runtime token to confirm it's rejected outside its
scope).

## Provider wiring (important — read before calling this module)

This module intentionally contains **no `provider "cloudflare" {}` block of its own**.
Terraform hard-errors ("Module is incompatible with count, for_each, and depends_on")
if a module with its own provider configuration is called with `count`/`for_each` — and
this module is meant to be instantiated conditionally (`count = var.cloudflare_operational_blocking_enabled ? 1 : 0`)
from `platform/<env>`. The caller must configure the provider and pass it explicitly:

```hcl
# platform/<env>/main.tf
provider "cloudflare" {
  alias     = "ops_blocking"
  api_token = var.cloudflare_api_token # the Terraform-operator bootstrap credential
}

module "cloudflare_operational_blocking" {
  count  = var.cloudflare_operational_blocking_enabled ? 1 : 0
  source = "../../modules/cloudflare-operational-blocking"

  providers = {
    cloudflare = cloudflare.ops_blocking
  }

  cloudflare_account_id            = var.cloudflare_account_id
  cloudflare_zone_ids              = var.cloudflare_zone_ids
  cloudflare_guard_list_name       = var.cloudflare_guard_list_name
  cloudflare_guard_rule_expression = var.cloudflare_guard_rule_expression
  protected_endpoints              = var.cloudflare_protected_endpoints
  cloudflare_guard_token_secret_ref = var.cloudflare_guard_token_secret_ref
  guard_token_secret_namespace     = "security-guard-grpc" # or wherever the API reads it from
  guard_token_backend_key          = "cloudflare-guard-runtime-token"
}
```

`modules/security-evidence-r2` needs the exact same treatment with its **own** alias
(different Cloudflare token, same account) — do not reuse the `ops_blocking` alias for
it.

## Resources created

- `cloudflare_list` (kind `ip`) named `var.cloudflare_guard_list_name`, validated against
  `^workerless_guard_block_[a-z0-9_]+$` so it can never collide with a manually-maintained
  list. `items` is omitted and `lifecycle.ignore_changes = [items]` is set — this is what
  satisfies spec §7's "Terraform must not try to reconcile every ephemeral item inserted
  by the API on every plan, without hiding structural changes": only the list's identity
  (name/kind/description) is reconciled; its contents are explicitly out of Terraform's
  authority.
- `cloudflare_ruleset` (phase `http_request_firewall_custom`, kind `zone`), one per entry
  in `var.cloudflare_zone_ids`. The rule's expression is always
  `(<cloudflare_guard_rule_expression>) and (<host-match over protected_endpoints>)` —
  never deployed as a bare `ip.src in $list` with no endpoint scope, per spec §7's
  "enable the rule only on the protected public endpoints."
- `kubectl_manifest` `ExternalSecret` materializing the API's runtime token from
  `cloudflare_guard_token_secret_ref` into `guard_token_secret_namespace`/`guard_token_secret_name`.
  This module owns this CR directly (it's self-contained, per spec §2) rather than
  delegating it to `platform/<env>`.

## Outputs

`cloudflare_guard_list_id`, `cloudflare_guard_ruleset_ids` (map keyed by zone ID) — IDs
only, per spec §14. No token value is ever output.

## Capability-unavailable behavior

When `cloudflare_operational_blocking_enabled = false`, `platform/<env>` must not
instantiate this module at all (`count = 0`) — zero resources are created, and the
capability-flag output surfaced to the external API must resolve to `false`, never a
fake/placeholder list.
