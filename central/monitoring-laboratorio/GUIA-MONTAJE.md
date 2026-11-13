# Guía de montaje del laboratorio (monitoring-stack 2.0.0)

Dos clústeres k0s de un nodo, recién instalados y vacíos. Esta guía dice **qué va en cada lado, en qué orden y por
qué**. Los dos Argo CD leen este repo público de GitHub (`github.com/aelogonpin/laboratorio-monitoring`, rama
`main`), sin credenciales: no hay Gitea ni registro de charts.

| Nodo | IP | CPU / RAM / disco | kubeconfig | Papel |
|---|---|---|---|---|
| `k0s-central` | 10.99.90.223 | 8 / 24 GB / 350 GB | `~/.kube/k0s-central.yaml` | Monitorización central |
| `k0s-cliente` | 10.99.90.179 | 3 / 8 GB / 90 GB | `~/.kube/k0s-cliente.yaml` | Un cliente (`cliente-demo`) que envía logs y métricas |

Las dos tienen k0s v1.36.4+k0s.1 (`k0s install controller --single -c /etc/k0s/k0s.yaml`) con la configuración de
`k0s config create` salvo **`spec.network.serviceCIDR: 10.112.0.0/16`**: el de por defecto (`10.96.0.0/12`) contiene
la red de multipass (`10.99.90.0/24`) y k0s no aprueba entonces el certificado de servidor del kubelet (sin
`kubectl logs` ni metrics-server). Lo demás por defecto: CNI kube-router (aplica NetworkPolicy), CoreDNS y
metrics-server. **No traen StorageClass, ni Ingress, ni nada más.**

## Panorama

```
 k0s-cliente (cliente-demo)                                  k0s-central
 ┌───────────────────────────────────┐                       ┌──────────────────────────────────────────────┐
 │ cert-manager ── CA del cliente    │                       │ Envoy GW :80  HTTPRoute → Grafana (login)     │
 │   └─ certificado 24 h (se renueva)│   HTTPS + mTLS :443   │          :443 ingesta mTLS (pendiente migrar) │
 │ Prometheus ── remote_write ───────┼──────────────────────▶│  cliente-demo.ingest.<dominio>                │
 │ Fluentd    ── output loki ────────┼──────────────────────▶│   ├ TLSOption: solo la CA de cliente-demo     │
 │ Reloader (reinicia Fluentd)       │   solo de cliente     │   ├ solo rutas de envío; tenant lo pone él    │
 │                                   │   a central           │   └ → mimir-distributor / loki-write          │
 └──────────────┬────────────────────┘                       │ Mimir ── Kafka (externo)    Loki   Grafana    │
        ▲       │ git (lectura)                              │ S3 (SeaweedFS)   PostgreSQL (CNPG)            │
        │       ▼                                            │ NetworkPolicy: monitoring y logging cerrados  │
        │   GitHub (repo público) ◀──── git (lectura) ───────│ Argo CD                                       │
        │                                                    └──────────────────────────────────────────────┘
   el central NUNCA entra en el cliente     personal autorizado: kubectl port-forward a Prometheus · Alertmanager · Mimir · Loki
```

Entradas públicas del central: **solo dos**, Grafana (personas) y la ingesta (clientes). Prometheus, Alertmanager,
Mimir y Loki no tienen ruta: se entra con `kubectl port-forward` (los comandos salen en las NOTES del chart).

**El repo es público**: nada de contraseñas, tokens ni claves privadas. Los Secrets se crean a mano (1.3 y 2.1) y
`.secrets.env` está en `.gitignore`. Lo único de los clientes que va en Git es la parte **pública** de su CA.

## Estructura del repo

| Ruta | Dónde se usa |
|---|---|
| `central/raiz.yaml` + `central/infra/` | Aplicación raíz del central y su base como Applications de Argo CD (local-path, MetalLB, Envoy Gateway, cert-manager, CNPG, SeaweedFS, Secrets) |
| `central/monitoring-stack/` | Chart 2.0.0. Applications `monitoring` y `logging` |
| `central/monitoring-laboratorio/` | `values-laboratorio.yaml`, chart `kafka/` y las Applications (`argocd/`) |
| `central/herramientas-ingesta/` | `alta-cliente.sh` / `baja-cliente.sh` (en tu equipo, editan `values-laboratorio.yaml`) |
| `cliente/cliente-demo-k8s/` | `raiz.yaml` y las Applications del cliente |
| `cliente/herramientas-cliente/` | Chart que genera las Applications de las herramientas del cliente |
| `cliente/ingesta-mtls-cliente/` | Chart de la CA y el certificado del cliente |

---

## 1. Central (`k0s-central`)

Todo el central lo despliega su Argo CD desde este repo. A mano solo van dos cosas:

```bash
export KUBECONFIG=~/.kube/k0s-central.yaml
helm upgrade --install argocd argo/argo-cd --version 10.10.5 -n argocd --create-namespace -f central/infra/argocd/values.yaml
kubectl apply -f central/raiz.yaml
```

### 1.1 Lo que crea `raiz.yaml`, por olas

