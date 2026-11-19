# laboratorio-monitoring · rama `testing`

Rama del curso: el mismo stack que `main`, montado desde cero en `k0s-central` (10.99.90.58) y `k0s-cliente`
(10.99.90.218) y añadido pieza a pieza, una clase cada vez. **`main` es la solución**: cuando termina una clase,
se compara con ella:

```bash
git diff main testing -- central/infra/aplicaciones/
```

Los Argo CD de los dos clústeres leen esta rama (`targetRevision: testing`).

| Clase | Qué entra |
|---|---|
| 2 | `central/raiz.yaml` y local-path. Argo CD v3.6.1 se instala a mano (install.yaml estándar), fuera del repo |
| 3 | MetalLB 0.16.1 (pool = IP del nodo), Envoy Gateway 1.9.3 (con Gateway API v1.6.1), `red/`: EnvoyProxy, GatewayClass y Gateway `principal` :80. |
| 4 | `base` (namespaces y Secrets del laboratorio), CRDs del Prometheus Operator (las necesita el PodMonitor de grafana-db), cert-manager v1.21.2, CNPG 0.29.1 + `grafana-db`, SeaweedFS 4.48.0 y Kafka (Strimzi, topic `mimir-ingest`) |
| 5 | Chart umbrella `monitoring-stack` entero (igual que en main) y su Application `monitoring`; solo Mimir encendido (`values-curso.yaml`, exclusivo de la rama), sin clientes |
| 6 | `prometheus` (kube-prometheus-stack) y `tenant` (cortex-tenant) encendidos: el central se monitoriza y escribe en Mimir con el tenant `k0s-central`. Vuelve el PodMonitor de Envoy a `red/` |
| 7 | Application `logging` (mismo chart, release `logging`, `values-logging.yaml`): Loki simple scalable sobre S3. Los interruptores del curso pasan a `values-curso.yaml` para no pisar a logging |
| 8 | `grafana` encendido: Postgres `grafana-db`, HTTPRoute en `monitoring.10.99.90.58.nip.io/grafana`, datasources de Mimir y Loki por tenant (`grafanaClusters`) |
| 9 | PKI: External Secrets Operator 2.15.0 y un Vault de laboratorio (0.34.1, modo dev) con KV `ingesta/`, AppRole `central` (escribe) y uno por cliente (solo lee lo suyo); ClusterSecretStore `vault` en el central; Vault expuesto en `vault.10.99.90.58.nip.io` para los clientes |
| 10 | Ingesta mTLS en el central, **modelo B**: el central crea la CA y el certificado de cada cliente (90 días, renueva a 30) y los sube a Vault con un PushSecret; protección (VAP) sobre `ca-<cliente>`; alertas nuevas (CA falta, entrega falla, renovación falla). Fuera los modos `cas` y `caSecret`. Cliente de prueba `prueba` |
| 10b | Logs del propio central: Application `logging-operator` (Fluent Bit → Fluentd → loki-gateway, tenant `k0s-central`, todo en `logging`). Namespaces `external-secrets` y `vault` con `monitoring=true` para que Prometheus lea ESO |

Repo **público**: nada de credenciales reales, claves privadas ni kubeconfigs.
