# Guía de montaje del laboratorio (monitoring-stack 3.0.0)

Tres clústeres k0s de un nodo, recién instalados y vacíos: el central y dos clientes. Esta guía dice **qué va en
cada lado, en qué orden y por qué**. Los tres Argo CD leen este repo público de GitHub
(`github.com/aelogonpin/laboratorio-monitoring`, rama `main`), sin credenciales: no hay Gitea ni registro de charts.

| Nodo | IP | CPU / RAM / disco | kubeconfig | Papel |
|---|---|---|---|---|
| `k0s-central` | 10.99.90.58 | 8 / 20 GB / 120 GB | `~/.kube/k0s-central.yaml` | Monitorización central y el Vault del laboratorio |
| `k0s-cliente` | 10.99.90.218 | 3 / 6 GB / 40 GB | `~/.kube/k0s-cliente.yaml` | Cliente `cliente-demo` |
| `k0s-cliente-b` | 10.99.90.254 | 3 / 6 GB / 40 GB | `~/.kube/k0s-cliente-b.yaml` | Cliente `cliente-b` |

## 0. Las VMs y k0s (los tres igual)

**Límites del sistema.** Sin subir inotify, Fluent Bit muere con *Too many open files* al vigilar los logs.
`central/infra/cloud-init.yaml` lo deja hecho al crear la VM (`multipass launch ... --cloud-init central/infra/cloud-init.yaml`);
en una VM ya creada:

```bash
printf 'fs.inotify.max_user_instances = 1024\nfs.inotify.max_user_watches = 1048576\n' | sudo tee /etc/sysctl.d/90-inotify.conf
sudo sysctl --system
```

**k0s v1.36.4+k0s.1** (`k0s install controller --single -c /etc/k0s/k0s.yaml`) con la configuración de
`k0s config create` salvo **`spec.network.serviceCIDR: 10.112.0.0/16`**: el de por defecto (`10.96.0.0/12`) contiene
la red de multipass (`10.99.90.0/24`) y k0s no aprueba entonces el certificado de servidor del kubelet (sin
`kubectl logs` ni metrics-server). Lo demás por defecto: CNI kube-router (aplica NetworkPolicy), CoreDNS y
metrics-server. **No traen StorageClass, ni Ingress, ni nada más.**

**Argo CD** estándar (v3.6.1), fuera del repo, con un único ajuste: un **timeout de sync de 15 min**. Por defecto es
0 (nunca), y una operación que espera a un recurso que no llega a estar sano se queda colgada para siempre sin que
entre el `retry`. Pasa en el primer arranque de un cliente: el certificado del webhook de kube-prometheus-stack falla
porque el webhook de cert-manager aún no está listo, y la operación espera para siempre al operador, que lo necesita.

```bash
kubectl create ns argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
kubectl -n argocd patch cm argocd-cmd-params-cm --type merge -p '{"data":{"controller.sync.timeout.seconds":"900"}}'
kubectl -n argocd rollout restart statefulset argocd-application-controller
```

Sin salud de Application (estándar): las olas (`sync-wave`) ordenan, pero no esperan a que la anterior esté sana. Lo
que arranca antes de tiempo falla y reintenta (`retry`) hasta que se coloca: en el primer arranque hay errores
durante unos minutos.

## Panorama

```
 k0s-cliente / k0s-cliente-b                                k0s-central
 ┌───────────────────────────────────┐                      ┌──────────────────────────────────────────────┐
 │ ESO ── ExternalSecret ◀───────────┼── Vault (lab, en ───▶│ cert-manager: CA y certificado de cada cliente│
 │   └─ Secret ingesta-mtls          │   el central) ◀──────┼── ESO PushSecret                             │
 │ Prometheus ── remote_write ───────┼─ HTTPS + mTLS :443 ─▶│ Envoy GW :443 Gateway ingesta, un listener    │
 │ Fluentd    ── output loki ────────┼─────────────────────▶│  por cliente: <cliente>.ingest.<dominio>      │
 │ Reloader (reinicia Fluentd)       │   solo de cliente    │   ├ ClientTrafficPolicy: solo SU CA           │
 │                                   │   a central          │   ├ solo rutas de envío; tenant lo pone él    │
 └──────────────┬────────────────────┘                      │   └ → mimir-distributor / loki-write          │
        ▲       │ git (lectura)                             │ :80 HTTPRoute → Grafana (login)               │
        │       ▼                                           │ Mimir ── Kafka   Loki   S3 (SeaweedFS)        │
        │   GitHub (repo público) ◀──── git (lectura) ──────│ PostgreSQL (CNPG)   NetworkPolicy cerrada     │
        │                                                   │ Argo CD                                       │
   el central NUNCA entra en el cliente                     └──────────────────────────────────────────────┘
```

