#!/usr/bin/env sh

set -e

cd "$(dirname "$0")"

for d in envs/local platform/local modules/core-platform modules/workload; do
  terraform fmt -check "$d"
done
echo "fmt OK"

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

  cd "$DIR"
  terraform init
  terraform validate
  terraform plan -out=tfplan
  terraform apply tfplan
  cd - > /dev/null
}

run_terraform "envs/local"
run_terraform "platform/local" "true"

./scripts/generate-workerless-api-env.sh

echo "Credenciais limitadas da API gravadas em platform/local/workerless-api.local.env"
echo "Na API: set -a; source ../workerless-terraforms/platform/local/workerless-api.local.env; set +a; yarn start:dev"
