# Ingesta mTLS de clientes externos

Los clústeres de cliente envían logs (Loki) y métricas (Mimir) al central con un **certificado de
cliente** en lugar de usuario y contraseña. Se activa con `global.monitoring.ingesta` (release `monitoring`).

**El central es el dueño de los certificados**: crea la CA de cada cliente y su certificado, los renueva y, con
`ingesta.entrega.pushSecret`, los sube a Vault con External Secrets; cada cliente los baja con su ExternalSecret.

## Cómo viaja una petición

```
Cliente (Prometheus / Fluentd)                         Central
 su certificado: lo crea el central, lo trae de Vault
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
| `templates/ingesta/pki.yaml` | Certificados: CA y certificado de **servidor**, y por cliente su CA y su certificado de cliente |
| `templates/ingesta/entrega.yaml` | PushSecret por cliente (certificado y clave a Vault) y de la CA de servidor |
| `templates/ingesta/proteccion.yaml` | ValidatingAdmissionPolicy sobre las CAs de los clientes |
| `templates/ingesta/envoy.yaml` | Gateway de la ingesta y, por cliente, ClientTrafficPolicy, HTTPRoute y SecurityPolicy |
| `templates/ingesta/politica-red.yaml` | NetworkPolicy que cierra los namespaces `monitoring` y `logging` |
| `templates/ingesta/alertas.yaml` | Alertas: política no aplicada, CA que falta, entrega que falla, certificado sin renovar, cliente sin datos |
| `templates/ingesta/_helpers.tpl` | Lee y valida los clientes de `ingesta.clientes` |
| `values.yaml` → `ingesta:` | Gateway, destinos, política de red y alertas (comunes a todos) |
| values del entorno → `ingesta.dominio` y `ingesta.clientes` | El dominio y **un elemento por cliente**: es lo único que se toca para dar de alta o de baja |

## Objetos que se crean

### Comunes (una vez)

| Objeto (CRD) | De quién es el CRD | Para qué |
|---|---|---|
| `Issuer ingesta-autofirmado` | cert-manager | Firma las CAs (la de servidor de laboratorio y la de cada cliente) |
| `Certificate ingesta-ca-servidor` + `Issuer ingesta-ca-servidor` | cert-manager | CA del certificado de servidor. Solo laboratorio: con un certificado de una CA pública, `ingesta.servidorTLS` |
| `Certificate ingesta-servidor` → Secret `ingesta-servidor-tls` | cert-manager | Certificado de servidor `*.ingest.<dominio>`: lo presenta Envoy |
| `Gateway ingesta` (si hay clientes) | Gateway API | Un listener HTTPS por cliente. Se fusiona con el Gateway de la plataforma (`mergeGateways`): mismo Envoy, misma IP |
| `BackendTrafficPolicy ingesta-limite-cuerpo` | Envoy Gateway | Tamaño máximo de cada envío (`requestBuffer`) |
| `ReferenceGrant ingesta-desde-monitoring` (en `logging`) | Gateway API | Deja a las HTTPRoute de `monitoring` enviar a `loki-write` |
| `NetworkPolicy ingesta-cerrar-monitoring` / `-logging` | Kubernetes | Mimir y Loki no autentican: solo entra Envoy (y lo listado en `ingesta.politicaRed`) |
| `PrometheusRule ingesta-mtls` | Prometheus Operator | Alertas (sección de alertas de la guía) |
| `PushSecret ingesta-ca-servidor` | External Secrets | Con `entrega.pushSecret` y CA de servidor propia: su `ca.crt` a `rutaServidor` |
| `ValidatingAdmissionPolicy <release>-ingesta-cas-clientes` (+ Binding) | Kubernetes | Con `ingesta.proteger`: las CAs `ca-<cliente>` no se borran sin `ingesta.borrable=true` |
| `ServiceMonitor cert-manager` | Prometheus Operator | Métricas de caducidad de cert-manager (las usan las alertas) |

### Por cliente (salen solos de su elemento en `ingesta.clientes`)

| Objeto (CRD) | De quién es el CRD | Para qué |
|---|---|---|
| Listener `<cliente>` del `Gateway ingesta` | Gateway API | Host `<cliente>.ingest.<dominio>`, HTTPS 443, certificado de servidor |
| `Certificate ca-<cliente>` → Secret `ca-<cliente>` + `Issuer ca-<cliente>` | cert-manager | Su CA (10 años, `rotationPolicy: Never`), con la etiqueta `ingesta.ca` (protegida). Su listener solo confía en ella |
| `Certificate cliente-<cliente>` → Secret `cliente-<cliente>` | cert-manager | Su certificado de cliente (`CN=<cliente>`, RSA, 90 días, renueva a falta de 30; `clientes[].certificado`) |
| `PushSecret ingesta-<cliente>` | External Secrets | Con `entrega.pushSecret`: sube `tls.crt` y `tls.key` a `<ruta>/<cliente>`. Al quitar el cliente, lo borra de Vault |
| `ClientTrafficPolicy ingesta-<cliente>` | Envoy Gateway | En **su** listener solo acepta certificados de **su** CA, `ca-<cliente>` (TLS ≥ 1.2) |
| `HTTPRoute ingesta-<cliente>` | Gateway API | Solo rutas de envío (`/loki/api/v1/push`, `/otlp/v1/logs`, `/api/v1/push`, `/otlp/v1/metrics`) y `X-Scope-OrgID` fijo |
| `SecurityPolicy ingesta-<cliente>` | Envoy Gateway | Solo si `ipPermitidas`: un certificado robado no sirve desde otra IP |

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
    certificado: {duracion: 2160h, renovarAntes: 720h}   # opcional, por defecto ingesta.certCliente
```

