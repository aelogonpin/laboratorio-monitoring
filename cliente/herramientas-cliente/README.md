# herramientas-cliente

Un chart que genera una Application de Argo CD por cada `apps.<nombre>` activo. El Argo CD de cada cliente lo
lee directamente de este repo (`path: cliente/herramientas-cliente`) con `global.appName: <cliente>`.

| values | Contenido |
|---|---|
| `values.yaml` | cert-manager y Reloader |
| `values-monitoring.yaml` | ingesta mTLS (chart `ingesta-mtls-cliente`), CRDs del operador y kube-prometheus-stack escribiendo por mTLS |
| `values-logging.yaml` | logging-operator: Fluentd hacia Loki por mTLS |
| `values-almacenamiento.yaml` | local-path-provisioner, para clústeres sin StorageClass (buffer de Fluentd) |

El nombre del cliente (= `CLUSTER_NAME`) se declara en `apps.ingesta-mtls...nombre` y `apps.monitoring...ingesta.nombre`; Fluentd lo toma de `CLUSTER_NAME`. Este chart no aplica tpl: las `{{ }}` las evalúa el chart de destino.

Sin registro de charts: un cambio aquí llega a los clientes que siguen `main`. Para fijar una versión, crea un tag
y ponlo en el `targetRevision` de la Application del cliente.
