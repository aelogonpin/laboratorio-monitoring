# herramientas-cliente

Un chart que genera una Application de Argo CD por cada `apps.<nombre>` activo y, con `ingesta.enabled`, trae de
Vault el certificado de la ingesta mTLS (`templates/ingesta-mtls.yaml`): el cliente no tiene CA propia, el central
crea y renueva su certificado. El Argo CD de cada cliente lo
lee directamente de este repo (`path: cliente/herramientas-cliente`) con `global.appName: <cliente>`.

| values | Contenido |
|---|---|
| `values.yaml` | cert-manager (webhook de kube-prometheus-stack), Reloader y External Secrets |
| `values-monitoring.yaml` | `ingesta:` (de dónde salen el certificado y la CA del servidor: `origen: vault` o `manual`), CRDs del operador y kube-prometheus-stack escribiendo por mTLS |
| `values-logging.yaml` | logging-operator: Fluentd hacia Loki por mTLS |
| `values-almacenamiento.yaml` | local-path-provisioner, para clústeres sin StorageClass (buffer de Fluentd) |

El nombre del cliente (= `CLUSTER_NAME` de `monitoring-secrets`) se escribe **una vez**, en `global.appName`: es la ruta de su certificado en Vault (`<clave>/<appName>`) y se copia a `ingesta.nombre` de toda app cuyo `valuesObject` traiga `ingesta:` (la URL de Prometheus). Fluentd lo toma de `CLUSTER_NAME`. En `apps` no se aplica tpl: las `{{ }}` las evalúa el chart de destino.

El ClusterSecretStore y los ExternalSecret de la ingesta usan los CRDs de External Secrets, que instala
`apps.external-secrets`: la Application de este chart necesita `SkipDryRunOnMissingResource=true` y `retry`. Por cliente:
`ingesta.vault.server`, `ingesta.vault.appRole.roleId` y el Secret `external-secrets/vault-approle` (`secret-id`), que
este chart no crea. Con un ClusterSecretStore que ya exista: `ingesta.vault.almacen: {crear: false, nombre: <el suyo>}`.

Sin registro de charts: un cambio aquí llega a los clientes que siguen `main`. Para fijar una versión, crea un tag
y ponlo en el `targetRevision` de la Application del cliente.