> **Ojo: la CA del cliente (`ca-<cliente>`) no se puede perder.** Si falta, la `ClientTrafficPolicy` queda
> `Accepted=False` y Envoy deja de **exigir certificado** en ese listener (probado en el laboratorio el 17/11/2026:
> solo lo paró `ipPermitidas`), y cert-manager crea otra CA con la que el certificado del cliente ya no vale. Por eso
> la protege una ValidatingAdmissionPolicy y avisan `IngestaCAClienteFalta` e `IngestaPoliticaClienteNoAplicada`.

## Alta y baja

Paso a paso, a mano y explicando cada comando: `central/GUIA-CLIENTES-INGESTA.md` del repo del laboratorio.
En resumen:

- **Alta**: su política y su AppRole en Vault (solo leer lo suyo), añadirlo a `ingesta.clientes` y a
  `grafanaClusters`, y en el cliente `global.appName` y su acceso a Vault. Nada que copiar a mano.
- **Renovación**: sola. cert-manager → PushSecret → Vault → ExternalSecret del cliente → Prometheus / Reloader.
- **Cambio de CA** (cortar sus certificados ya): borrar `ca-<cliente>` (con la anotación) y `cliente-<cliente>`.
- **Baja**: quitarlo del values (se borra también de Vault) y borrar a mano sus Secrets `ca-` y `cliente-`.

Lo que sigue siendo de personas: su IP de salida y, en Vault, su política y su AppRole.

## Requisitos del central

- Envoy Gateway con una GatewayClass (`ingesta.gateway.className`) cuyo `EnvoyProxy` tenga `mergeGateways: true`.
- El Service de Envoy con `externalTrafficPolicy: Local` (IP real del cliente) y delante solo L4.
- Métricas del Envoy en Prometheus (PodMonitor): la alerta de cliente sin datos usa `envoy_cluster_upstream_rq_xx`.
- Un motor de NetworkPolicy en el clúster.
- `ingesta.servidorTLS`: en producción, el certificado del wildcard `*.ingest.<dominio>`.
- Para la entrega por Vault: External Secrets y un ClusterSecretStore (`ingesta.entrega.pushSecret.secretStoreRef`)
  que pueda escribir en `<ruta>/*` y `rutaServidor`.
- kube-state-metrics con `customResourceState` (values del chart): las alertas de política y de entrega lo usan.