Cada ola espera a que la anterior esté Healthy: `central/infra/argocd/values.yaml` activa la salud de las
Applications. Si algo falla, cada app reintenta sola (`retry`).

| Ola | Application | Qué | Versión | Configuración |
|---|---|---|---|---|
| -5 | `base` | Namespaces con `monitoring=true` (monitoring, logging, seaweedfs, postgres, cert-manager, envoy-gateway-system) y los Secrets | — | `central/infra/base/` |
| -5 | `local-path-provisioner` | StorageClass `local-path` por defecto | v0.0.37 | En la Application |
| -5 | `prometheus-operator-crds` | CRDs del Prometheus Operator (el chart lleva `prometheus.crds.enabled: false`) | 32.0.1 | — |
| -4 | `metallb` | Balanceador: da IP al Service de Envoy | 0.16.1 | Pool en `central/infra/red/` |
| -4 | `envoy-gateway` | Controlador de Gateway API. **Trae sus CRDs y los de Gateway API v1.6.1 (experimental)** | 1.9.3 | Por defecto |
| -4 | `cert-manager` | PKI de la ingesta y certificado del webhook de kube-prometheus-stack | v1.21.2 | `central/infra/cert-manager/values.yaml` |
| -4 | `cnpg` | Operador CloudNativePG (trae sus CRDs) | 0.29.1 | `central/infra/cnpg/values.yaml` |
| -3 | `seaweedfs` | S3 de Mimir y Loki | 4.48.0 | `central/infra/seaweedfs/values.yaml` |
| -3 | `red` | Pool de MetalLB, `EnvoyProxy`, `GatewayClass envoy` y `Gateway principal` | — | `central/infra/red/` |
| -3 | `grafana-db` | Clúster PostgreSQL de Grafana (`grafana-db-rw.postgres.svc:5432`) | PostgreSQL 18.6 | `central/infra/postgres/` |
| 0 | `kafka` | Strimzi 1.3.0 + Kafka + topic `mimir-ingest` | — | `central/monitoring-laboratorio/kafka/` |
| 1 | `monitoring` | Grafana, Mimir, kube-prometheus-stack, cortex-tenant (y la ingesta mTLS cuando se migre) | chart 2.0.0 | `values.yaml` + `values-laboratorio.yaml` |
| 1 | `logging` | Loki | chart 2.0.0 | `values-logging.yaml` + `values-laboratorio.yaml` |

### 1.2 Entrada: MetalLB + Envoy Gateway

- k0s no trae balanceador. **MetalLB** tiene como pool **la propia IP del nodo** (`10.99.90.223/32`). Así los
  dominios `*.10.99.90.223.nip.io` no cambian, y kube-proxy (iptables) lleva el 80/443 de esa IP a Envoy.
- `EnvoyProxy principal`: Service `LoadBalancer` con **`externalTrafficPolicy: Local`**. Conserva la IP real del
  cliente, que es la que comprueba `ipPermitidas`.
- `Gateway principal` (namespace `envoy-gateway-system`), listener `http` en el 80 para todas las rutas. Grafana se
  cuelga con `grafana.route.main.parentRefs` y Argo CD con `server.httproute` (desactivado hasta que exista el Gateway).
- **Pendiente: la ingesta mTLS.** Sus plantillas aún generan recursos de Traefik, así que está **apagada**
  (`global.monitoring.ingesta: false`). Al migrarla irá en este Gateway: listener HTTPS 443 por cliente,
  `ClientTrafficPolicy` con su CA, `HTTPRoute` con `X-Scope-OrgID` y `SecurityPolicy` con sus IPs.

### 1.3 Secrets

En `central/infra/base/secretos.yaml`, **en claro**: son valores aleatorios que solo valen en este laboratorio.
**Credenciales de verdad (tokens de GitHub, nube, producción) nunca van al repo.**

| Namespace / Secret | Claves | Lo usa |
|---|---|---|
| `monitoring/monitoring-secrets` | `s3AccessKey`, `s3SecretKey`, `lokiUser`, `lokiPass`, `admin-user`, `grafana-admin-password`, `clusterName` (`k0s-central`), `distro`, `grafana-db-pass` | Grafana, Mimir, Prometheus |
| `logging/monitoring-secrets` | `s3AccessKey`, `s3SecretKey`, `.htpasswd` | Loki (S3 y basic auth de su gateway, que usa Grafana) |
| `postgres/grafana-db-credentials` | `username`, `password` (tipo basic-auth) | CNPG, al crear la base de datos |
| `seaweedfs/seaweedfs-s3-config` | `seaweedfs_s3_config` | SeaweedFS |

### 1.4 Comprobaciones del central

```bash
export KUBECONFIG=~/.kube/k0s-central.yaml
kubectl -n argocd get app                                          # todas Synced/Healthy
kubectl -n envoy-gateway-system get gateway principal              # PROGRAMMED=True, ADDRESS 10.99.90.223
curl -s -o /dev/null -w '%{http_code}\n' http://monitoring.10.99.90.223.nip.io/grafana/api/health   # 200
```

---

## 2. Cliente (`k0s-cliente`)

