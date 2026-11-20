# Guía: clientes de la ingesta mTLS

Cómo dar de alta, renovar, cambiar la CA y dar de baja a un cliente que envía métricas y logs al central por mTLS,
entendiendo cada paso. Los ejemplos son del laboratorio (`k0s-central`, `k0s-cliente`, `cliente-demo`, Vault en el
central); en otro entorno cambian el kubeconfig, el values, el dominio y el Vault.

## 0. Cómo funciona

**Todo se gestiona en el central.** El central crea la CA de cada cliente y su certificado, y los deja en Vault; el
cliente solo los trae con External Secrets (ESO). Nadie entra en el clúster del cliente para dar de alta, renovar o
cambiar nada.

```
CENTRAL (cert-manager + ESO)                         VAULT (KV ingesta/)               CLIENTE (ESO)
 ingesta.clientes: [{nombre: cliente-demo}]
  ├─ CA ca-cliente-demo (10 años, protegida)
  ├─ certificado cliente-cliente-demo ─PushSecret─▶ clientes/cliente-demo ─ExternalSecret─▶ Secret ingesta-mtls
  │   (90 días, se renueva a falta de 30)            {tls.crt, tls.key}                     (monitoring, logging)
  └─ CA de servidor (solo lab) ───────PushSecret─▶ servidor {ca.crt} ──ExternalSecret─▶ Secret ingesta-ca-servidor
                                                                                          │
 Envoy, listener cliente-demo.ingest.<dominio>  ◀────────── mTLS ─────────── Prometheus / Fluentd
  ├─ ClientTrafficPolicy: solo certificados firmados por ca-cliente-demo
  ├─ HTTPRoute: solo rutas de envío, X-Scope-OrgID = cliente-demo (lo pone el servidor)
  └─ SecurityPolicy: solo sus IPs (ipPermitidas)
```

| Pieza | Dónde | Quién la crea |
|---|---|---|
| El cliente: nombre, IPs, duración del certificado | `ingesta.clientes` del values del entorno (`values-laboratorio.yaml`) | Tú, editando el YAML |
| Su CA, su certificado, el PushSecret, el listener, la política, la ruta y las alertas | Namespace `monitoring` del central | Argo CD, a partir del values |
| Su entrada en Vault: política (leer solo `clientes/<cliente>` y `servidor`) y AppRole | Vault | El equipo de Vault (en el lab, `central/infra/vault-config/`) |
| `global.appName`, la URL de Vault y el AppRole | Application `herramientas-cliente` del cliente | El repo de despliegue del cliente |

**Lo que hay que tener presente:**
- **La clave privada del cliente se genera en el central** y viaja por Vault, cifrada y auditada. Por eso la política
  de cada cliente en Vault solo le deja leer **lo suyo**: si pudiera leer `clientes/*`, podría hacerse pasar por otro.
- **La CA de cada cliente (`ca-<cliente>`) no se puede perder.** Si se borra, mientras falta Envoy **deja de exigir
  certificado** en ese listener, y cert-manager crea otra CA: el certificado que tiene el cliente deja de valer. La
  protege una ValidatingAdmissionPolicy (sección 6) y avisan dos alertas críticas (sección 5).
- **La renovación es una cadena** (sección 2). Si un eslabón falla, el cliente sigue con el certificado viejo hasta
  que caduque: los 30 días de `renovarAntes` son el margen para arreglarlo.

---

## 1. Alta de un cliente

Ejemplo: `cliente-b`, con IP de salida `203.0.113.10`.

### 1.1 En Vault: su política y su AppRole

Lo hace quien gestiona Vault. La política del cliente, **solo lectura y solo lo suyo**:

```hcl
path "ingesta/data/clientes/cliente-b" { capabilities = ["read"] }
path "ingesta/data/servidor"           { capabilities = ["read"] }
```

Y un AppRole (`cliente-b`) con esa política. Al cliente se le entregan su `role_id` y su `secret_id` (este último es
una credencial: nunca en Git en producción).

El AppRole del central ya existe y puede escribir en `clientes/*` y `servidor`: no se toca en cada alta.

**En el laboratorio** lo hace el CronJob `vault-config` (cada 2 min): añade el cliente a `clientes` en
`central/infra/vault-config/configuracion.yaml` y sus `cliente-b-role-id` / `cliente-b-secret-id` (dos UUID nuevos) a
`central/infra/vault-config/secretos.yaml`.

### 1.2 En el central: el cliente en el values

En `central/monitoring-laboratorio/values-laboratorio.yaml`:

