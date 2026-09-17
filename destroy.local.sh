#!/usr/bin/env sh

set -e

cd "$(dirname "$0")"

destroy_terraform() {
  DIR="$1"
  NEEDS_TFVARS="${2:-false}"

  echo "=============================="
  echo "Destruindo Terraform em: $DIR"
  echo "=============================="

  if [ "$NEEDS_TFVARS" = "true" ] && [ ! -f "$DIR/terraform.tfvars" ]; then
    echo "ERRO: $DIR/terraform.tfvars não existe."
    echo "Para destruir corretamente, o Terraform ainda precisa ler as variáveis que foram usadas na criação."
    exit 1
  fi

  cd "$DIR"

  # Garante que o diretório está inicializado
  terraform init

  # Gera o plano de destruição e aplica
  terraform plan -destroy -out=tfdestroyplan
  terraform apply tfdestroyplan

  cd - > /dev/null
}

# ATENÇÃO: A destruição ocorre na ordem INVERSA da criação
destroy_terraform "platform/local" "true"
destroy_terraform "envs/local"

echo "=============================="
echo "Destruição concluída com sucesso!"
echo "=============================="
