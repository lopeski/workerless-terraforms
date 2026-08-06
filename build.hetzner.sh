#!/usr/bin/env sh

set -e

cd "$(dirname "$0")"

for d in envs/hetzner platform/hetzner modules/core-platform modules/workload; do
  terraform fmt -check "$d"
done
echo "fmt OK"

if [ -z "${TF_VAR_hcloud_token:-}" ]; then
  echo "ERRO: exporte TF_VAR_hcloud_token=<seu_token_hetzner> antes de rodar."
  exit 1
fi

run_terraform() {
  DIR="$1"
  NEEDS_TFVARS="${2:-false}"

  echo "=============================="
  echo "Rodando Terraform em: $DIR"
  echo "=============================="

  if [ "$NEEDS_TFVARS" = "true" ] && [ ! -f "$DIR/terraform.tfvars" ]; then
    echo "ERRO: $DIR/terraform.tfvars não existe."
    echo "Copie $DIR/terraform.tfvars.example para $DIR/terraform.tfvars e preencha."
    exit 1
  fi

  if [ ! -f "$DIR/backend.hcl" ]; then
    echo "ERRO: $DIR/backend.hcl não existe."
    echo "Copie $DIR/backend.hcl.example para $DIR/backend.hcl e preencha o bucket/region."
    exit 1
  fi

  if ! grep -Eq '^[[:space:]]*encrypt[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$DIR/backend.hcl"; then
    echo "ERRO: $DIR/backend.hcl deve conter encrypt = true."
    exit 1
  fi

  if ! grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$DIR/backend.hcl"; then
    echo "ERRO: $DIR/backend.hcl deve conter use_lockfile = true."
    exit 1
  fi

  cd "$DIR"
  terraform init -backend-config=backend.hcl
  terraform validate
  terraform plan -out=tfplan
  terraform apply tfplan
  cd - > /dev/null
}

run_terraform "envs/hetzner"
run_terraform "platform/hetzner" "true"
