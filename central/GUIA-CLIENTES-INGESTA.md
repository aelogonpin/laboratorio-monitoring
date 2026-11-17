# Guía: clientes de la ingesta mTLS en el central

Cómo dar de alta, cambiar la CA y dar de baja a un cliente que envía métricas y logs al central por mTLS, a mano,
entendiendo cada paso. Los ejemplos usan el laboratorio (`k0s-central`, `k0s-cliente`, `cliente-demo`); en otro
entorno cambian el kubeconfig, el values y el dominio.

## 0. Cómo funciona

```
CLIENTE (su cert-manager)                         CENTRAL
  CA del cliente  ── solo ca.crt (público) ──▶  Secret ingesta-clientes/ingesta-ca-<cliente>
   └─ firma su certificado (CN=<cliente>)          │
        │                                          ▼
        └── Prometheus / Fluentd ── mTLS ──▶  Envoy, listener <cliente>.ingest.<dominio>
                                               ├─ ClientTrafficPolicy: solo certificados de ESA CA
                                               ├─ HTTPRoute: solo rutas de envío, X-Scope-OrgID = <cliente>
                                               └─ SecurityPolicy: solo sus IPs (si ipPermitidas)
```

Hay tres piezas en el central, y cada una vive en un sitio distinto:

| Pieza | Dónde | Quién la crea |
|---|---|---|
| La CA pública del cliente | Secret `ingesta-ca-<cliente>` en el namespace `ingesta-clientes` | Tú, con `kubectl apply` (o External Secrets) |
| El cliente: nombre e IPs | `ingesta.clientes` del values del entorno (`values-laboratorio.yaml`) | Tú, editando el YAML |
| Listener, ClientTrafficPolicy, HTTPRoute, SecurityPolicy, alertas | Namespace `monitoring` | Argo CD, a partir del values |

Del cliente no se guarda **nada privado**: la clave de su CA y la de su certificado no salen nunca de su clúster.

### La regla más importante

**El Secret de la CA tiene que existir mientras exista el listener del cliente.** Si falta, o su `ca.crt` no vale,
la ClientTrafficPolicy se queda `Accepted=False` y **Envoy deja de pedir certificado** en ese listener. Entonces
puede entrar cualquiera con el tenant de ese cliente. Lo probamos en el laboratorio, y solo lo paró `ipPermitidas`.

Por eso:
- **Alta**: primero el Secret, después el values.
- **Baja**: primero el values, y cuando Argo CD ya ha quitado el listener, el Secret.
- El chart pone dos protecciones (sección 5): una ValidatingAdmissionPolicy que impide borrar o estropear esos
  Secrets por accidente, y dos alertas críticas si aun así falta algo.

---

## 1. Alta de un cliente

Ejemplo: `cliente-b`, con IP de salida `203.0.113.10`.

### 1.1 En el cliente: que tenga su CA

En su Application de `herramientas-cliente`, `global.appName: cliente-b`. Con eso, su cert-manager crea:
- su CA (`cert-manager/ingesta-ca`);
- su certificado `CN=cliente-b`;
- la URL `https://cliente-b.ingest.<dominio>`.

Mira `cliente/herramientas-cliente/templates/ingesta-mtls.yaml`.

### 1.2 Sacar su CA pública

```bash
kubectl --kubeconfig ~/.kube/<cliente>.yaml -n cert-manager get secret ingesta-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > cliente-b-ca.crt
```

- El Secret `ingesta-ca` tiene tres claves: `tls.crt`, `tls.key` y `ca.crt`. **Solo** sacamos `ca.crt`, que es público.
- `tls.key` es la clave de la CA y no sale nunca del cliente.
- En un cliente real, te lo manda él (por correo, ticket...) y es el mismo fichero.

### 1.3 Comprobar que es lo que dice ser

```bash
openssl x509 -in cliente-b-ca.crt -noout -subject -issuer -dates
openssl x509 -in cliente-b-ca.crt -noout -text | grep -A1 'Basic Constraints'   # tiene que decir CA:TRUE
openssl x509 -in cliente-b-ca.crt -noout -checkend 0 && echo "no ha caducado"
openssl x509 -in cliente-b-ca.crt -noout -fingerprint -sha256
```

- Con `CA:TRUE` sabes que es una CA, y no un certificado suelto.
- La **huella SHA-256** compárala con la que el cliente te dé **por otro canal**: teléfono, otro correo... Es lo que
  impide que alguien te cuele su propia CA haciéndose pasar por el cliente. Anótala: la vas a poner como comentario
  en el values.

### 1.4 Comprobar que esa CA no es ya de otro cliente

Si dos clientes compartieran CA, uno podría usar el certificado del otro.

