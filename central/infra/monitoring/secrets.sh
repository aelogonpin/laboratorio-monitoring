#!/usr/bin/env bash
# Creates/updates every Secret the monitoring-stack chart expects, for the local k0s test cluster.
# Credentials are generated once into .secrets.env (chmod 600) and reused on every run. Idempotent.
set -euo pipefail

cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k0s-central.yaml}"
ENV_FILE=.secrets.env

rand() { openssl rand -hex "${1:-16}"; }

if [[ ! -f $ENV_FILE ]]; then
  umask 077
  cat > "$ENV_FILE" <<EOV
S3_ACCESS_KEY=$(rand 10)
S3_SECRET_KEY=$(rand 20)
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$(rand 12)
LOKI_USER=loki
LOKI_PASS=$(rand 12)
CLUSTER_NAME=k0s-central
EOV
  echo ">> Generated $ENV_FILE"
fi
# Grafana PostgreSQL password, added to existing env files too
if ! grep -q '^GRAFANA_DB_PASS=' "$ENV_FILE"; then
  umask 077
  printf 'GRAFANA_DB_PASS=%s\n' "$(rand 16)" >> "$ENV_FILE"
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

apply() { kubectl apply -f - >/dev/null; }
secret() { # secret <ns> <name> <kubectl create secret generic args...>
  local ns=$1 name=$2; shift 2
  kubectl -n "$ns" create secret generic "$name" "$@" --dry-run=client -o yaml | apply
  echo "   $ns/$name"
}

for ns in seaweedfs monitoring logging argocd postgres; do
  kubectl create ns "$ns" --dry-run=client -o yaml | apply
done

echo ">> Secrets"
s3_config=$(cat <<EOJ
{"identities":[{"name":"admin","credentials":[{"accessKey":"$S3_ACCESS_KEY","secretKey":"$S3_SECRET_KEY"}],"actions":["Admin","Read","List","Tagging","Write"]}]}
EOJ
)
secret seaweedfs seaweedfs-s3-config --from-literal=seaweedfs_s3_config="$s3_config"

# Keys used by repo/values.yaml (Grafana admin, Loki datasource auth, S3, Prometheus external labels)
secret monitoring monitoring-secrets \
  --from-literal=s3AccessKey="$S3_ACCESS_KEY" \
  --from-literal=s3SecretKey="$S3_SECRET_KEY" \
  --from-literal=lokiUser="$LOKI_USER" \
  --from-literal=lokiPass="$LOKI_PASS" \
  --from-literal=admin-user="$GRAFANA_ADMIN_USER" \
  --from-literal=grafana-admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --from-literal=clusterName="$CLUSTER_NAME" \
  --from-literal=distro=k0s \
  --from-literal=grafana-db-pass="$GRAFANA_DB_PASS"
# Owner of the Grafana database (CloudNativePG initdb)
kubectl -n postgres create secret generic grafana-db-credentials --type=kubernetes.io/basic-auth \
  --from-literal=username=grafana --from-literal=password="$GRAFANA_DB_PASS" \
  --dry-run=client -o yaml | apply
echo "   postgres/grafana-db-credentials"

# Loki gateway basic auth (.htpasswd) + S3
secret logging monitoring-secrets \
  --from-literal=s3AccessKey="$S3_ACCESS_KEY" \
  --from-literal=s3SecretKey="$S3_SECRET_KEY" \
  --from-literal=.htpasswd="$LOKI_USER:$(openssl passwd -apr1 "$LOKI_PASS")"

# Argo CD lee github.com/aelogonpin/laboratorio-monitoring (público): no hace falta Secret de repo.
