# security-datastore-acl

Optional, flag-gated module that reconciles role separation and access control on an **external**
PostgreSQL database and Kafka cluster used by the Workerless Security Guard (spec §10). It owns no
infrastructure of its own — only roles, grants, topics and ACLs against endpoints supplied via
variables. Mirrors the repo's standing principle that brokers/databases are external; this module
is the one exception where Terraform needs a direct, live administrative connection (rather than
going through `ExternalSecret`s) because the `postgresql`/`kafka` providers must authenticate to
reconcile roles/ACLs at plan/apply time.

## Role separation

```
                 ┌─────────────────────────┐
                 │   security schema/DB     │
                 └───────────┬─────────────┘
                 SELECT only │              │ SELECT, INSERT, UPDATE, DELETE
         ┌───────────────────┘              └───────────────────┐
         ▼                                                      ▼
 security_guard_api_readonly                        security_guard_cron_writer
 (the gRPC API — can never                          (the cron/collector —
  INSERT/UPDATE/DELETE/                               no DDL, no superuser,
  TRUNCATE/ALTER/CREATE)                               separate from the API)
```

If migrations for this schema run as yet another identity (recommended), set
`postgresql_schema_owner_role` to that role's name — this activates a `postgresql_default_privileges`
resource that revokes `PUBLIC`'s implicit grants on tables created after this module first applies,
so a new table never silently inherits broader access than the two roles above. **A third,
migration-only role is not created by this module** — if the cron role above should not also run
migrations, provision that third role outside this module and point `postgresql_schema_owner_role`
at it.

## Provider wiring (important — read before calling this module)

This module intentionally contains **no `provider "postgresql" {}` or `provider "kafka" {}` block
of its own**. Terraform hard-errors ("Module is incompatible with count, for_each, and depends_on")
if a module with its own provider configuration is called with `count`/`for_each` — and this module
is meant to be instantiated conditionally via `for_each = var.security_datastore_acl_enabled ? {enabled = true} : {}`
(never a plain `count` — see "The capability-flag contract" below). The caller must configure both
providers and pass them in explicitly:

```hcl
# platform/<env>/main.tf
provider "postgresql" {
  alias           = "security_datastore"
  host            = var.postgresql_host
  port            = var.postgresql_port
  database        = var.postgresql_database
  username        = try(var.postgresql_admin_credentials_secret_ref.username, null)
  password        = try(var.postgresql_admin_credentials_secret_ref.password, null)
  sslmode         = "verify-full" # hard requirement, no disable/require-without-verify fallback
  connect_timeout = 10
  superuser       = false
}

provider "kafka" {
  alias             = "security_datastore"
  bootstrap_servers = var.kafka_bootstrap_servers
  sasl_mechanism    = "scram-sha256"
  sasl_username     = try(var.kafka_admin_credentials_secret_ref.username, null)
  sasl_password     = try(var.kafka_admin_credentials_secret_ref.password, null)
  tls_enabled       = true
}

module "security_datastore_acl" {
  for_each = var.security_datastore_acl_enabled ? { enabled = true } : {}
  source   = "../../modules/security-datastore-acl"

  providers = {
    postgresql = postgresql.security_datastore
    kafka      = kafka.security_datastore
  }

  security_datastore_acl_enabled = true
  postgresql_database             = var.postgresql_database
  postgresql_security_schema      = var.postgresql_security_schema
  postgresql_security_tables      = var.postgresql_security_tables
  postgresql_schema_owner_role    = var.postgresql_schema_owner_role
  kafka_security_topics           = var.kafka_security_topics
  kafka_dlq_topic_name            = var.kafka_dlq_topic_name
  kafka_dlq_retention_ms          = var.kafka_dlq_retention_ms
  kafka_api_principal             = var.kafka_api_principal
  kafka_collector_principal       = var.kafka_collector_principal
  kafka_dlq_ops_principal         = var.kafka_dlq_ops_principal
}
```

