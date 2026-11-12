#!/usr/bin/env bash
# Baja de un cliente de la ingesta mTLS: lo quita de ingesta.clientes y su tenant de grafanaClusters del values del
# entorno. Al aplicarse (commit + push), Argo CD borra su TLSOption, Middlewares, IngressRoute y CA: queda fuera en el TLS.
# Los datos ya enviados se quedan en Mimir/Loki.
#   uso: baja-cliente.sh -f values-entorno.yaml <nombre>
set -euo pipefail
[ "${1:-}" = -f ] || { echo "uso: $0 -f values-entorno.yaml <nombre>" >&2; exit 2; }
V=${2:?values}; N=${3:?nombre}
[ -f "$V" ] || { echo "no existe $V" >&2; exit 1; }
[ "$(N="$N" yq '[.ingesta.clientes[]? | select(.nombre == strenv(N))] | length' "$V")" -gt 0 ] || { echo "$N no está en $V" >&2; exit 1; }
N="$N" yq -i '.ingesta.clientes |= map(select(.nombre != strenv(N))) |
  .global.parameters.grafanaClusters |= (split("|") | map(select(. != strenv(N))) | join("|"))' "$V"
echo "Baja de $N en $V. grafanaClusters: $(yq '.global.parameters.grafanaClusters' "$V")"
echo "Siguiente: git commit + push del values"
