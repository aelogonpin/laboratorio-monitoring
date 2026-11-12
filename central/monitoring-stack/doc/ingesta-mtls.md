# Ingesta mTLS de clientes externos

Los clústeres de cliente envían logs (Loki) y métricas (Mimir) al central con un **certificado de
cliente** en lugar de usuario y contraseña. Se activa con `global.monitoring.ingesta` (release `monitoring`).

## Cómo viaja una petición

```
Cliente (Prometheus / Fluentd)                         Central
 cert-manager del cliente: su CA y su certificado
 ── HTTPS + certificado ──►  Traefik :443  host <cliente>.ingest.<dominio>
                              1. TLSOption mtls-<cliente>   ¿certificado firmado por SU CA?   no -> corta en el TLS
                              2. Middleware ip-<cliente>    ¿IP permitida? (opcional)         no -> 403
                              3. Middleware ingesta-limite-cuerpo                             > 50 MB -> 413
                              4. Middleware tenant-<cliente> pone X-Scope-OrgID = <cliente> (pisa el del cliente)
                              5. IngressRoute ingesta-<cliente>: solo rutas de envío          resto -> 404
                                    │
                                    ▼  HTTP interno (NetworkPolicy: solo entra Traefik)
                              loki-write / mimir-distributor
```

## Ficheros

| Fichero | Qué hace |
|---|---|
| `templates/ingesta/pki.yaml` | Certificados: CA y certificado de **servidor**, y la CA pública de cada cliente |
| `templates/ingesta/traefik.yaml` | Por cliente: TLSOption, Middlewares e IngressRoute |
| `templates/ingesta/politica-red.yaml` | NetworkPolicy que cierra los namespaces `monitoring` y `logging` |
| `templates/ingesta/alertas.yaml` | Alertas: certificado por caducar, cliente sin datos |
| `templates/ingesta/_helpers.tpl` | Lee y valida los clientes de `ingesta.clientes` |
| `values.yaml` → `ingesta:` | Destinos, política de red y alertas (comunes a todos) |
| values del entorno → `ingesta.dominio` y `ingesta.clientes` | El dominio y **un elemento por cliente**: es lo único que se toca para dar de alta o de baja |

## Objetos que se crean

### Comunes (una vez)

| Objeto (CRD) | De quién es el CRD | Para qué |
|---|---|---|
| `Issuer ingesta-autofirmado` | cert-manager | Firma las CAs (la de servidor de laboratorio y las de clientes en modo central) |
| `Certificate ingesta-ca-servidor` + `Issuer ingesta-ca-servidor` | cert-manager | CA del certificado de servidor. Solo laboratorio: en producción, el wildcard de la empresa (`ingesta.servidorTLS`) |
| `Certificate ingesta-servidor` → Secret `ingesta-servidor-tls` | cert-manager | Certificado de servidor `*.ingest.<dominio>`: lo presenta Traefik |
| `Middleware ingesta-limite-cuerpo` | Traefik | Tamaño máximo de cada envío |
| `Middleware ingesta-a-cortex-tenant` | Traefik | Cambia `/api/v1/push` por `/push` para cortex-tenant |
| `NetworkPolicy ingesta-cerrar-monitoring` / `-logging` | Kubernetes | Mimir y Loki no autentican: solo entra Traefik (y lo listado en `ingesta.politicaRed`) |
| `PrometheusRule ingesta-mtls` | Prometheus Operator | Alertas de certificados y de cliente sin datos |
| `ServiceMonitor cert-manager` | Prometheus Operator | Métricas de caducidad de cert-manager (las usan las alertas) |

### Por cliente (salen solos de su elemento en `ingesta.clientes`)

| Objeto (CRD) | De quién es el CRD | Para qué |
|---|---|---|
| `Secret ca-<cliente>-<n>` | Kubernetes | Parte **pública** de la CA del cliente (`cas:`). Varias = cambio de CA sin corte |
| `TLSOption mtls-<cliente>` | Traefik | En su host solo acepta certificados de **su** CA (`RequireAndVerifyClientCert`, TLS ≥ 1.2, SNI obligatorio) |
| `Middleware tenant-<cliente>` | Traefik | Fija `X-Scope-OrgID`: el tenant lo decide el central, no el cliente |
| `Middleware ip-<cliente>` | Traefik | Solo si `ipPermitidas`: un certificado robado no sirve desde otra IP |
| `IngressRoute ingesta-<cliente>` | Traefik | Host `<cliente>.ingest.<dominio>` → rutas de envío de Loki y Mimir con sus Middlewares y su TLSOption |
| `Certificate ca-<cliente>` + `Issuer` + `Certificate cliente-<cliente>` | cert-manager | Solo en modo **CA en el central** (sin `cas:`, clientes sin cert-manager): el central emite su certificado y hay que entregárselo |

Por qué IngressRoute y TLSOption (CRDs de Traefik) y no HTTPRoute: Gateway API estándar no permite exigir un
certificado de cliente distinto por host.

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

Con las herramientas del repo `ingesta-mtls` (`herramientas/`), sobre el values del entorno:

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

- Traefik con `providers.kubernetesCRD.allowCrossNamespace: true` (las rutas de Loki van al namespace `logging`).
- Traefik ve la IP real del cliente (`externalTrafficPolicy: Local`) y delante solo hay L4.
- Un motor de NetworkPolicy en el clúster.
- `ingesta.servidorTLS`: en producción, el certificado del wildcard `*.ingest.<dominio>`.
