#!/usr/bin/env bash
# Baja de un cliente de la ingesta mTLS, en dos pasos y en este orden:
#   1) baja-cliente.sh -f values-entorno.yaml <nombre>
#      Lo quita de ingesta.clientes y su tenant de grafanaClusters. Después: git commit + push. Argo CD borra su
#      listener, ClientTrafficPolicy, HTTPRoute y SecurityPolicy: queda fuera en el TLS.
#   2) baja-cliente.sh --borrar-secret [-n namespace] <nombre>      (con el KUBECONFIG del central)
#      Borra su Secret ingesta-ca-<nombre> (le pone ingesta.borrable=true, que exige la ValidatingAdmissionPolicy),
#      solo si Argo CD ya quitó su ClientTrafficPolicy.
# El orden importa: si el Secret desaparece con el listener aún puesto, Envoy deja de exigir el certificado en ese
# listener (la ClientTrafficPolicy queda sin aplicar). Los datos ya enviados se quedan en Mimir/Loki.
set -euo pipefail
uso() { echo "uso: $0 -f values-entorno.yaml <nombre> | $0 --borrar-secret [-n namespace] [--ns-release monitoring] <nombre>" >&2; exit 2; }
V= NS=ingesta-clientes REL=monitoring BORRAR=
while [ $# -gt 0 ]; do
  case $1 in
    -f) V=${2:?}; shift 2 ;;
    -n) NS=${2:?}; shift 2 ;;
    --ns-release) REL=${2:?}; shift 2 ;;
    --borrar-secret) BORRAR=1; shift ;;
    -*) uso ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || uso
N=$1
[[ $N =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "nombre no válido: $N" >&2; exit 1; }

if [ -n "$BORRAR" ]; then
  if kubectl -n "$REL" get clienttrafficpolicy "ingesta-$N" >/dev/null 2>&1; then
    echo "La ClientTrafficPolicy $REL/ingesta-$N sigue: primero el paso 1 (values + push) y que Argo CD sincronice" >&2; exit 1
  fi
  if kubectl -n "$NS" get secret "ingesta-ca-$N" >/dev/null 2>&1; then
    # La ValidatingAdmissionPolicy de la ingesta solo deja borrarlo con esta anotación
    kubectl -n "$NS" annotate secret "ingesta-ca-$N" ingesta.borrable=true --overwrite >/dev/null
    kubectl -n "$NS" delete secret "ingesta-ca-$N"
  else echo "No existe $NS/ingesta-ca-$N"; fi
  exit 0
fi

[ -n "$V" ] || uso
[ -f "$V" ] || { echo "no existe $V" >&2; exit 1; }
[ "$(N="$N" yq '[.ingesta.clientes[]? | select(.nombre == strenv(N))] | length' "$V")" -gt 0 ] || { echo "$N no está en $V" >&2; exit 1; }
N="$N" yq -i '.ingesta.clientes |= map(select(.nombre != strenv(N))) |
  .global.parameters.grafanaClusters |= (split("|") | map(select(. != strenv(N))) | join("|"))' "$V"
echo "Baja de $N en $V. grafanaClusters: $(yq '.global.parameters.grafanaClusters' "$V")"
echo "Siguiente: git commit + push del values; cuando Argo CD sincronice: $0 --borrar-secret $N"
