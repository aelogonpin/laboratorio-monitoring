# Guía de montaje del laboratorio (monitoring-stack 2.0.0)

Dos clústeres k0s de un nodo, recién instalados y vacíos. Esta guía dice **qué va en cada lado, en qué orden y por
qué**. Los dos Argo CD leen este repo público de GitHub (`github.com/aelogonpin/laboratorio-monitoring`, rama
`main`), sin credenciales: no hay Gitea ni registro de charts.

| Nodo | IP | CPU / RAM / disco | kubeconfig | Papel |
|---|---|---|---|---|
| `k0s-central` | 10.99.90.223 | 8 / 24 GB / 350 GB | `~/.kube/k0s-central.yaml` | Monitorización central |
| `k0s-cliente` | 10.99.90.179 | 3 / 8 GB / 90 GB | `~/.kube/k0s-cliente.yaml` | Un cliente (`cliente-demo`) que envía logs y métricas |

Las dos tienen k0s v1.36.4+k0s.1 con su configuración por defecto: CNI kube-router (aplica NetworkPolicy), CoreDNS
y metrics-server. **No traen StorageClass, ni Ingress, ni nada más.**

## Panorama

```
 k0s-cliente (cliente-demo)                                  k0s-central
 ┌───────────────────────────────────┐                       ┌──────────────────────────────────────────────┐
 │ cert-manager ── CA del cliente    │                       │ Traefik  :80  Gateway API → Grafana (login)   │
 │   └─ certificado 24 h (se renueva)│   HTTPS + mTLS :443   │          :443 IngressRoute → ingesta mTLS     │
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
| `central/infra/` | Base del central, a mano con Helm (Traefik, cert-manager, SeaweedFS, Postgres, Argo CD) y scripts |
| `central/monitoring-stack/` | Chart 2.0.0. Applications `monitoring` y `logging` |
| `central/monitoring-laboratorio/` | `values-laboratorio.yaml`, chart `kafka/` y las Applications (`argocd/`) |
| `central/herramientas-ingesta/` | `alta-cliente.sh` / `baja-cliente.sh` (en tu equipo, editan `values-laboratorio.yaml`) |
| `cliente/cliente-demo-k8s/` | `raiz.yaml` y las Applications del cliente |
| `cliente/herramientas-cliente/` | Chart que genera las Applications de las herramientas del cliente |
| `cliente/ingesta-mtls-cliente/` | Chart de la CA y el certificado del cliente |

---

## 1. Central (`k0s-central`)

### 1.1 Base del clúster (fuera de Argo CD)

Instálalo en este orden: cada paso necesita el anterior.

| # | Qué | Versión | Configuración | Para qué |
|---|---|---|---|---|
| 1 | StorageClass `local-path` (local-path-provisioner), **por defecto** | v0.0.37 | — | PVC de Mimir, Loki, Prometheus, Kafka, Postgres, SeaweedFS. Los values del laboratorio piden `local-path` |
| 2 | Namespaces con la etiqueta `monitoring=true` | — | `monitoring`, `logging`, `seaweedfs`, `postgres`, `traefik`, `cert-manager` | Prometheus solo recoge ServiceMonitor y reglas de namespaces con esa etiqueta |
| 3 | CRDs de Gateway API (canal experimental) y de Traefik | Gateway API v1.6.3 | `central/infra/traefik/crds/` (`install.sh` los aplica server-side) | Fuera de Helm, porque Helm no actualiza CRDs |
| 4 | CRDs del Prometheus Operator (`prometheus-operator-crds`) | 32.0.1 | — | El chart lleva `prometheus.crds.enabled: false`. Tienen que estar **antes** que Traefik y cert-manager, porque crean ServiceMonitor |
| 5 | Traefik (`traefik/traefik`) | 42.1.1 (v3.7.16) | `central/infra/traefik/values.yaml` | Ver 1.2 |
| 6 | cert-manager (`jetstack/cert-manager`) | v1.21.2 | `central/infra/cert-manager/values.yaml` | PKI de la ingesta y certificado del webhook de kube-prometheus-stack |
| 7 | SeaweedFS (S3) | 4.48.0 | `central/infra/seaweedfs/values.yaml` (antes, el Secret `seaweedfs-s3-config`) | Buckets de Mimir y Loki |
| 8 | CloudNativePG + clúster `grafana-db` | 0.29.1 | `central/infra/postgres/operator-values.yaml` y `grafana-db.yaml` (antes, el Secret `grafana-db-credentials`) | Base de datos de Grafana: `grafana-db-rw.postgres.svc:5432` |
| 9 | Argo CD | 10.10.5 (v3.5.5) | `central/infra/argocd/values.yaml` | Repo registrado sin credenciales (GitHub público). Ruta desactivada hasta que exista el Gateway: `kubectl port-forward` |

Scripts (usan `~/.kube/k0s-central.yaml` salvo que exportes otro `KUBECONFIG`, y el `helm` del PATH):
- `central/infra/traefik/install.sh`: pasos 3 y 5;
- `central/infra/monitoring/secrets.sh`: los Secrets de 1.3;
- `central/infra/monitoring/prereqs.sh`: pasos 2, 4, 6, 7 y 8;
- `central/infra/monitoring/gitops.sh`: paso 9 y las Applications de 1.4, en orden.

### 1.2 Traefik: lo que tiene que tener sí o sí

- **Tres proveedores**:
  - `kubernetesCRD`, para la ingesta (IngressRoute, TLSOption y Middleware);
  - `kubernetesGateway`, para la ruta de Grafana;
  - `kubernetesIngress`, que es opcional.
- **`GatewayClass` `traefik` y `Gateway` `traefik-gateway`** en el namespace `traefik`, con un listener `web` HTTP y
  `namespacePolicy: All`. Lo crea el propio chart de Traefik (`gateway:` en sus values). **El chart de monitorización
  no crea el Gateway: solo se cuelga de él.**
- **Entrypoint `websecure` en el 443**. Por ahí entra la ingesta, y es su `ingesta.entryPoints`.
- **IP de origen real.** En el laboratorio se consigue con `hostPort` 80/443 y Service ClusterIP; detrás de un
  LoadBalancer, con `externalTrafficPolicy: Local`. Sin eso, `ipPermitidas` de los clientes no sirve.
- **Métricas con `addRoutersLabels: true` y su ServiceMonitor.** La alerta `IngestaClienteSinDatos` se calcula con
  `traefik_router_requests_total`.

### 1.3 Secrets (fuera de Git)

`central/infra/monitoring/secrets.sh` los crea. La primera vez genera credenciales nuevas en
`central/infra/monitoring/.secrets.env` (chmod 600, en `.gitignore`).

| Namespace / Secret | Claves | Lo usa |
|---|---|---|
| `monitoring/monitoring-secrets` | `s3AccessKey`, `s3SecretKey`, `lokiUser`, `lokiPass`, `admin-user`, `grafana-admin-password`, `clusterName` (`k0s-central`), `distro`, `grafana-db-pass` | Grafana, Mimir, Prometheus |
| `logging/monitoring-secrets` | `s3AccessKey`, `s3SecretKey`, `.htpasswd` | Loki (S3 y basic auth de su gateway, que usa Grafana) |
| `postgres/grafana-db-credentials` | `username`, `password` (tipo basic-auth) | CNPG, al crear la base de datos |
| `seaweedfs/seaweedfs-s3-config` | `seaweedfs_s3_config` | SeaweedFS |

### 1.4 Applications de Argo CD (en este orden)

| # | Application | Origen (este repo) | Qué despliega |
|---|---|---|---|
| 1 | `kafka` | `central/monitoring-laboratorio/kafka` | Operador Strimzi 1.3.0 + Kafka `kafka` + topic `mimir-ingest`. Mimir no arranca sin él |
| 2 | `monitoring` | `central/monitoring-stack` (`values.yaml` + `../monitoring-laboratorio/values-laboratorio.yaml`) | Grafana, Mimir, kube-prometheus-stack, cortex-tenant y la ingesta mTLS |
| 3 | `logging` | `central/monitoring-stack` (`values-logging.yaml` + el mismo values del laboratorio) | Loki |

Están en `central/monitoring-laboratorio/argocd/` y las crea la aplicación raíz `central/raiz.yaml`
(`kubectl apply -f central/raiz.yaml`, una vez). Mimir reintenta hasta que el Kafka está Ready. Alternativa:
`gitops.sh` aplica `kafka`, espera a que esté Ready y aplica las otras dos.

### 1.5 Comprobaciones del central

```bash
export KUBECONFIG=~/.kube/k0s-central.yaml
kubectl get gateway -n traefik                       # traefik-gateway PROGRAMMED=True
kubectl -n argocd get app                            # kafka, monitoring, logging: Synced/Healthy
curl -s -o /dev/null -w '%{http_code}\n' http://monitoring.10.99.90.223.nip.io/grafana/api/health   # 200
kubectl -n monitoring get certificate ingesta-servidor   # READY=True
kubectl -n monitoring get networkpolicy               # ingesta-cerrar-monitoring
```

---

## 2. Cliente (`k0s-cliente`)

El cliente tiene su propio Argo CD, que lee `cliente/` de este repo. **Todo el tráfico va del cliente hacia fuera**:
GitHub para la configuración y el central para los datos.

### 2.1 Base

| # | Qué | Versión | Nota |
|---|---|---|---|
| 1 | Argo CD | 10.10.5 | `cliente/infra/argocd/values.yaml`. Repo registrado sin credenciales (GitHub público). Sin ruta: `kubectl port-forward` |
| 2 | Secret `monitoring/monitoring-secrets` | — | Solo `clusterName=cliente-demo` y `distro=k0s`. **Sin contraseñas de Loki ni Mimir** |
| 3 | `cliente/cliente-demo-k8s/raiz.yaml` | — | La aplicación de aplicaciones. Se aplica una vez, a mano |

```bash
export KUBECONFIG=~/.kube/k0s-cliente.yaml
kubectl create ns monitoring
kubectl -n monitoring create secret generic monitoring-secrets --from-literal=clusterName=cliente-demo --from-literal=distro=k0s
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