El cliente tiene su propio Argo CD, que lee `cliente/` de este repo. **Todo el tráfico va del cliente hacia fuera**:
GitHub para la configuración y el central para los datos.

### 2.1 Base

| # | Qué | Versión | Nota |
|---|---|---|---|
| 1 | Argo CD | 10.10.5 | `cliente/infra/argocd/values.yaml`. Repo registrado sin credenciales (GitHub público). Sin ruta: `kubectl port-forward` |
| 2 | `cliente/cliente-demo-k8s/raiz.yaml` | — | La aplicación de aplicaciones. Se aplica una vez, a mano. Incluye la app `secretos` (`monitoring-secrets` con `clusterName=cliente-demo` y `distro=k0s`, sin contraseñas) |

```bash
export KUBECONFIG=~/.kube/k0s-cliente.yaml
helm upgrade --install argocd argo/argo-cd --version 10.10.5 -n argocd --create-namespace -f cliente/infra/argocd/values.yaml
kubectl apply -f cliente/cliente-demo-k8s/raiz.yaml
```

### 2.2 Lo que despliega `herramientas-cliente`

| Application | Chart / versión | Para qué |
|---|---|---|
| `local-path-provisioner` | v0.0.37 (`values-almacenamiento.yaml`) | StorageClass para el buffer de Fluentd. El clúster no trae ninguna |
| `cert-manager` | v1.21.2 | Crea la **CA del cliente** y renueva su certificado |
| `reloader` | 2.2.18 | Reinicia Fluentd cuando cambia el certificado, porque Fluentd solo lo lee al arrancar |
| `ingesta-mtls` | `cliente/ingesta-mtls-cliente` 0.1.0 | CA de 5 años, certificado de cliente de 24 h (se renueva 8 h antes; en cliente-demo, 1 h para verlo) copiado a `monitoring` y `logging`, y la CA del servidor central (`servidorCA`) |
| `monitoring-crds` | `prometheus-operator-crds` 32.0.1 | CRDs del operador |
| `monitoring` | `kube-prometheus-stack` 92.10.1 | Prometheus con `remoteWrite` a `https://cliente-demo.ingest.10.99.90.223.nip.io/api/v1/push` con el certificado |
| `logging` | `logging-operator` 6.9.0 | Fluentd con output Loki a `https://cliente-demo.ingest.10.99.90.223.nip.io` con el certificado |

`herramientas-cliente` e `ingesta-mtls-cliente` se leen por ruta de este repo (`targetRevision: main`). Para fijar
una versión: un tag de Git y ese tag en el `targetRevision`.

### 2.3 Comprobaciones del cliente

```bash
export KUBECONFIG=~/.kube/k0s-cliente.yaml
kubectl -n argocd get app                                   # todas Synced/Healthy
kubectl -n cert-manager get certificate                     # ingesta-ca READY
kubectl -n monitoring get secret ingesta-mtls ingesta-ca-servidor
```

---

## 3. Unir los dos lados (orden obligatorio)

Hay un ida y vuelta de partes **públicas**. No viaja ninguna clave privada.

1. **Central arriba primero.** Con `ingesta.servidorTLS.crear: true` sin `issuerRef`, crea su CA de servidor de
   laboratorio.
2. **CA del servidor → cliente.** Se saca del central:
   ```bash
   kubectl --kubeconfig ~/.kube/k0s-central.yaml -n monitoring get secret ingesta-ca-servidor \
     -o jsonpath='{.data.ca\.crt}' | base64 -d
   ```
   Va en `servidorCA` de `cliente/herramientas-cliente/values-monitoring.yaml` (ahora vacío). Commit y push.
3. **Cliente arriba** (sección 2). Su cert-manager crea la CA del cliente. Prometheus y Fluentd reintentan, con
   rechazo TLS, hasta el alta.
4. **CA del cliente → central (alta).**
   ```bash
   kubectl --kubeconfig ~/.kube/k0s-cliente.yaml -n cert-manager get secret ingesta-ca \
     -o jsonpath='{.data.ca\.crt}' | base64 -d > ca-cliente-demo.crt
   central/herramientas-ingesta/alta-cliente.sh -f central/monitoring-laboratorio/values-laboratorio.yaml \
     cliente-demo ca-cliente-demo.crt 10.99.90.179/32
   ```
   Comprueba la huella que imprime. Después, commit y push de `values-laboratorio.yaml`; Argo CD lo aplica.
   `ca-cliente-demo.crt` no hace falta subirlo.
5. **Comprobar que llega**, desde el central, por port-forward a Prometheus:
   ```bash
   kubectl --kubeconfig ~/.kube/k0s-central.yaml -n monitoring port-forward svc/monitoring-prometheus-prometheus 9090
   # http://localhost:9090  →  sum by (router, code) (increase(traefik_router_requests_total{router=~"monitoring-ingesta-.*"}[5m]))
   ```
   Respuestas 200/204 para `cliente-demo`, y en Grafana su tenant con datos.

Con un certificado de servidor de una CA pública, el paso 2 no existe: el cliente confía en esa CA.
