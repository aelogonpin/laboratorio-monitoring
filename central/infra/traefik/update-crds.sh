#!/usr/bin/env bash
# Regenerates crds/ from the pinned versions in versions.env.
#   crds/traefik/      <- crds/traefik.io_*.yaml of chart traefik/traefik (Hub CRDs excluded)
#   crds/gateway-api/  <- kubernetes-sigs/gateway-api <channel>-install.yaml
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=versions.env
source ./versions.env

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo ">> Traefik CRDs from chart traefik/traefik ${TRAEFIK_CHART_VERSION}"
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null
helm pull traefik/traefik --version "$TRAEFIK_CHART_VERSION" --untar -d "$tmp"

echo ">> Gateway API ${GATEWAY_API_VERSION} (${GATEWAY_API_CHANNEL})"
gw_file="${GATEWAY_API_CHANNEL}-install.yaml"
curl -sSfL -o "$tmp/$gw_file" \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/${gw_file}"
grep -q "bundle-version: ${GATEWAY_API_VERSION}" "$tmp/$gw_file" \
  || { echo "ERROR: downloaded Gateway API bundle is not ${GATEWAY_API_VERSION}" >&2; exit 1; }
grep -q "channel: ${GATEWAY_API_CHANNEL}" "$tmp/$gw_file" \
  || { echo "ERROR: downloaded Gateway API bundle is not channel ${GATEWAY_API_CHANNEL}" >&2; exit 1; }

rm -rf crds/traefik crds/gateway-api
mkdir -p crds/traefik crds/gateway-api
cp "$tmp"/traefik/crds/traefik.io_*.yaml crds/traefik/
cp "$tmp/$gw_file" "crds/gateway-api/${GATEWAY_API_CHANNEL}-install-${GATEWAY_API_VERSION}.yaml"

echo ">> crds/ updated:"
find crds -name '*.yaml' | sort | sed 's/^/   /'