```bash
export KUBECONFIG=~/.kube/k0s-central.yaml
for s in $(kubectl -n ingesta-clientes get secret -l ingesta.cliente -o name); do
  echo "$s: $(kubectl -n ingesta-clientes get $s -o jsonpath='{.data.ca\.crt}' | base64 -d \
    | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)"
done
```

- Ninguna huella de la lista debe coincidir con la del 1.3.
- Este `openssl` solo enseña la primera CA de cada Secret. Si alguno está a mitad de un cambio de CA (sección 2), tiene dos.

### 1.5 Crear el Secret con la CA en el central (ANTES del values)

Escribe un fichero, por ejemplo `/tmp/ingesta-ca-cliente-b.yaml`, **fuera del repo**:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ingesta-ca-cliente-b            # siempre ingesta-ca-<cliente>
  namespace: ingesta-clientes           # ingesta.casClientes.namespace
  labels:
    ingesta.cliente: cliente-b          # la usan la protección (sección 5) y los listados
type: Opaque
stringData:
  ca.crt: |                             # pega aquí cliente-b-ca.crt, tal cual, desde -----BEGIN
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
```

```bash
kubectl apply -f /tmp/ingesta-ca-cliente-b.yaml
```

- `stringData` deja escribir el PEM en claro, y Kubernetes lo guarda en `data` en base64.
- El `ca.crt` tiene que **empezar** por `-----BEGIN CERTIFICATE-----`, o la protección lo rechaza.
- Si el namespace `ingesta-clientes` aún no existe (primer cliente de un central nuevo), créalo antes con
  `kubectl create namespace ingesta-clientes`. Argo CD lo adopta después.

### 1.6 Añadir el cliente al values

En `central/monitoring-laboratorio/values-laboratorio.yaml`, dentro de `ingesta.clientes`:

```yaml
    # Alta 2026-11-20. Huella SHA-256 de la CA: AB:CD:...   <- la del 1.3: así queda constancia en git
    - nombre: cliente-b              # host, CN y tenant. Igual que global.appName del cliente
      caSecret: true                 # su CA está en el Secret ingesta-ca-cliente-b de ingesta-clientes
      ipPermitidas: [203.0.113.10/32]  # opcional, pero es la segunda barrera: úsalo si sus IPs son fijas
      # tenant: otro                 # opcional: si su tenant no es su nombre
      # senales: [metricas]          # opcional: por defecto logs y métricas
```

Y su tenant en `global.parameters.grafanaClusters`, separado por `|`, para que Grafana le cree el datasource:

```yaml
    grafanaClusters: k0s-central|cliente-demo|cliente-b
```

### 1.7 Commit, push y comprobar

```bash
git add central/monitoring-laboratorio/values-laboratorio.yaml
git commit -m "ingesta: alta de cliente-b" && git push
```

Argo CD sincroniza el Application `monitoring` (o fuerza un refresh desde la UI). Después:

```bash
export KUBECONFIG=~/.kube/k0s-central.yaml
# La política tiene que estar Accepted=True. Si no, el listener NO exige certificado
kubectl -n monitoring get clienttrafficpolicy ingesta-cliente-b \
  -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'

# Sin certificado tiene que fallar en el TLS (curl da 000 y un error de handshake)
kubectl -n monitoring get secret ingesta-ca-servidor -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/srv-ca.crt
curl -sS -o /dev/null -w "%{http_code}\n" --cacert /tmp/srv-ca.crt -X POST \
  https://cliente-b.ingest.10.99.90.223.nip.io/api/v1/push
```

- **Datos**: en Grafana, el datasource de `cliente-b` con datos.
- **Envoy**: en el Prometheus del central, `envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/monitoring/ingesta-cliente-b/.*"}` con respuestas 2xx.
- Borra `/tmp/ingesta-ca-cliente-b.yaml` si quieres: lo que vale está en el clúster.

---

## 2. Cambiar la CA de un cliente sin cortarle

Envoy se fía de **todas** las CAs que haya en el `ca.crt` del Secret. Para cambiar de CA:

1. **Las dos a la vez.** Edita tu fichero del Secret: en `ca.crt`, la CA vieja y la nueva seguidas, empezando por un
   `-----BEGIN CERTIFICATE-----`. Después, `kubectl apply -f`. Envoy recarga el Secret solo, sin push ni reinicio.
2. **El cliente cambia** a su CA nueva, y su cert-manager le reemite los certificados.
3. **Solo la nueva.** Quita la vieja del `ca.crt` y aplica otra vez. Actualiza el comentario de la huella en el
   values (commit).

Compruébalo entre paso y paso: la política sigue `Accepted=True` y los datos llegan.

Si pierdes el fichero, puedes sacar el contenido actual del clúster:

```bash
kubectl -n ingesta-clientes get secret ingesta-ca-cliente-b -o jsonpath='{.data.ca\.crt}' | base64 -d
```

