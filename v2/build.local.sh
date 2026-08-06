#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> [v2] Installing workspace dependencies..."
npm install

echo "==> [v2] Type-checking all packages..."
npm run typecheck --workspaces --if-present

echo "==> [v2] Building packages..."
npm run build --workspaces --if-present

echo "==> [v2] Provisioning local cluster (envs/local)..."
cd "$SCRIPT_DIR/envs/local"
pulumi stack select local 2>/dev/null || pulumi stack init local
pulumi up --yes --stack local

echo "==> [v2] Installing platform on local cluster (platform/local)..."
cd "$SCRIPT_DIR/platform/local"
pulumi stack select local 2>/dev/null || pulumi stack init local
pulumi up --yes --stack local

echo "==> [v2] Done! Local platform is ready."
