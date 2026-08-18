#!/usr/bin/env sh

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
MOCK_BIN="$TEST_DIR/bin"
TARGET_ENV="$TEST_DIR/api.env"
mkdir "$MOCK_BIN"

cat >"$MOCK_BIN/terraform" <<'EOF'
#!/usr/bin/env sh
case "$*" in
  *paas_sa_token) printf '%s' 'fixture-secret-token' ;;
  *prometheus_url) printf '%s' 'http://localhost:30090' ;;
  *registry_push_url) printf '%s' 'harbor-registry.harbor.svc:5000' ;;
  *registry_url) printf '%s' 'localhost:5001' ;;
  *registry_credentials_source_namespace) printf '%s' 'harbor' ;;
  *registry_credentials_source_secret) printf '%s' 'registry-credentials-source' ;;
  *) exit 1 ;;
esac
EOF

cat >"$MOCK_BIN/kubectl" <<'EOF'
#!/usr/bin/env sh
if [ "${FAIL_KUBECTL:-false}" = "true" ]; then
  exit 1
fi
cat <<'JSON'
{"clusters":[{"cluster":{"server":"https://127.0.0.1:6550","certificate-authority-data":"fixture-ca-data"}}]}
JSON
EOF
chmod +x "$MOCK_BIN/terraform" "$MOCK_BIN/kubectl"

cat >"$TARGET_ENV" <<'EOF'
# preserved comment
PORT=3000
KUBERNETES_SERVER_URL=https://old.invalid
KUBERNETES_BEARER_TOKEN=old-token
KUBERNETES_CA_DATA_BASE64=old-ca
OBSERVABILITY_PROMETHEUS_URL=http://localhost:9090
PLATFORM_REGISTRY_URL=old.invalid
UNRELATED_SECRET=keep-me
EOF

PATH="$MOCK_BIN:$PATH" "$REPO_DIR/sync.local-api-env.sh" "$TARGET_ENV" >"$TEST_DIR/update.out"
grep -q '^PORT=3000$' "$TARGET_ENV"
grep -q '^UNRELATED_SECRET=keep-me$' "$TARGET_ENV"
grep -q '^KUBERNETES_SERVER_URL=https://127.0.0.1:6550$' "$TARGET_ENV"
grep -q '^KUBERNETES_BEARER_TOKEN=fixture-secret-token$' "$TARGET_ENV"
grep -q '^KUBERNETES_CA_DATA_BASE64=fixture-ca-data$' "$TARGET_ENV"
grep -q '^OBSERVABILITY_PROMETHEUS_URL=http://localhost:30090$' "$TARGET_ENV"
grep -q '^PLATFORM_REGISTRY_URL=localhost:5001$' "$TARGET_ENV"
grep -q '^PLATFORM_REGISTRY_PUSH_URL=harbor-registry.harbor.svc:5000$' "$TARGET_ENV"
grep -q '^KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_NAMESPACE=harbor$' "$TARGET_ENV"
grep -q '^KUBERNETES_REGISTRY_CREDENTIALS_SOURCE_SECRET=registry-credentials-source$' "$TARGET_ENV"
if grep -Eq 'fixture-secret-token|fixture-ca-data' "$TEST_DIR/update.out"; then
  echo "sensitive value was printed" >&2
  exit 1
fi

PATH="$MOCK_BIN:$PATH" "$REPO_DIR/sync.local-api-env.sh" --check "$TARGET_ENV" >"$TEST_DIR/check.out"

cp "$TARGET_ENV" "$TEST_DIR/before-failure.env"
if FAIL_KUBECTL=true PATH="$MOCK_BIN:$PATH" "$REPO_DIR/sync.local-api-env.sh" "$TARGET_ENV" >"$TEST_DIR/failure.out" 2>"$TEST_DIR/failure.err"; then
  echo "expected a failed preflight" >&2
  exit 1
fi
cmp -s "$TEST_DIR/before-failure.env" "$TARGET_ENV"
if grep -Eq 'fixture-secret-token|fixture-ca-data' "$TEST_DIR/failure.out" "$TEST_DIR/failure.err"; then
  echo "sensitive value was printed on failure" >&2
  exit 1
fi

sed 's|http://localhost:30090|http://localhost:9090|' "$TARGET_ENV" >"$TEST_DIR/out-of-sync.env"
if PATH="$MOCK_BIN:$PATH" "$REPO_DIR/sync.local-api-env.sh" --check "$TEST_DIR/out-of-sync.env" >"$TEST_DIR/divergence.out" 2>"$TEST_DIR/divergence.err"; then
  echo "expected --check to detect divergence" >&2
  exit 1
fi
grep -q 'out of sync' "$TEST_DIR/divergence.err"

echo "sync.local-api-env tests passed"