Entradas públicas del central: **dos**, Grafana (personas) y la ingesta (clientes); en el laboratorio, además, Vault
(`vault.10.99.90.58.nip.io`), que hace el papel del Vault corporativo al que llegan los clientes. Prometheus,
Alertmanager, Mimir y Loki no tienen ruta: se entra con `kubectl port-forward` (los comandos salen en las NOTES del
chart).

**El repo es público**: nada de contraseñas de verdad, tokens ni claves privadas. Los Secrets del laboratorio van en
claro (valores aleatorios), también los del Vault de pruebas. Los certificados de los clientes no están en Git: los
crea el central y viajan por Vault.

## Estructura del repo

| Ruta | Dónde se usa |
|---|---|
| `central/raiz.yaml` + `central/infra/` | Aplicación raíz del central y su base como Applications de Argo CD |
| `central/monitoring-stack/` | Chart 3.0.0. Applications `monitoring`, `logging` y `logging-operator` |
| `central/monitoring-laboratorio/` | `values-laboratorio.yaml`, chart `kafka/` y las Applications (`argocd/`) |
| `central/GUIA-CLIENTES-INGESTA.md` | Alta, renovación, cambio de CA y baja de clientes, paso a paso |
| `cliente/cliente-demo-k8s/`, `cliente/cliente-b-k8s/` | `raiz.yaml` y las Applications de cada cliente |
| `cliente/herramientas-cliente/` | Chart que genera las Applications de las herramientas del cliente y trae su certificado de Vault |

---

## 1. Central (`k0s-central`)

Todo el central lo despliega su Argo CD desde este repo. A mano solo va la raíz:

```bash
export KUBECONFIG=~/.kube/k0s-central.yaml
kubectl apply -f central/raiz.yaml
```

### 1.1 Lo que crea `raiz.yaml`, por olas

| Ola | Application | Qué | Versión | Configuración |
|---|---|---|---|---|
| -5 | `base` | Namespaces con `monitoring=true` (monitoring, logging, seaweedfs, postgres, cert-manager, envoy-gateway-system, external-secrets, vault) y los Secrets | — | `central/infra/base/` |
| -5 | `local-path-provisioner` | StorageClass `local-path` por defecto | v0.0.37 | En la Application |
| -5 | `prometheus-operator-crds` | CRDs del Prometheus Operator (el chart lleva `prometheus.crds.enabled: false`) | 32.0.1 | — |
| -4 | `metallb` | Balanceador: da IP al Service de Envoy | 0.16.1 | Pool en `central/infra/red/` |
| -4 | `envoy-gateway` | Controlador de Gateway API. **Trae sus CRDs y los de Gateway API v1.6.1 (experimental)** | 1.9.3 | Por defecto |
| -4 | `cert-manager` | PKI de la ingesta y certificado del webhook de kube-prometheus-stack | v1.21.2 | `central/infra/cert-manager/values.yaml` |
| -4 | `cnpg` | Operador CloudNativePG (trae sus CRDs) | 0.29.1 | `central/infra/cnpg/values.yaml` |
| -4 | `external-secrets` | External Secrets Operator: sube a Vault los certificados de los clientes (PushSecret) | 2.15.0 | `central/infra/external-secrets/values.yaml` |
| -3 | `seaweedfs` | S3 de Mimir y Loki | 4.48.0 | `central/infra/seaweedfs/values.yaml` |
| -3 | `red` | Pool de MetalLB, `EnvoyProxy`, `GatewayClass envoy`, `Gateway principal` y el PodMonitor de Envoy | — | `central/infra/red/` |
| -3 | `grafana-db` | Clúster PostgreSQL de Grafana (`grafana-db-rw.postgres.svc:5432`) | PostgreSQL 18.6 | `central/infra/postgres/` |
| -3 | `vault` | **Solo laboratorio**: Vault en modo dev (en memoria), en el papel del Vault corporativo | 0.34.1 (Vault 2.0.4) | `central/infra/vault/values.yaml` |
| -2 | `vault-config` | KV `ingesta/`, AppRoles y políticas (CronJob idempotente cada 2 min), ClusterSecretStore `vault` y la ruta de Vault | — | `central/infra/vault-config/` |
| 0 | `kafka` | Strimzi 1.3.0 + Kafka + topic `mimir-ingest` | — | `central/monitoring-laboratorio/kafka/` |
| 1 | `monitoring` | Grafana, Mimir, kube-prometheus-stack, cortex-tenant y la ingesta mTLS | chart 3.0.0 | `values.yaml` + `values-laboratorio.yaml` |
| 1 | `logging` | Loki | chart 3.0.0 | `values-logging.yaml` + `values-laboratorio.yaml` |
| 2 | `logging-operator` | Logs del propio central: Fluent Bit → Fluentd → loki-gateway, tenant `k0s-central` | chart 3.0.0 | `values-logging-operator.yaml` + `values-laboratorio.yaml` |

