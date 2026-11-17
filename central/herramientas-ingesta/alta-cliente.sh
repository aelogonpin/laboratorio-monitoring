#!/usr/bin/env bash
# Alta de un cliente en la ingesta mTLS del monitoring-stack (modo caSecret):
#   - su CA PÚBLICA al Secret ingesta-ca-<nombre> (clave ca.crt) del namespace de las CAs, en el clúster central,
#     con el kubectl actual (KUBECONFIG del central). No va en el values.
#   - el cliente en ingesta.clientes del values del entorno: nombre, caSecret: true y, si se dan, sus IPs
#   - su tenant en global.parameters.grafanaClusters (datasources de Grafana)
# Después: git commit + push del values (Argo CD crea listener, ClientTrafficPolicy, HTTPRoute...).
#   uso: alta-cliente.sh -f values-entorno.yaml [-n namespace] [--anadir] [--sin-secret] <nombre> <ca.crt> [ip/32 ...]
#   -n           namespace de las CAs (por defecto ingesta.casClientes.namespace del values, o ingesta-clientes)
#   --anadir     añade la CA a las que ya tiene el cliente: cambio de CA sin corte. Sin él, la CA SUSTITUYE a las
#                que hubiera (así se termina el cambio, cuando el cliente ya usa la nueva)
#   --sin-secret no toca el clúster: imprime el Secret para crearlo por otro camino (External Secrets, otro equipo)
# Antes del push: comparar la huella que imprime con la que el cliente ha dado POR OTRO CANAL.
set -euo pipefail
uso() { echo "uso: $0 -f values-entorno.yaml [-n namespace] [--anadir] [--sin-secret] <nombre> <ca.crt> [ip/32 ...]" >&2; exit 2; }
V= NS= ANADIR= SIN_SECRET=
while [ $# -gt 0 ]; do
  case $1 in
    -f) V=${2:?}; shift 2 ;;
    -n) NS=${2:?}; shift 2 ;;
    --anadir) ANADIR=1; shift ;;
    --sin-secret) SIN_SECRET=1; shift ;;
    -*) uso ;;
    *) break ;;
  esac
done
[ -n "$V" ] && [ $# -ge 2 ] || uso
N=$1; CA=$2; shift 2
for b in yq openssl; do command -v $b >/dev/null || { echo "falta $b" >&2; exit 1; }; done
[ -n "$SIN_SECRET" ] || command -v kubectl >/dev/null || { echo "falta kubectl" >&2; exit 1; }
[ -f "$V" ] || { echo "no existe $V" >&2; exit 1; }
[[ $N =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "nombre no válido: $N" >&2; exit 1; }
for ip in "$@"; do [[ $ip =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || { echo "IP no válida (falta /32?): $ip" >&2; exit 1; }; done
openssl x509 -in "$CA" -noout -text | grep -q 'CA:TRUE' || { echo "$CA no es una CA" >&2; exit 1; }
openssl x509 -in "$CA" -noout -checkend 0 >/dev/null || { echo "$CA está caducada" >&2; exit 1; }
[ -n "$NS" ] || NS=$(yq '.ingesta.casClientes.namespace // ""' "$V")
[ -n "$NS" ] || NS=ingesta-clientes
S=ingesta-ca-$N
PEM=$(openssl x509 -in "$CA")
HUELLA=$(openssl x509 -in "$CA" -noout -fingerprint -sha256 | cut -d= -f2)

# Huellas SHA-256 de todos los certificados de un PEM (stdin), una por línea
huellas() {
  local t; t=$(mktemp -d)
  awk -v d="$t" '/BEGIN CERTIFICATE/{n++} n{print > (d "/" n ".pem")}'
  for f in "$t"/*.pem; do [ -e "$f" ] && openssl x509 -in "$f" -noout -fingerprint -sha256 | cut -d= -f2; done
  rm -rf -- "$t"
}
leer_ca() { kubectl -n "$NS" get secret "$1" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d || true; }

BUNDLE=$PEM
if [ -z "$SIN_SECRET" ]; then
  # La misma CA no puede ser de dos clientes
  for otro in $(kubectl -n "$NS" get secret -l ingesta.cliente -o jsonpath='{range .items[*]}{.metadata.labels.ingesta\.cliente}{"\n"}{end}' 2>/dev/null); do
    [ "$otro" = "$N" ] && continue
    if leer_ca "ingesta-ca-$otro" | huellas | grep -qx "$HUELLA"; then echo "esa CA ya es de $otro" >&2; exit 1; fi
  done
  if [ -n "$ANADIR" ]; then
    ACTUAL=$(leer_ca "$S")
    [ -n "$ACTUAL" ] || { echo "--anadir: $N no tiene aún el Secret $NS/$S" >&2; exit 1; }
    if printf '%s\n' "$ACTUAL" | huellas | grep -qx "$HUELLA"; then echo "esa CA ya estaba en $NS/$S"; BUNDLE=$ACTUAL
    else BUNDLE=$(printf '%s\n%s' "$ACTUAL" "$PEM"); fi
  fi
fi

manifiesto() {
  kubectl create secret generic "$S" -n "$NS" --from-literal=ca.crt="$BUNDLE"$'\n' --dry-run=client -o yaml \
    | kubectl label --local -f - ingesta.cliente="$N" -o yaml
}
if [ -n "$SIN_SECRET" ]; then
  echo "--- Secret a crear en el central (solo parte pública):"; manifiesto
else
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
  manifiesto | kubectl apply -f -
  echo "CAs en $NS/$S:"; printf '%s\n' "$BUNDLE" | huellas | sed 's/^/  /'
fi

# Values: solo nombre, caSecret e IPs. Si ya estaba, conserva el resto de su entrada (tenant, senales...).
if [ -z "$ANADIR" ]; then
  N="$N" yq -i '
    .ingesta.clientes = (.ingesta.clientes // []) |
    with(select([.ingesta.clientes[] | select(.nombre == strenv(N))] | length == 0); .ingesta.clientes += [{"nombre": strenv(N)}]) |
    (.ingesta.clientes[] | select(.nombre == strenv(N))) |= (del(.cas) | .caSecret = true)' "$V"
  for ip in "$@"; do
    N="$N" IP="$ip" yq -i '(.ingesta.clientes[] | select(.nombre == strenv(N)) | .ipPermitidas) |= ((. // []) + [strenv(IP)] | unique) |
      (.ingesta.clientes[] | select(.nombre == strenv(N)) | .ipPermitidas) style="flow"' "$V"
  done
  N="$N" COM="Alta $(date +%F). Huella SHA-256 de la CA: $HUELLA" yq -i '(.ingesta.clientes[] | select(.nombre == strenv(N))) head_comment = strenv(COM)' "$V"
  T=$(yq '.global.parameters.grafanaClusters // ""' "$V")
  if printf '%s' "$T" | tr '|' '\n' | grep -qx "$N"; then echo "$N ya estaba en grafanaClusters"
  else N="$N" yq -i '.global.parameters.grafanaClusters = ((.global.parameters.grafanaClusters // "") + (select(.global.parameters.grafanaClusters != "") | "|") + strenv(N) | sub("^\|"; ""))' "$V"; echo "Añadido $N a grafanaClusters"; fi
  echo "Cliente $N en $V"
fi
openssl x509 -in "$CA" -noout -subject -enddate; echo "Huella SHA-256: $HUELLA"
if [ -n "$ANADIR" ]; then echo "Siguiente: cuando el cliente use la CA nueva, repetir sin --anadir para dejar solo esa"
else echo "Siguiente: comparar la huella con el cliente por otro canal; git commit + push del values"; fi
