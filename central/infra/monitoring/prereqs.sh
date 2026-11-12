#!/usr/bin/env bash
# Cluster prerequisites of monitoring-stack that live outside the chart. Idempotent.
#   - namespaces monitoring/logging/seaweedfs (label monitoring=true: Prometheus selects rules/monitors by it)
#   - prometheus-operator CRDs (the chart sets prometheus.crds.enabled=false)
#   - cert-manager (admission webhook certificate of kube-prometheus-stack)
#   - SeaweedFS as S3 backend (needs secrets.sh first)
#   - PostgreSQL for Grafana (CloudNativePG)
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=versions.env
source ./versions.env
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k0s-central.yaml}"
HELM=$HELM_BIN

echo ">> Namespaces"
for ns in monitoring logging seaweedfs postgres; do
  kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label ns "$ns" monitoring=true --overwrite >/dev/null
done

echo ">> prometheus-operator CRDs ${PROMETHEUS_OPERATOR_CRDS_VERSION}"
$HELM repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
$HELM repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm >/dev/null 2>&1 || true
$HELM repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
$HELM repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
$HELM repo update prometheus-community seaweedfs jetstack cnpg >/dev/null
$HELM upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator-crds \
  --version "$PROMETHEUS_OPERATOR_CRDS_VERSION" -n monitoring --wait >/dev/null

echo ">> cert-manager ${CERT_MANAGER_CHART_VERSION}"
$HELM upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_CHART_VERSION" \
  -n cert-manager --create-namespace -f ../cert-manager/values.yaml --wait --timeout 5m >/dev/null

echo ">> SeaweedFS ${SEAWEEDFS_CHART_VERSION}"
kubectl -n seaweedfs get secret seaweedfs-s3-config >/dev/null || { echo "run ./secrets.sh first" >&2; exit 1; }
$HELM upgrade --install seaweedfs seaweedfs/seaweedfs --version "$SEAWEEDFS_CHART_VERSION" \
  -n seaweedfs -f ../seaweedfs/values.yaml --wait --timeout 5m >/dev/null
kubectl -n seaweedfs get pods

echo ">> PostgreSQL for Grafana (CloudNativePG ${CNPG_CHART_VERSION})"
kubectl -n postgres get secret grafana-db-credentials >/dev/null || { echo "run ./secrets.sh first" >&2; exit 1; }
$HELM upgrade --install cnpg cnpg/cloudnative-pg --version "$CNPG_CHART_VERSION" \
  -n cnpg-system --create-namespace -f ../postgres/operator-values.yaml --wait --timeout 5m >/dev/null
kubectl apply -f ../postgres/grafana-db.yaml >/dev/null
kubectl -n postgres wait cluster/grafana-db --for=condition=Ready --timeout=10m >/dev/null
kubectl -n postgres get cluster grafana-db
