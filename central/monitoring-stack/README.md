# monitoring-stack

Stack central de monitorización: Grafana, Mimir, Loki, kube-prometheus-stack y logging-operator, con entrada
mTLS por cliente.

## Estructura

**Umbrella chart de Helm** (2.x): cada componente es el chart oficial de su servicio, con versión exacta en
`Chart.yaml`. Las plantillas propias (`templates/`) solo cubren lo que esos charts no traen. El chart no lleva nada de
un entorno concreto: dominios, almacenamiento, Kafka, base de datos de Grafana, tenants y clientes van en un values
aparte de cada entorno, y `values.schema.json` comprueba que estén.

| Ruta | Qué es |
|---|---|
| `Chart.yaml` | Dependencias: logging-operator, loki, grafana y grafana-dev, mimir, kube-prometheus-stack, cortex-tenant |
| `values.yaml` | Release `monitoring` (valores comunes, sin entorno) |
| `values-logging.yaml` | Release `logging` (Loki) |
| `values-logging-operator.yaml` | Release del logging-operator |
| `values.schema.json` | Lo obligatorio de cada entorno según lo que se active |
| `templates/ingesta/` | Entrada mTLS de clientes ([doc/ingesta-mtls.md](./doc/ingesta-mtls.md)) |
| `doc/ingesta-mtls.md` | Cómo funciona la ingesta mTLS |

### Values de un entorno

```yaml
global:
  objectStorage: {s3Endpoint: ...}            # S3 de Mimir
  kafka: {bootstrap: ...}                     # Kafka EXTERNO (ingest storage de Mimir): este chart no lo instala
  hosts: {esquema: https, monitoring: ...}    # host de Grafana
  parameters: {clusterName: ..., grafanaClusters: "tenant-a|tenant-b"}
grafana:
  route: {main: {parentRefs: [{name: <gateway>, namespace: ...}]}}
  grafana.ini: {database: {host: ...}}
loki:                                         # values-logging
  loki: {storage: {s3: {endpoint: ...}}}
ingesta:
  dominio: ingest.<dominio>
  clientes: []                                # ver doc/ingesta-mtls.md
```

### Acceso

| Quién | Por dónde |
|---|---|
| Personas | Grafana: `https://<hosts.monitoring>/grafana` (login de Grafana) |
| Clientes externos | Ingesta mTLS: `https://<cliente>.<ingesta.dominio>` con su certificado, solo envío |
| Personal autorizado | `kubectl port-forward` a Prometheus, Alertmanager, Mimir o Loki (sin ruta pública; ver `NOTES.txt`) |

Cada Application de Argo CD usa el values del chart (`values.yaml` o `values-logging.yaml`) más el del entorno.
Las flags `global.monitoring.*` / `global.logging.*` activan cada pieza. `charts/` y `Chart.lock` no se versionan.
