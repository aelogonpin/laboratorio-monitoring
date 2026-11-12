#!/usr/bin/env bash
# Applies CRDs (outside Helm) and installs/upgrades Traefik. Idempotent.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=versions.env
source ./versions.env
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k0s-central.yaml}"

[[ -d crds/traefik && -d crds/gateway-api ]] || { echo "crds/ missing: run ./update-crds.sh" >&2; exit 1; }

echo ">> Applying CRDs (server-side)"
kubectl apply --server-side --force-conflicts -f crds/traefik/ -f crds/gateway-api/ >/dev/null
kubectl wait --for=condition=Established crd --all --timeout=120s >/dev/null

echo ">> Helm: traefik/traefik ${TRAEFIK_CHART_VERSION}"
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null
helm upgrade --install "$RELEASE" traefik/traefik \
  --version "$TRAEFIK_CHART_VERSION" \
  -n "$NAMESPACE" --create-namespace \
  --skip-crds \
  -f values.yaml \
  --wait --timeout 5m

kubectl -n "$NAMESPACE" get pods
kubectl get gatewayclass
kubectl -n "$NAMESPACE" get gateway