```yaml
ingesta:
  clientes:
    - nombre: cliente-b                  # = global.appName del cliente: host, tenant y ruta en Vault
      ipPermitidas: [203.0.113.10/32]    # su IP de salida (CIDR); sin esto, entra desde cualquier IP
```

Y su tenant en Grafana, en el mismo fichero: `grafanaClusters: k0s-central|cliente-demo|cliente-b`.

Opcionales: `tenant` (si no es el nombre), `senales: [logs]` o `[metricas]` (por defecto las dos), `certificado:
{duracion, renovarAntes}` (por defecto 90 días y 30).

```bash
git commit -am "ingesta: alta de cliente-b" && git push
```

### 1.3 Comprobar el central

```bash
export KUBECONFIG=~/.kube/k0s-central.yaml
kubectl -n monitoring get certificate ca-cliente-b cliente-cliente-b       # READY True
kubectl -n monitoring get pushsecret ingesta-cliente-b                      # Synced
kubectl -n monitoring get clienttrafficpolicy ingesta-cliente-b \
  -o jsonpath='{range .status.ancestors[0].conditions[*]}{.type}={.status} {end}{"\n"}'   # Accepted=True
```

- `ca-cliente-b` es su CA; `cliente-cliente-b`, su certificado (`CN=cliente-b`), firmado por ella.
- El PushSecret sube **solo** `tls.crt` y `tls.key` del certificado. Nunca la CA (que lleva su clave privada).
- **Sin certificado, el listener ya rechaza:**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -k -X POST https://cliente-b.ingest.10.99.90.58.nip.io/api/v1/push   # 000
```

`000` = el TLS se corta antes de llegar a HTTP: Envoy pidió certificado y no se lo dieron.

En Vault (en el laboratorio, desde el pod de Vault), que está y qué claves tiene, **sin enseñar la clave**:

```bash
kubectl -n vault exec vault-0 -- vault kv get -address=http://127.0.0.1:8200 -format=json ingesta/clientes/cliente-b \
  | python3 -c 'import sys,json; print(sorted(json.load(sys.stdin)["data"]["data"]))'      # ['tls.crt', 'tls.key']
```

### 1.4 En el cliente: su Application

En la Application `herramientas-cliente` de su repo de despliegue (ejemplo:
`cliente/cliente-demo-k8s/aplicaciones-cliente-demo/herramientas-cliente.yaml`):

```yaml
valuesObject:
  global:
    appName: cliente-b
  ingesta:
    vault:
      server: https://vault.<dominio>
      appRole: {roleId: <role_id de cliente-b>}
