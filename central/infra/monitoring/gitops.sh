#!/usr/bin/env bash
# Argo CD + Applications del central. Idempotente. Orden: ./secrets.sh -> ./prereqs.sh -> ./gitops.sh
# Las Applications leen github.com/aelogonpin/laboratorio-monitoring (público): sin credenciales ni Secret de repo.
#   1. Argo CD (chart oficial)
#   2. kafka y espera a que el Kafka esté Ready (Mimir no arranca sin él)
#   3. monitoring y logging
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=versions.env
source ./versions.env
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k0s-central.yaml}"
HELM=$HELM_BIN
APPS=../../monitoring-laboratorio/argocd

$HELM repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
$HELM repo update argo >/dev/null

echo ">> Argo CD ${ARGOCD_CHART_VERSION}"
$HELM upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  -n argocd --create-namespace -f ../argocd/values.yaml --wait --timeout 5m >/dev/null

echo ">> Application kafka"
kubectl apply -f "$APPS/kafka.yaml" >/dev/null
echo "   esperando a que el Kafka esté Ready (hasta 20 min)"
for _ in $(seq 240); do
  [[ "$(kubectl -n monitoring get kafka kafka -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]] && break
  sleep 5
done
kubectl -n monitoring wait kafka/kafka --for=condition=Ready --timeout=10s >/dev/null \
  || { echo "Kafka no está Ready: kubectl -n monitoring get kafka,pods" >&2; exit 1; }

echo ">> Applications monitoring y logging"
kubectl apply -f "$APPS/monitoring.yaml" -f "$APPS/logging.yaml" >/dev/null
kubectl -n argocd get applications
