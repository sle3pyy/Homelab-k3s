#!/usr/bin/env bash
set -euo pipefail

GITEA_NAMESPACE="${GITEA_NAMESPACE:-gitea}"
GITEA_POD_SELECTOR="${GITEA_POD_SELECTOR:-app.kubernetes.io/name=gitea,app.kubernetes.io/instance=gitea}"
GITEA_CONTAINER="${GITEA_CONTAINER:-gitea}"

SECRET_NAME="${SECRET_NAME:-gitea-actions-runner-token}"
SECRET_KEY="${SECRET_KEY:-runner-token}"

SEALED_SECRETS_CONTROLLER_NAME="${SEALED_SECRETS_CONTROLLER_NAME:-sealed-secrets-controller}"
SEALED_SECRETS_CONTROLLER_NAMESPACE="${SEALED_SECRETS_CONTROLLER_NAMESPACE:-kube-system}"

MANIFEST_DIR="${MANIFEST_DIR:-manifests/gitea-actions}"
SEALED_SECRET_FILE="${SEALED_SECRET_FILE:-gitea-actions-runner-token.sealedsecret.yaml}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need git
need kubectl
need kubeseal

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

mkdir -p "$MANIFEST_DIR"

echo "waiting for Sealed Secrets controller..."
kubectl -n "$SEALED_SECRETS_CONTROLLER_NAMESPACE" rollout status \
  "deployment/$SEALED_SECRETS_CONTROLLER_NAME" \
  --timeout=180s

echo "finding a running Gitea pod..."
pod="$(
  kubectl -n "$GITEA_NAMESPACE" get pods \
    -l "$GITEA_POD_SELECTOR" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' |
    head -n 1
)"

if [[ -z "$pod" ]]; then
  pod="$(
    kubectl -n "$GITEA_NAMESPACE" get pods \
      -l app.kubernetes.io/name=gitea \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' |
      head -n 1
  )"
fi

if [[ -z "$pod" ]]; then
  echo "no running Gitea pod found in namespace $GITEA_NAMESPACE" >&2
  exit 1
fi

echo "generating runner token from pod $pod..."
token="$(
  {
    kubectl -n "$GITEA_NAMESPACE" exec "$pod" -c "$GITEA_CONTAINER" -- \
      gitea actions generate-runner-token 2>/dev/null ||
    kubectl -n "$GITEA_NAMESPACE" exec "$pod" -- \
      gitea actions generate-runner-token
  } |
    awk 'NF { line = $0 } END { print line }'
)"

if [[ -z "$token" ]]; then
  echo "Gitea returned an empty runner token" >&2
  exit 1
fi

secret_file="$(mktemp)"
trap 'rm -f "$secret_file"' EXIT

kubectl -n "$GITEA_NAMESPACE" create secret generic "$SECRET_NAME" \
  "--from-literal=$SECRET_KEY=$token" \
  --dry-run=client \
  -o yaml > "$secret_file"

output_path="$MANIFEST_DIR/$SEALED_SECRET_FILE"

echo "sealing $SECRET_NAME into $output_path..."
kubeseal \
  --controller-name "$SEALED_SECRETS_CONTROLLER_NAME" \
  --controller-namespace "$SEALED_SECRETS_CONTROLLER_NAMESPACE" \
  --format yaml \
  < "$secret_file" \
  > "$output_path"

cat > "$MANIFEST_DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - $SEALED_SECRET_FILE
EOF

echo "wrote $output_path and updated $MANIFEST_DIR/kustomization.yaml"
