# monitoring-laboratorio

Lo propio del **laboratorio** (VM `k0s-central`) para el chart `monitoring-stack` 3.x. El chart no lleva nada de
ningún entorno; aquí está todo lo de este.

| Ruta | Qué es |
|---|---|
| `values-laboratorio.yaml` | Values del entorno: hosts `nip.io`, S3 de SeaweedFS, `local-path`, Kafka, base de datos de Grafana, tenants de Grafana y clientes de la ingesta mTLS (con su entrega por Vault) |
| `kafka/` | Chart del Kafka del laboratorio (Strimzi + `Kafka`, `KafkaNodePool` y `KafkaTopic`), que el monitoring-stack usa como externo |
| `argocd/` | Applications `kafka`, `monitoring`, `logging` y `logging-operator`. Leen este repo público de GitHub, sin credenciales |
| `GUIA-MONTAJE.md` | Qué instalar en cada nodo y en qué orden |

Las crea la aplicación raíz `central/raiz.yaml` (kafka en la ola 0; monitoring y logging en la 1; logging-operator en la 2).
Altas y bajas de clientes: `central/GUIA-CLIENTES-INGESTA.md`.