```

Y el `secret_id` en el Secret `external-secrets/vault-approle` (clave `secret-id`). Si el clúster ya tiene un
ClusterSecretStore hacia Vault con ese acceso, en vez de lo anterior:
`ingesta.vault.almacen: {crear: false, nombre: <el suyo>}`.

### 1.5 Comprobar el cliente y los datos

```bash
export KUBECONFIG=~/.kube/k0s-cliente.yaml
kubectl get clustersecretstore ingesta-vault           # Valid, Ready
kubectl get externalsecret -A                          # ingesta-mtls e ingesta-ca-servidor: SecretSynced
kubectl -n monitoring get secret ingesta-mtls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -enddate      # CN=cliente-b, issuer CN=ingesta-ca-cliente-b
```

Hasta que el ExternalSecret trae el certificado (`refreshInterval`, 1 h por defecto; en el lab 5 min), Prometheus
espera (*secret "ingesta-mtls" not found*) y Fluentd no se crea. Para no esperar:
`kubectl -n monitoring annotate externalsecret ingesta-mtls force-sync=$(date +%s) --overwrite` (y en `logging`).

**Si Fluentd no aparece** con el Secret ya creado: el logging-operator deja de reintentar cuando su Output falla por
un Secret que no existe (`kubectl -n logging get clusteroutput` → `PROBLEMS`). Se arregla reiniciándolo, una vez:
`kubectl -n logging rollout restart deploy/operator`.

En el central, que llegan datos con su tenant:

```promql
# Prometheus del central: respuestas de los backends por cliente (2xx = entra)
sum by (envoy_cluster_name, envoy_response_code_class) (increase(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/monitoring/ingesta-cliente-b/.*"}[5m]))
```

Y en Grafana, el datasource de Mimir/Loki con el tenant `cliente-b`.

### 1.6 Sin Vault: entrega a mano

Con `ingesta.origen: manual` en el cliente, el chart no crea nada y los Secrets se ponen a mano. Lo que haría ESO:

```bash
# en el central: certificado y clave del cliente, y la CA de servidor (ficheros temporales, fuera del repo)
kubectl --kubeconfig ~/.kube/k0s-central.yaml -n monitoring get secret cliente-cliente-b -o jsonpath='{.data.tls\.crt}' | base64 -d > tls.crt
kubectl --kubeconfig ~/.kube/k0s-central.yaml -n monitoring get secret cliente-cliente-b -o jsonpath='{.data.tls\.key}' | base64 -d > tls.key
kubectl --kubeconfig ~/.kube/k0s-central.yaml -n monitoring get secret ingesta-ca-servidor -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
# en el cliente, en monitoring y en logging
for ns in monitoring logging; do
  kubectl --kubeconfig ~/.kube/<cliente>.yaml -n $ns create secret tls ingesta-mtls --cert=tls.crt --key=tls.key
  kubectl --kubeconfig ~/.kube/<cliente>.yaml -n $ns create secret generic ingesta-ca-servidor --from-file=ca.crt
done
shred -u tls.key; rm tls.crt ca.crt
```

Y en cada renovación (sección 2) hay que repetirlo **antes de que caduque el anterior**. Por eso, con Vault.

---

## 2. Renovación (sola)

```
1. cert-manager (central) renueva cliente-<cliente> a falta de renovarAntes      → Secret nuevo (clave nueva)
2. PushSecret (central) lo sube a Vault en su siguiente vuelta (refreshInterval)  → clientes/<cliente> v+1
3. ExternalSecret (cliente) lo baja en su siguiente vuelta (refreshInterval)     → Secret ingesta-mtls nuevo
4. Prometheus lo relee solo; Reloader reinicia Fluentd (anotación secret.reloader.stakater.com/reload)
```

- **Cuánto tarda**: en el laboratorio (19/11/2026, `refreshInterval` de 5 min) la cadena entera tardó **46 s**:
  renovado 21:55:42, en Vault 21:55:57, en el cliente 21:56:13, Fluentd reiniciado 21:56:28, sin ningún envío fallido.
  El tope es la suma de los dos `refreshInterval` (1 h + 1 h por defecto); con 30 días de margen da igual. Ojo: si el
  Secret se **borra** y se vuelve a crear (sección 2, forzar), el PushSecret no lo subió hasta su siguiente vuelta;
  para no esperar, `force-sync` (como en 1.5) en el PushSecret `ingesta-<cliente>` y en los ExternalSecret del cliente.
- **No hay corte**: el certificado viejo sigue valiendo hasta que caduca, y Envoy acepta los dos (misma CA).
- **Si se rompe un eslabón** (Vault caído, AppRole del cliente sin permiso, ESO roto), el cliente sigue con el viejo:
  avisan `IngestaEntregaClienteFalla` (paso 2) y, si de verdad caduca, `IngestaClienteSinDatos`. El paso 3 se ve en
  el propio cliente (`kubectl get externalsecret -A`) o en sus métricas de ESO, que llegan al central con su tenant.

**Forzar una renovación** (prueba, o tras sospechar que la clave se ha filtrado): borrar el Secret del certificado (no
el de la CA). cert-manager emite otro con clave nueva en segundos:

```bash
kubectl --kubeconfig ~/.kube/k0s-central.yaml -n monitoring delete secret cliente-cliente-b
```

**Ojo, revocar no existe aquí**: Envoy no comprueba CRL. Un certificado filtrado sigue valiendo hasta que caduca.
Si hay que cortarlo ya, cambiar la CA del cliente (sección 3).

---

## 3. Cambio de CA de un cliente (cortar un certificado ya)

Para invalidar **todos** los certificados de un cliente: su CA nueva hace que el listener deje de aceptar los
firmados con la vieja. Hay un corte de unos minutos para ese cliente (hasta que le llega el certificado nuevo).

```bash
export KUBECONFIG=~/.kube/k0s-central.yaml
kubectl -n monitoring annotate secret ca-cliente-b ingesta.borrable=true
kubectl -n monitoring delete secret ca-cliente-b          # cert-manager crea otra CA (y otro Secret protegido)
kubectl -n monitoring delete secret cliente-cliente-b     # certificado nuevo, firmado por la CA nueva
kubectl -n monitoring annotate pushsecret ingesta-cliente-b force-sync=$(date +%s) --overwrite
```

Y en el cliente, `force-sync` de sus dos ExternalSecret `ingesta-mtls` (o esperar su `refreshInterval`).
Durante esos segundos sin `ca-cliente-b`, Envoy no exige certificado en su listener: con `ipPermitidas` solo entra
desde sus IPs. Por eso se hace seguido y no se deja a medias.

---

## 4. Baja de un cliente

1. **Quitarlo del values** (y de `grafanaClusters`), commit y push. Argo CD borra su listener, ClientTrafficPolicy,
   HTTPRoute, SecurityPolicy, sus Certificate y su PushSecret, que **borra su entrada de Vault**
   (`deletionPolicy: Delete`).

   ```bash
   kubectl -n monitoring get clienttrafficpolicy,httproute,pushsecret,certificate -l ingesta.cliente=cliente-b   # vacío
   ```

2. **Borrar sus dos Secrets**, que cert-manager no borra al borrar los Certificate. El de la CA está protegido:

   ```bash
   kubectl -n monitoring annotate secret ca-cliente-b ingesta.borrable=true
   kubectl -n monitoring delete secret ca-cliente-b cliente-cliente-b
   ```

3. **En Vault**: quitar su política y su AppRole (en el lab, de `vault-config`).
4. **En el cliente**: `ingesta.enabled: false`. Sus Secrets se quedan (`deletionPolicy: Retain`), pero ya no le valen:
   su listener no existe.

Los datos que ya envió siguen en Mimir y Loki con su tenant hasta que caduquen por retención.

---

## 5. Alertas

| Alerta | Qué significa | Qué hacer |
|---|---|---|
| `IngestaPoliticaClienteNoAplicada` (critical) | Su ClientTrafficPolicy no está `Accepted`: su listener **no exige certificado** | `kubectl -n monitoring get clienttrafficpolicy ingesta-<c> -o yaml` (status). Casi siempre: falta `ca-<c>` |
| `IngestaCAClienteFalta` (critical) | Falta el Secret `ca-<c>` | cert-manager crea otra CA: el cliente necesita certificado nuevo (sección 3, pasos de `delete secret cliente-…` y `force-sync`) |
| `IngestaEntregaClienteFalla` (warning) | Su PushSecret no consigue subir a Vault | `kubectl -n monitoring describe pushsecret ingesta-<c>`: ClusterSecretStore `vault`, AppRole del central |
| `IngestaCertificadoClienteSinRenovar` (warning) | Ha pasado su hora de renovar (`renewBefore`) y cert-manager no lo ha hecho | `kubectl -n monitoring describe certificate cliente-<c>` y sus CertificateRequest |
| `IngestaCertificadoClienteCaducaPronto` (critical) | Sigue sin renovar y ya ha gastado la mitad del margen | Lo mismo, ya con prisa |
| `IngestaClienteSinDatos` (warning) | Ninguna respuesta 2xx de sus envíos en 30 min | Su certificado (¿le llegó el nuevo?), su red, sus agentes. Agente `diagnostico-ingesta-mtls` |
| `IngestaCertificadoNoListo` (warning) | Un Certificate de `monitoring` no está listo | `kubectl -n monitoring describe certificate <nombre>` |

---

## 6. Protecciones, por dentro

**ValidatingAdmissionPolicy** `monitoring-ingesta-cas-clientes` (`templates/ingesta/proteccion.yaml`), sobre los
Secrets con la etiqueta `ingesta.ca` del namespace `monitoring` (las CAs de los clientes). La evalúa el propio API
server (sin webhook):

| Intento | Resultado |
|---|---|
| Borrar sin `ingesta.borrable=true` | Forbidden |
| Crear o cambiar con un `tls.crt` que no empieza por `-----BEGIN CERTIFICATE-----` | Invalid |
| Quitar o cambiar la etiqueta `ingesta.ca` | Forbidden |

Probarla sin romper nada (`--dry-run=server` pasa por la admisión pero no guarda):

```bash
kubectl -n monitoring delete secret ca-cliente-demo --dry-run=server          # Forbidden
kubectl -n monitoring label secret ca-cliente-demo ingesta.ca- --dry-run=server  # Forbidden
```

- En CEL, `data` llega en base64 y no hay `base64.decode`: se compara con el base64 de `-----BEGIN CERTIFICATE-----`.
- cert-manager no borra los Secrets al borrar un Certificate, así que la protección no estorba a sus renovaciones.
- Si se quitan todos los clientes del values, la política desaparece con ellos.

**Métricas de estado** (kube-state-metrics, `customResourceState` en el values del chart):
`ingesta_clienttrafficpolicy_condicion{name, type}` y `ingesta_pushsecret_condicion{name, type}` (1 = True).
