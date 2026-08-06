#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -z "${HCLOUD_TOKEN:-}" ]] && ! pulumi config get hcloudToken --stack hetzner --cwd "$SCRIPT_DIR/envs/hetzner" &>/dev/null; then
  echo "ERROR: HCLOUD_TOKEN must be set or hcloudToken configured in the Pulumi stack"
  echo "  export HCLOUD_TOKEN=<your-token>"
  echo "  or: pulumi config set --secret hcloudToken <token> --cwd envs/hetzner --stack hetzner"
  exit 1
fi

echo "==> [v2] Installing workspace dependencies..."
npm install

echo "==> [v2] Type-checking all packages..."
npm run typecheck --workspaces --if-present

echo "==> [v2] Building packages..."
npm run build --workspaces --if-present

echo "==> [v2] Provisioning Hetzner cluster (envs/hetzner)..."
cd "$SCRIPT_DIR/envs/hetzner"
pulumi stack select hetzner 2>/dev/null || pulumi stack init hetzner
if [[ -n "${HCLOUD_TOKEN:-}" ]]; then
  pulumi config set --secret hcloudToken "$HCLOUD_TOKEN" --stack hetzner
fi
pulumi up --yes --stack hetzner

echo "==> [v2] Installing platform on Hetzner cluster (platform/hetzner)..."
cd "$SCRIPT_DIR/platform/hetzner"
pulumi stack select hetzner 2>/dev/null || pulumi stack init hetzner
if [[ -n "${HCLOUD_TOKEN:-}" ]]; then
  pulumi config set --secret hcloudToken "$HCLOUD_TOKEN" --stack hetzner
fi
pulumi up --yes --stack hetzner

echo "==> [v2] Done! Hetzner platform is ready."