---

## 3. Baja de un cliente

**El orden importa**: si borras el Secret con el listener todavía puesto, ese listener se queda abierto.

1. **Values.** Quita su elemento de `ingesta.clientes` y su nombre de `grafanaClusters`. Haz commit y push.
2. **Espera a que Argo CD borre su listener.** Esto no tiene que devolver nada:
   ```bash
   kubectl -n monitoring get clienttrafficpolicy,httproute -l ingesta.cliente=cliente-b
   ```
3. **Ahora el Secret.** La protección exige marcarlo antes de borrarlo:
   ```bash
   kubectl -n ingesta-clientes annotate secret ingesta-ca-cliente-b ingesta.borrable=true
   kubectl -n ingesta-clientes delete secret ingesta-ca-cliente-b
   ```

Sus datos ya enviados se quedan en Mimir y Loki.

---

## 4. Si salta una alerta

| Alerta | Qué significa | Qué hacer |
|---|---|---|
| `IngestaCASecretFalta` (critical) | No existe el Secret de CA de un cliente que está en el values | Si el cliente sigue: vuelve a crearlo (1.2 y 1.5). Si era una baja: termina la baja (sección 3) |
| `IngestaPoliticaClienteNoAplicada` (critical) | Su ClientTrafficPolicy no está `Accepted`: su listener **no exige certificado** | Mira el `message` del status (comando del 1.7). Lo normal es que falte el Secret o que su `ca.crt` no valga |
| `IngestaClienteSinDatos` (warning) | Lleva un rato sin envíos correctos | Agente `diagnostico-ingesta-mtls`: certificado del cliente, red, agentes |

Ojo con el mensaje de Envoy Gateway cuando falta el Secret: dice *"not permitted by any ReferenceGrant"*, aunque la
ReferenceGrant esté bien. Mira primero si existe el Secret.

---

## 5. Las protecciones, por dentro

### ValidatingAdmissionPolicy

Fichero `central/monitoring-stack/templates/ingesta/proteccion.yaml`, con `ingesta.casClientes.proteger: true`.

- La evalúa el propio API server (CEL). No hay webhook ni pod que se pueda caer.
- Se aplica a los Secrets con la etiqueta `ingesta.cliente` de los namespaces de CAs.

| Intento | Resultado |
|---|---|
| Borrar el Secret | Denegado, salvo que lleve la anotación `ingesta.borrable=true` |
| Crear o cambiar `ca.crt` a algo que no empiece por `-----BEGIN CERTIFICATE-----` | Denegado |
| Quitar o cambiar la etiqueta `ingesta.cliente` (sería sacarlo de la protección) | Denegado |
| Borrar el namespace entero | Se queda en `Terminating` hasta que marques sus Secrets |

Detalles:
- En CEL, el `data` de un Secret llega en base64 y no existe `base64.decode`. Por eso se compara con el base64 de
  `-----BEGIN CERTIFICATE-----` (`LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t`), y el PEM tiene que ir al principio.
- Protege contra accidentes, no contra un administrador del clúster: quien pueda borrar la política, puede saltársela.

Pruébala en el laboratorio sin romper nada, con `--dry-run=server`:

```bash
kubectl -n ingesta-clientes delete secret ingesta-ca-cliente-demo --dry-run=server            # denegado
kubectl -n ingesta-clientes label secret ingesta-ca-cliente-demo ingesta.cliente- --dry-run=server  # denegado
```

### Alertas

Están en `central/monitoring-stack/templates/ingesta/alertas.yaml`.

- `IngestaCASecretFalta` usa `kube_secret_info` de kube-state-metrics.
- `IngestaPoliticaClienteNoAplicada` usa `ingesta_clienttrafficpolicy_condicion`. Es una métrica propia de
  kube-state-metrics (customResourceState, en `prometheus.kube-state-metrics` del values del chart), que lee el
  `status` de cada ClientTrafficPolicy. Esta alerta salta sea cual sea la causa: falta el Secret, la CA no vale o
  falta la ReferenceGrant.

```promql
ingesta_clienttrafficpolicy_condicion{type="Accepted"}   # 1 = aplicada
```

### En producción

Lo natural es que los Secrets los cree **External Secrets** desde un vault. Argo CD gestiona el `ExternalSecret`, y
si alguien borra el Secret, ESO lo vuelve a crear.

Si lo haces así:
- el Secret que genere ESO tiene que llevar la etiqueta `ingesta.cliente: <cliente>` (`target.template.metadata.labels`);
- para la baja, primero quita el cliente del values y después el `ExternalSecret`;
- antes de que ESO borre el Secret, ponle la anotación `ingesta.borrable=true`, o la protección se lo impedirá.
