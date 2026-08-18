#!/usr/bin/env sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLATFORM_DIR="$SCRIPT_DIR/platform/local"
KUBE_CONTEXT="k3d-local-rock"
TARGET_ENV="$SCRIPT_DIR/../workerless-api/.env"
CHECK_ONLY=false

usage() {
  echo "Usage: $0 [--check] [path-to-api-env]"
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=true
  shift
fi

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  TARGET_ENV=$1
fi

command -v terraform >/dev/null 2>&1 || fail "terraform is not available"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is not available"
command -v jq >/dev/null 2>&1 || fail "jq is not available"
[ -f "$TARGET_ENV" ] || fail "target env file does not exist: $TARGET_ENV"

# Read every source before creating a temporary file. Terraform and kubectl
# diagnostics are suppressed because sensitive output must never reach stdout.
KUBERNETES_BEARER_TOKEN=$(terraform -chdir="$PLATFORM_DIR" output -raw paas_sa_token 2>/dev/null) ||
  fail "platform/local has no applied paas_sa_token output"
OBSERVABILITY_PROMETHEUS_URL=$(terraform -chdir="$PLATFORM_DIR" output -raw prometheus_url 2>/dev/null) ||
  fail "platform/local has no applied prometheus_url output"
PLATFORM_REGISTRY_URL=$(terraform -chdir="$PLATFORM_DIR" output -raw registry_url 2>/dev/null) ||
  fail "platform/local has no applied registry_url output"
PLATFORM_REGISTRY_PUSH_URL=$(terraform -chdir="$PLATFORM_DIR" output -raw registry_push_url 2>/dev/null) ||
  fail "platform/local has no applied registry_push_url output"
KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_NAMESPACE=$(terraform -chdir="$PLATFORM_DIR" output -raw registry_credentials_source_namespace 2>/dev/null) ||
  fail "platform/local has no applied registry_credentials_source_namespace output"
KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_SECRET=$(terraform -chdir="$PLATFORM_DIR" output -raw registry_credentials_source_secret 2>/dev/null) ||
  fail "platform/local has no applied registry_credentials_source_secret output"

KUBE_CONFIG=$(kubectl config view --raw --minify --context="$KUBE_CONTEXT" -o json 2>/dev/null) ||
  fail "kubeconfig context $KUBE_CONTEXT is not available"

KUBERNETES_SERVER_URL=$(printf '%s' "$KUBE_CONFIG" | jq -r '.clusters[0].cluster.server // empty')
KUBERNETES_CA_DATA_BASE64=$(printf '%s' "$KUBE_CONFIG" | jq -r '.clusters[0].cluster["certificate-authority-data"] // empty')

[ -n "$KUBERNETES_SERVER_URL" ] || fail "context $KUBE_CONTEXT has no Kubernetes server URL"
[ -n "$KUBERNETES_BEARER_TOKEN" ] || fail "Terraform output paas_sa_token is empty"
[ -n "$KUBERNETES_CA_DATA_BASE64" ] || fail "context $KUBE_CONTEXT has no embedded CA data"
[ -n "$OBSERVABILITY_PROMETHEUS_URL" ] || fail "Terraform output prometheus_url is empty"
[ -n "$PLATFORM_REGISTRY_URL" ] || fail "Terraform output registry_url is empty"
[ -n "$PLATFORM_REGISTRY_PUSH_URL" ] || fail "Terraform output registry_push_url is empty"
[ -n "$KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_NAMESPACE" ] || fail "Terraform registry credentials source namespace is empty"
[ -n "$KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_SECRET" ] || fail "Terraform registry credentials source secret is empty"

export KUBERNETES_SERVER_URL KUBERNETES_BEARER_TOKEN KUBERNETES_CA_DATA_BASE64 OBSERVABILITY_PROMETHEUS_URL PLATFORM_REGISTRY_URL PLATFORM_REGISTRY_PUSH_URL KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_NAMESPACE KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_SECRET

render_env() {
  awk '
    BEGIN {
      split("KUBERNETES_SERVER_URL KUBERNETES_BEARER_TOKEN KUBERNETES_CA_DATA_BASE64 OBSERVABILITY_PROMETHEUS_URL PLATFORM_REGISTRY_URL PLATFORM_REGISTRY_PUSH_URL KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_NAMESPACE KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_SECRET", keys)
      for (i in keys) values[keys[i]] = ENVIRON[keys[i]]
    }
    {
      matched = 0
      for (key in values) {
        if ($0 ~ "^" key "=") {
          if (!seen[key]++) print key "=" values[key]
          matched = 1
          break
        }
      }
      if (!matched) print
    }
    END {
      for (i = 1; i <= 8; i++)
        if (!seen[keys[i]]) print keys[i] "=" values[keys[i]]
    }
  ' "$TARGET_ENV"
}

if [ "$CHECK_ONLY" = "true" ]; then
  if render_env | cmp -s - "$TARGET_ENV"; then
    echo "Local API integration environment is in sync."
    exit 0
  fi
  echo "Local API integration environment is out of sync." >&2
  exit 1
fi

TARGET_DIR=$(dirname -- "$TARGET_ENV")
TEMP_ENV=$(mktemp "$TARGET_DIR/.sync.local-api-env.XXXXXX") || fail "could not create temporary env file"
trap 'rm -f "$TEMP_ENV"' EXIT HUP INT TERM

render_env >"$TEMP_ENV"
chmod --reference="$TARGET_ENV" "$TEMP_ENV" 2>/dev/null || chmod 600 "$TEMP_ENV"
mv -f "$TEMP_ENV" "$TARGET_ENV"
trap - EXIT HUP INT TERM

echo "Updated Kubernetes and Prometheus integration settings in $TARGET_ENV."
