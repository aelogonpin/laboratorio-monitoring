# Changelog

This file documents all notable changes to the monitoring-stack Helm Chart. The release numbering uses [semantic versioning](http://semver.org).

## 2.0.0 Breaking Change

- [Ingesta] **De Traefik a Envoy Gateway + Gateway API**: fuera `templates/ingesta/traefik.yaml` (IngressRoute,
  TLSOption, Middlewares) y `ingesta.entryPoints`. Nuevo `templates/ingesta/envoy.yaml`: `Gateway ingesta` con un
  listener por cliente, `ClientTrafficPolicy` con su CA, `HTTPRoute` con `X-Scope-OrgID` fijo, `SecurityPolicy` por IP,
  `BackendTrafficPolicy` de tamaño (`limiteCuerpo: 50Mi`) y `ReferenceGrant` hacia `logging`. La CA pública de cada
  cliente pasa a un único Secret `ingesta-ca-<cliente>`. `ingesta.politicaRed.traefikNamespace` →
  `gatewayNamespace`. La alerta `IngestaClienteSinDatos` usa `envoy_cluster_upstream_rq_xx`.
- [Chart] Sin nada de un entorno concreto: dominios (`global.hosts`), S3 (`global.objectStorage.s3Endpoint`), Kafka
  (`global.kafka.bootstrap`), gateway, base de datos de Grafana, tenants y clientes van
  en el values de cada entorno. `values.schema.json` comprueba lo obligatorio según lo que se active. `NOTES.txt`.
- [Kafka] Fuera Strimzi y `templates/kafka/`: Mimir (ingest storage) usa un Kafka EXTERNO (`global.kafka.bootstrap`).
- [Ingesta] Los clientes van en `ingesta.clientes` del values del entorno (fuera `files/ingesta/`); se validan nombre e IPs.
  `ingesta.servidorTLS.crear` pasa a `false` por defecto. Herramientas de alta y baja en el repo `ingesta-mtls`.
- [Prometheus] Por defecto solo escribe en su tenant (`global.parameters.clusterName`); las copias a tenants de prueba
  pasan al values del laboratorio.
- [Acceso] Solo dos entradas públicas: Grafana (su `route.main`, con login) y la ingesta mTLS de los clientes.
  Prometheus, Alertmanager, Mimir y Loki quedan sin ruta: el personal autorizado entra con `kubectl port-forward`
  (RBAC del clúster; ver `NOTES.txt`). Fuera `templates/gateway/`, el bloque `gatewayApi`, los Middlewares `mon-*` / `log-*`,
  `global.gateway`, `global.redesPermitidas`, `global.hosts.alertmanager` / `loki` y el `externalUrl` / `routePrefix`
  `/prometheus/` de Prometheus (vuelve a `/`).
- [cert-manager] Fuera `templates/cert-manager/` y `certManager.issuers`: nadie los usaba (los Ingress del original iban
  con el ClusterIssuer de la plataforma). El certificado del Gateway se gestiona con el Gateway, fuera de este chart.
- [grafana-mcp] Fuera del chart: dependencia, values, ruta y Middlewares `mcp-*`, `global.hosts.mcp`.
- Migración: crear el values del entorno con lo de arriba y desplegar Kafka aparte antes de subir a 2.0.0.

## 1.6.0

- [Tempo] Fuera del chart (no se incluye Kafka para trazas): dependencia `tempo-distributed`, bloque `tempo:`, `global.monitoring.tempo`,
  bucket S3, ruta `/tempo`, topic `tempo-traces`, datasource y las rutas de trazas de la ingesta (solo logs y métricas).
- [Ingesta] `values-logging-operator.yaml` apaga `global.monitoring.ingesta`: la release del logging-operator renderizaba otra
  copia de la ingesta (TLSOption, IngressRoute, Certificates…) al heredar el `true` de `values.yaml`.

## 1.5.0

- [Kafka] El Kafka central (Strimzi) va con Mimir: la dependencia `strimzi` y `templates/kafka/` cuelgan de `global.monitoring.mimir`.
  Fuera `global.monitoring.kafka` y `kafkaCluster.enabled`. Tempo sin Mimir falla en el render (Tempo 3 necesita ese Kafka).
- [Ingesta] `alta-cliente.sh` también añade el tenant a `grafanaClusters`; nuevo `baja-cliente.sh`. README con todos los objetos y CRDs.

## 1.4.0

- [Reglas] Sin reglas en el chart: fuera `templates/prometheus-rules` y `files/prometheus-rules` (incluida `backup/`), `templates/loki-rules` y
  `files/loki-rules`, `templates/alerts` (alertas y recording rules de Grafana) y el flag `global.logging.lokirules`.
  El ruler de Mimir deja de montar el ConfigMap de reglas propio; el de Loki monta un `emptyDir` en su directorio local (sin reglas).
  Quedan las reglas que traen los subcharts (`defaultRules` de kube-prometheus-stack) y las alertas propias de la ingesta mTLS.

## 1.3.0

- [Grafana] Sin paneles en el chart: fuera `Grafana/dashboards/` (JSON), `templates/dashboards/` (ConfigMaps) y en `grafana:` los
  `dashboardProviders`, `customerDashboardTenants`, `dashboards` (descargas por URL) y los `extraVolumes`/`extraVolumeMounts`
  que montaban esos ConfigMaps. Los dashboards de los subcharts (Mimir, kube-prometheus-stack) siguen por el sidecar.

## 1.2.0

- [Repo] Limpieza: el repo queda solo con el chart (Chart.yaml, values, templates/, files/, Grafana/) y doc/. Fuera los
  restos de la migración a Helm 4 (`migration/`, `apply-plan/`, `AGENTS.md`, `PENDIENTES.md`), `templates_cronjobs_no/`,
  los dashboards `Sistemas/` y las reglas `prometheus-rules/backup/` (ninguna plantilla los leía).
- [Datos de prueba] Fuera `testData.logGenerator` (`templates/sample-data`, `files/sample-data`) y su permiso en la NetworkPolicy.
- [Ingesta] Los clientes pasan a `files/ingesta/clientes/` (con `alta-cliente.sh` y el README), como el resto de datos del chart.

## 1.1.0

- [Ingesta] Entrada mTLS por cliente para clústeres externos (`templates/ingesta/`, `global.monitoring.ingesta`, valores `ingesta:`):
  host por cliente con su TLSOption (solo su CA), `X-Scope-OrgID` fijado por el servidor, solo rutas push, `ipPermitidas` opcional y alertas (caducidad, cliente sin datos).
  Un fichero por cliente en `files/ingesta/clientes/` (`files/ingesta/alta-cliente.sh`). Ver `files/ingesta/README.md`.
- [Ingesta] NetworkPolicy por namespace (`ingesta.politicaRed`, modo `namespace`) en `monitoring` y `logging`: Mimir/Loki/Tempo no autentican; cierra también los gateways y Kafka.
- [cortex-tenant] Dependencia activada (alias `tenant`, 0.8.1, `global.monitoring.tenant`) para clientes con varios clústeres por certificado (`metricasPorCortexTenant`): tenant `<cliente>-<cluster>`.
- Requiere Traefik con `allowCrossNamespace` y motor de NetworkPolicy.
- [Tempo] Desactivado por ahora (`global.monitoring.tempo: false`); el código se queda. Con él se apagan el datasource Tempo de Grafana (comentado), el KafkaTopic `tempo-traces` (nuevo `when` por topic) y las rutas de trazas de la ingesta.

## 0.0.1

- Primera versión:
  - prometheus
  - alertmanager
  - grafana
  - loki-distributed
  - mimir-distributed


### TODO

Keep building the changelog using *git log charts* checking the tag