El propio central se monitoriza **por dentro**, sin mTLS: su Prometheus escribe en `mimir-gateway` con
`X-Scope-OrgID: k0s-central` fijo, y su Fluentd en `loki-gateway` con el mismo tenant.

### 1.2 Entrada: MetalLB + Envoy Gateway

- k0s no trae balanceador. **MetalLB** tiene como pool **la propia IP del nodo** (`10.99.90.58/32`). Así los
  dominios `*.10.99.90.58.nip.io` no cambian, y kube-proxy (iptables) lleva el 80/443 de esa IP a Envoy.
- `EnvoyProxy principal`: Service `LoadBalancer` con **`externalTrafficPolicy: Local`**. Conserva la IP real del
  cliente, que es la que comprueba `ipPermitidas`.
- `Gateway principal` (namespace `envoy-gateway-system`), listener `http` en el 80 para todas las rutas (Grafana y,
  solo en el laboratorio, Vault). Argo CD no tiene ruta: `kubectl -n argocd port-forward svc/argocd-server 8080:443`.
- **Ingesta mTLS**: el chart crea su propio `Gateway ingesta` (namespace `monitoring`) con un listener HTTPS 443 por
  cliente. `mergeGateways: true` en el `EnvoyProxy` lo fusiona con `principal`: mismo Envoy, misma IP. Por cliente:
  `ClientTrafficPolicy` con su CA, `HTTPRoute` con `X-Scope-OrgID` fijo y `SecurityPolicy` con sus IPs
  (detalle en `central/monitoring-stack/doc/ingesta-mtls.md`).

### 1.3 Secrets

En claro (valores aleatorios que solo valen en este laboratorio). **Credenciales de verdad (tokens de GitHub, nube,
producción) nunca van al repo.**

| Namespace / Secret | Claves | Lo usa |
|---|---|---|
| `monitoring/monitoring-secrets` | `s3AccessKey`, `s3SecretKey`, `lokiUser`, `lokiPass`, `admin-user`, `grafana-admin-password`, `clusterName` (`k0s-central`), `distro`, `grafana-db-pass` | Grafana, Mimir, Prometheus |
| `logging/monitoring-secrets` | `s3AccessKey`, `s3SecretKey`, `.htpasswd`, `clusterName`, `lokiUser`, `lokiPass` | Loki (S3 y basic auth de su gateway) y el logging-operator del central |
| `postgres/grafana-db-credentials` | `username`, `password` (tipo basic-auth) | CNPG, al crear la base de datos |
| `seaweedfs/seaweedfs-s3-config` | `seaweedfs_s3_config` | SeaweedFS |
| `vault/vault-laboratorio` | token raíz del Vault de pruebas y `role_id` / `secret_id` fijos de los AppRoles | CronJob `vault-config` (`central/infra/vault-config/secretos.yaml`) |
| `external-secrets/vault-approle-central` | `secret-id` del AppRole `central` | ClusterSecretStore `vault` |

### 1.4 Comprobaciones del central

```bash
export KUBECONFIG=~/.kube/k0s-central.yaml
kubectl -n argocd get app                                          # todas Synced/Healthy
kubectl -n envoy-gateway-system get gateway principal              # PROGRAMMED=True, ADDRESS 10.99.90.58
kubectl get clustersecretstore vault                               # Valid, Ready
curl -s -o /dev/null -w '%{http_code}\n' http://monitoring.10.99.90.58.nip.io/grafana/api/health   # 200
```

---

