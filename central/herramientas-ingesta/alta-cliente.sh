#!/usr/bin/env bash
# Alta de un cliente en la ingesta mTLS del monitoring-stack, sobre el values del entorno:
#   - añade el cliente a ingesta.clientes (nombre, su CA pública y, si se da, su IP)
#   - añade su tenant a global.parameters.grafanaClusters (datasources de Grafana)
# NO toca el clúster: el alta real es el commit + push del values (Argo CD crea TLSOption, Middlewares e IngressRoute).
#   uso: alta-cliente.sh -f values-entorno.yaml <nombre> <ca.crt> [ip/32 ...]
# Antes del commit: comparar la huella que imprime con la que el cliente ha dado POR OTRO CANAL.
set -euo pipefail
[ "${1:-}" = -f ] || { echo "uso: $0 -f values-entorno.yaml <nombre> <ca.crt> [ip/32 ...]" >&2; exit 2; }
V=${2:?values}; N=${3:?nombre}; CA=${4:?ca.crt}; shift 4
command -v yq >/dev/null || { echo "falta yq (mikefarah, v4)" >&2; exit 1; }
[ -f "$V" ] || { echo "no existe $V" >&2; exit 1; }
[[ $N =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "nombre no válido: $N" >&2; exit 1; }
for ip in "$@"; do [[ $ip =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || { echo "IP no válida (falta /32?): $ip" >&2; exit 1; }; done
openssl x509 -in "$CA" -noout -text | grep -q 'CA:TRUE' || { echo "$CA no es una CA" >&2; exit 1; }
openssl x509 -in "$CA" -noout -checkend 0 >/dev/null || { echo "$CA está caducada" >&2; exit 1; }
PEM=$(openssl x509 -in "$CA")
otro=$(PEM="$PEM" yq '.ingesta.clientes[] | select(.cas[]? | contains(strenv(PEM))) | .nombre' "$V" | grep -vx "$N" | head -1 || true)
[ -z "$otro" ] || { echo "esa CA ya es de $otro" >&2; exit 1; }
HUELLA=$(openssl x509 -in "$CA" -noout -fingerprint -sha256 | cut -d= -f2)
N="$N" PEM="$PEM" yq -i '
  .ingesta.clientes = ((.ingesta.clientes // []) | map(select(.nombre != strenv(N)))) |
  .ingesta.clientes += [{"nombre": strenv(N), "cas": [strenv(PEM) + "\n"]}] |
  (.ingesta.clientes[] | select(.nombre == strenv(N)) | .cas[0]) style="literal"' "$V"
for ip in "$@"; do
  N="$N" IP="$ip" yq -i '(.ingesta.clientes[] | select(.nombre == strenv(N)) | .ipPermitidas) += [strenv(IP)] |
    (.ingesta.clientes[] | select(.nombre == strenv(N)) | .ipPermitidas) style="flow"' "$V"
done
N="$N" COM="Alta $(date +%F). Huella SHA-256 de la CA: $HUELLA" yq -i '(.ingesta.clientes[] | select(.nombre == strenv(N))) head_comment = strenv(COM)' "$V"
T=$(yq '.global.parameters.grafanaClusters // ""' "$V")
if printf '%s' "$T" | tr '|' '\n' | grep -qx "$N"; then echo "$N ya estaba en grafanaClusters"
else N="$N" yq -i '.global.parameters.grafanaClusters = ((.global.parameters.grafanaClusters // "") + (select(.global.parameters.grafanaClusters != "") | "|") + strenv(N) | sub("^\|"; ""))' "$V"; echo "Añadido $N a grafanaClusters"; fi
echo "Cliente $N en $V"; openssl x509 -in "$CA" -noout -subject -enddate; echo "Huella SHA-256: $HUELLA"
echo "Siguiente: comparar la huella con el cliente por otro canal; git commit + push del values"