The TLS/SASL hardening (`sslmode = "verify-full"`, `tls_enabled = true` + SCRAM) still applies in
full — it has simply relocated one layer up, alongside the connection details it secures. There is
no variable anywhere in this repo that can loosen either setting; change the provider block in
`platform/<env>/main.tf` directly if a weaker mode is ever genuinely needed (it shouldn't be).

**`postgresql_database` is the one variable declared on *both* layers.** `platform/<env>` needs it
to set the provider's own default-database connection target, and this module *also* needs it as
an input because `postgresql_grant`/`postgresql_default_privileges` take `database` as a required
argument on the resource itself, independent of the provider's configuration. Everything else that
configures the live connection (`postgresql_host`, `postgresql_port`,
`postgresql_admin_credentials_secret_ref`, `kafka_bootstrap_servers`,
`kafka_admin_credentials_secret_ref`) lives **only** on `platform/<env>`'s `variables.tf` — this
module has no use for them since it never opens the connection itself.

**Unconfigured-provider trap**: `platform/<env>` itself has no `count`/`for_each` on its own root
module, so its root-level `provider "postgresql"`/`provider "kafka"` blocks are initialized on
every plan — including when `security_datastore_acl_enabled = false` and the module invocation
above evaluates to an empty `for_each = {}`. Give `postgresql_host`, `postgresql_admin_credentials_secret_ref`,
`kafka_bootstrap_servers`, and `kafka_admin_credentials_secret_ref` safe `null`/empty defaults in
`platform/<env>/terraform.tfvars.example` (mirroring how every other new capability flag in this
effort defaults to disabled-with-no-fake-credentials) so an intentionally unconfigured provider
doesn't break `terraform plan` for local/dev when the feature is off. A provider block with `host =
null`/empty `bootstrap_servers` initializes fine; it only fails if something actually tries to
connect, which nothing does when the module above isn't instantiated.

## Kafka layout

- One `kafka_topic` per entry in `var.kafka_security_topics`, with explicit `partitions` /
  `replication_factor` / `retention.ms`.
- One dedicated DLQ topic (`var.kafka_dlq_topic_name`, default `security-guard-dlq`), its own
  retention (`var.kafka_dlq_retention_ms`).
- ACLs: `var.kafka_api_principal` gets `Write`+`Describe` on every security topic (producer);
  `var.kafka_collector_principal` gets `Read`+`Describe` on every security topic (consumer) **and**
  `Write` on the DLQ (it's the one writing failures there). Nobody else can read the DLQ unless
  `var.kafka_dlq_ops_principal` is set, which grants that one extra principal `Read` for incident
  response — there is no broad/public Read grant on the DLQ under any configuration.

## The capability-flag contract

`security_datastore_acl_enabled` is both an input and an output. **Terraform providers cannot be
conditionally configured** — `provider "postgresql" {}` and `provider "kafka" {}` in this module
always attempt to build their configuration from whatever variables they're given. This means
`platform/<env>` must **never** call this module with a plain `count`; it must use:

```hcl
module "security_datastore_acl" {
  for_each = var.security_datastore_acl_enabled ? { enabled = true } : {}
  source   = "../../modules/security-datastore-acl"

  security_datastore_acl_enabled = true
  # ...
}
```

so that when the flag is `false`, the module is **never instantiated at all** and no live
PostgreSQL/Kafka connection is ever attempted — satisfying spec §12's "absent provider/config ⇒
capability unavailable" without local/dev `terraform plan` failing against an unreachable database.
`platform/<env>/outputs.tf` must then supply a hardcoded `false` for this capability when the
module isn't instantiated (see that layer's own README/wiring).

## Validation without a live database

`terraform validate` in this directory does **not** require a reachable PostgreSQL/Kafka endpoint —
it has no provider block of its own to connect with, and only type-checks the configuration, so
it's safe to run with no real credentials and no `providers = {...}` wiring at all (that wiring is
only needed for `plan`/`apply`, which do need a real connection via whatever the caller passes in).
Two `check` blocks (`postgresql_config_consistency`, `kafka_config_consistency`) run at plan/apply
time and **warn** (they do not block) if e.g. `postgresql_security_tables` is set but
`postgresql_database` isn't — catching a likely misconfiguration without turning this into a hard
dependency between the two subsystems (you can legitimately use this module for only Postgres or
only Kafka). They cannot see or validate `platform/<env>`'s connection variables (host, bootstrap
servers, credentials) since those no longer exist at this layer — a working connection is entirely
the caller's responsibility.

To smoke-test this module against something real without touching production, apply it from a
throwaway root module that declares the provider blocks from "Provider wiring" above pointed at a
disposable `postgres:16` / Kafka container (e.g. `apache/kafka` or `confluentinc/cp-kafka`), then
passes them in via `providers = {...}` exactly as `platform/<env>` would.