## 2. Cada cliente (`k0s-cliente`, `k0s-cliente-b`)

Cada cliente tiene su propio Argo CD, que lee su carpeta de este repo. **Todo el tráfico va del cliente hacia
fuera**: GitHub para la configuración, Vault para su certificado y el central para los datos.

```bash
export KUBECONFIG=~/.kube/k0s-cliente.yaml          # o k0s-cliente-b.yaml
kubectl apply -f cliente/cliente-demo-k8s/raiz.yaml # o cliente/cliente-b-k8s/raiz.yaml
```

La raíz incluye la app `secretos`: `monitoring-secrets` (`clusterName`, `distro`, sin contraseñas) y
`external-secrets/vault-approle` (el `secret_id` de su AppRole en el Vault del laboratorio).

### 2.1 Lo que despliega `herramientas-cliente`

| Application | Chart / versión | Para qué |
|---|---|---|
| `local-path-provisioner` | v0.0.37 (`values-almacenamiento.yaml`) | StorageClass para el buffer de Fluentd. El clúster no trae ninguna |
| `cert-manager` | v1.21.2 | Certificado del webhook de kube-prometheus-stack (la ingesta ya no lo usa) |
| `external-secrets` | 2.15.0 | Trae de Vault el certificado de la ingesta |
| `reloader` | 2.2.18 | Reinicia Fluentd cuando cambia el certificado, porque Fluentd solo lo lee al arrancar |
| (sin Application) | `ingesta:` de `herramientas-cliente` | ClusterSecretStore `ingesta-vault` con el AppRole del cliente y, en `monitoring` y `logging`, los ExternalSecret `ingesta-mtls` (`clientes/<cliente>`) e `ingesta-ca-servidor` (`servidor`) |
| `monitoring-crds` | `prometheus-operator-crds` 32.0.1 | CRDs del operador |
| `monitoring` | `kube-prometheus-stack` 92.10.1 | Prometheus con `remoteWrite` a `https://<cliente>.ingest.10.99.90.58.nip.io/api/v1/push` con el certificado |
| `logging` | `logging-operator` 6.9.0 | Fluentd con output Loki a `https://<cliente>.ingest.10.99.90.58.nip.io` con el certificado |

`herramientas-cliente` se lee por ruta de este repo (`targetRevision: main`). Para fijar una versión: un tag de Git
y ese tag en el `targetRevision`.

### 2.2 Comprobaciones del cliente

```bash
kubectl -n argocd get app                                   # todas Synced/Healthy (tras el alta)
kubectl get clustersecretstore ingesta-vault                # Valid, Ready
kubectl get externalsecret -A                               # SecretSynced (ingesta-mtls, tras el alta)
```

Antes del alta en el central, `ingesta-mtls` da error (no hay nada en Vault) y Prometheus y Fluentd esperan al Secret.

---

## 3. Unir los dos lados

Con Vault no hay nada que copiar a mano:

1. **Central arriba primero** (sección 1), con el Vault del laboratorio.
2. **Cliente arriba** (sección 2): su ClusterSecretStore entra en Vault y trae ya la CA de servidor; su certificado,
   todavía no.
3. **Alta en el central**: `central/GUIA-CLIENTES-INGESTA.md`, sección 1. En el laboratorio, su AppRole en
   `vault-config` y su entrada en `ingesta.clientes` de `values-laboratorio.yaml` (y en `grafanaClusters`); commit y
   push. El central crea su CA y su certificado y los sube a Vault; el cliente los trae en segundos.
4. **La primera vez, si Fluentd no aparece**: el logging-operator del cliente deja de reintentar cuando su Output
   falla por un Secret que aún no existía. `kubectl -n logging rollout restart deploy/operator`, una vez.
5. **Comprobar que llega**, desde el central, por port-forward a Prometheus:
   ```bash
   kubectl --kubeconfig ~/.kube/k0s-central.yaml -n monitoring port-forward svc/monitoring-prometheus-prometheus 9090
   # http://localhost:9090  →  sum by (envoy_cluster_name, envoy_response_code_class) (increase(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/monitoring/ingesta-.*"}[5m]))
   ```
   Respuestas 2xx para cada cliente, y en Grafana su tenant con datos.

Con un certificado de servidor de una CA pública (`ingesta.servidorTLS.issuerRef`), la CA de servidor ni se sube a
Vault ni la necesita el cliente (`ingesta.vault.claveServidor: ""`).
