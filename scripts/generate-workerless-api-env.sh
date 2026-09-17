#!/usr/bin/env sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLATFORM_DIR="$REPO_DIR/platform/local"
OUTPUT_FILE="$PLATFORM_DIR/workerless-api.local.env"
TEMP_FILE=$(mktemp "$PLATFORM_DIR/.workerless-api.local.env.XXXXXX")

cleanup() {
  rm -f "$TEMP_FILE"
}
trap cleanup EXIT HUP INT TERM

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

SERVER_URL=$(terraform -chdir="$PLATFORM_DIR" output -raw workerless_api_server_url)
BEARER_TOKEN=$(terraform -chdir="$PLATFORM_DIR" output -raw workerless_api_token)
CA_DATA=$(terraform -chdir="$PLATFORM_DIR" output -raw workerless_api_ca_base64)

{
  printf 'KUBERNETES_SERVER_URL='
  shell_quote "$SERVER_URL"
  printf '\nKUBERNETES_BEARER_TOKEN='
  shell_quote "$BEARER_TOKEN"
  printf '\nKUBERNETES_CA_DATA_BASE64='
  shell_quote "$CA_DATA"
  printf '\n'
} > "$TEMP_FILE"

chmod 600 "$TEMP_FILE"
mv "$TEMP_FILE" "$OUTPUT_FILE"
trap - EXIT HUP INT TERM
