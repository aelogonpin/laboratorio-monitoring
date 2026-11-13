# Ingesta mTLS de clientes externos

Los clústeres de cliente envían logs (Loki) y métricas (Mimir) al central con un **certificado de
cliente** en lugar de usuario y contraseña. Se activa con `global.monitoring.ingesta` (release `monitoring`).

## Cómo viaja una petición

```
Cliente (Prometheus / Fluentd)                         Central
 cert-manager del cliente: su CA y su certificado
 ── HTTPS + certificado ──►  Envoy :443  (Gateway ingesta, listener <cliente>, SNI <cliente>.ingest.<dominio>)
                              1. ClientTrafficPolicy ingesta-<cliente> ¿firmado por SU CA?     no -> corta en el TLS
                                 (sin SNI o con otro host: no hay listener -> corta en el TLS)
                              2. SecurityPolicy ingesta-<cliente>      ¿IP permitida? (opcional) no -> 403
                              3. BackendTrafficPolicy ingesta-limite-cuerpo                     > 50 MiB -> 413
                              4. HTTPRoute ingesta-<cliente>: solo rutas de envío               resto -> 404
                                 y fija X-Scope-OrgID = <cliente> (pisa el que mande el cliente)
                                    │
                                    ▼  HTTP interno (NetworkPolicy: solo entra Envoy)
                              loki-write / mimir-distributor
```

## Ficheros

| Fichero | Qué hace |
|---|---|
| `templates/ingesta/pki.yaml` | Certificados: CA y certificado de **servidor**, y en modo CA en el central, la CA y el certificado del cliente |
| `templates/ingesta/envoy.yaml` | Gateway de la ingesta y, por cliente, su CA pública, ClientTrafficPolicy, HTTPRoute y SecurityPolicy |
| `templates/ingesta/politica-red.yaml` | NetworkPolicy que cierra los namespaces `monitoring` y `logging` |
| `templates/ingesta/alertas.yaml` | Alertas: certificado por caducar, cliente sin datos |
| `templates/ingesta/_helpers.tpl` | Lee y valida los clientes de `ingesta.clientes` |
| `values.yaml` → `ingesta:` | Gateway, destinos, política de red y alertas (comunes a todos) |
| values del entorno → `ingesta.dominio` y `ingesta.clientes` | El dominio y **un elemento por cliente**: es lo único que se toca para dar de alta o de baja |

## Objetos que se crean

### Comunes (una vez)

| Objeto (CRD) | De quién es el CRD | Para qué |
|---|---|---|
| `Issuer ingesta-autofirmado` | cert-manager | Firma las CAs (la de servidor de laboratorio y las de clientes en modo central) |
| `Certificate ingesta-ca-servidor` + `Issuer ingesta-ca-servidor` | cert-manager | CA del certificado de servidor. Solo laboratorio: con un certificado de una CA pública, `ingesta.servidorTLS` |
| `Certificate ingesta-servidor` → Secret `ingesta-servidor-tls` | cert-manager | Certificado de servidor `*.ingest.<dominio>`: lo presenta Envoy |
| `Gateway ingesta` (si hay clientes) | Gateway API | Un listener HTTPS por cliente. Se fusiona con el Gateway de la plataforma (`mergeGateways`): mismo Envoy, misma IP |
| `BackendTrafficPolicy ingesta-limite-cuerpo` | Envoy Gateway | Tamaño máximo de cada envío (`requestBuffer`) |
| `ReferenceGrant ingesta-desde-monitoring` (en `logging`) | Gateway API | Deja a las HTTPRoute de `monitoring` enviar a `loki-write` |
| `NetworkPolicy ingesta-cerrar-monitoring` / `-logging` | Kubernetes | Mimir y Loki no autentican: solo entra Envoy (y lo listado en `ingesta.politicaRed`) |
| `PrometheusRule ingesta-mtls` | Prometheus Operator | Alertas de certificados y de cliente sin datos |
| `ServiceMonitor cert-manager` | Prometheus Operator | Métricas de caducidad de cert-manager (las usan las alertas) |

### Por cliente (salen solos de su elemento en `ingesta.clientes`)

| Objeto (CRD) | De quién es el CRD | Para qué |
|---|---|---|
| Listener `<cliente>` del `Gateway ingesta` | Gateway API | Host `<cliente>.ingest.<dominio>`, HTTPS 443, certificado de servidor |
| `Secret ingesta-ca-<cliente>` | Kubernetes | Parte **pública** de la CA del cliente (`cas:`). Varias van en el mismo `ca.crt` = cambio de CA sin corte |
| `ClientTrafficPolicy ingesta-<cliente>` | Envoy Gateway | En **su** listener solo acepta certificados de **su** CA (TLS ≥ 1.2) |
| `HTTPRoute ingesta-<cliente>` | Gateway API | Solo rutas de envío (`/loki/api/v1/push`, `/otlp/v1/logs`, `/api/v1/push`, `/otlp/v1/metrics`) y `X-Scope-OrgID` fijo |
| `SecurityPolicy ingesta-<cliente>` | Envoy Gateway | Solo si `ipPermitidas`: un certificado robado no sirve desde otra IP |
| `Certificate ca-<cliente>` + `Issuer` + `Certificate cliente-<cliente>` | cert-manager | Solo en modo **CA en el central** (sin `cas:`, clientes sin cert-manager): el central emite su certificado y hay que entregárselo |

Por qué un listener por cliente: la validación de cliente estándar de Gateway API va por puerto, no por host. Envoy
Gateway la permite por listener con `ClientTrafficPolicy` + `sectionName`.

## Un cliente

En el values del entorno:

```yaml
ingesta:
  clientes:
  - nombre: cliente-x                 # host, CN y tenant (= CLUSTER_NAME del cliente)
    ipPermitidas: [203.0.113.10/32] # opcional
    senales: [logs, metricas]       # opcional, por defecto las dos
    metricasPorCortexTenant: false  # opcional: varios clústeres por certificado -> tenant <cliente>-<cluster>
    cas:
    - |
      -----BEGIN CERTIFICATE-----   # ca.crt del cert-manager del cliente (público)
```

## Alta y baja

Con `central/herramientas-ingesta/` del repo del laboratorio, sobre el values del entorno:

```bash
herramientas/alta-cliente.sh -f values-entorno.yaml cliente-x ca.crt 203.0.113.10/32
#  comprueba que es una CA, que no ha caducado y que no es de otro cliente; imprime la huella
#  añade el cliente a ingesta.clientes y su tenant a global.parameters.grafanaClusters
#  -> comparar la huella con la del cliente POR OTRO CANAL, commit + push: Argo CD crea todo lo de arriba
herramientas/baja-cliente.sh -f values-entorno.yaml cliente-x
```

Lo que sigue siendo de personas: recibir el `ca.crt` del cliente y **comprobar su huella por otro canal** (es lo que
evita dar de alta a un impostor) y, si se usa, su IP de salida.

## Requisitos del central

- Envoy Gateway con una GatewayClass (`ingesta.gateway.className`) cuyo `EnvoyProxy` tenga `mergeGateways: true`.
- El Service de Envoy con `externalTrafficPolicy: Local` (IP real del cliente) y delante solo L4.
- Métricas del Envoy en Prometheus (PodMonitor): la alerta de cliente sin datos usa `envoy_cluster_upstream_rq_xx`.
- Un motor de NetworkPolicy en el clúster.
- `ingesta.servidorTLS`: en producción, el certificado del wildcard `*.ingest.<dominio>`.
