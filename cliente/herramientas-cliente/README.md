# herramientas-cliente

Un chart que genera una Application de Argo CD por cada `apps.<nombre>` activo y, con `ingesta.enabled`, los
certificados de la ingesta mTLS (`templates/ingesta-mtls.yaml`). El Argo CD de cada cliente lo
lee directamente de este repo (`path: cliente/herramientas-cliente`) con `global.appName: <cliente>`.

| values | Contenido |
|---|---|
| `values.yaml` | cert-manager y Reloader |
| `values-monitoring.yaml` | `ingesta:` (CA del cliente, sus certificados y la CA del servidor central), CRDs del operador y kube-prometheus-stack escribiendo por mTLS |
| `values-logging.yaml` | logging-operator: Fluentd hacia Loki por mTLS |
| `values-almacenamiento.yaml` | local-path-provisioner, para clústeres sin StorageClass (buffer de Fluentd) |

El nombre del cliente (= `CLUSTER_NAME` de `monitoring-secrets`) se escribe **una vez**, en `global.appName`: lo usan los certificados de la ingesta y se copia a `ingesta.nombre` de toda app cuyo `valuesObject` traiga `ingesta:` (la URL de Prometheus). Fluentd lo toma de `CLUSTER_NAME`. En `apps` no se aplica tpl: las `{{ }}` las evalúa el chart de destino.

Los certificados de la ingesta usan los CRDs de cert-manager, que instala `apps.cert-manager`: la Application de este
chart necesita `SkipDryRunOnMissingResource=true` y `retry`. La CA del cliente lleva `Delete=false`: no se borra
nunca, ni al desactivar la ingesta.

Sin registro de charts: un cambio aquí llega a los clientes que siguen `main`. Para fijar una versión, crea un tag
y ponlo en el `targetRevision` de la Application del cliente.
