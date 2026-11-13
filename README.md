# laboratorio-monitoring

Laboratorio de un stack central de monitorización (Grafana, Mimir, Loki, kube-prometheus-stack, logging-operator)
con **ingesta mTLS por cliente**: cada clúster cliente envía sus métricas y logs al central con un certificado de su
propia CA, que su cert-manager renueva solo. El central nunca entra en los clientes.

Dos clústeres k0s de un nodo; sus dos Argo CD leen este repo (público, sin credenciales).

| Carpeta | Qué es | Dónde |
|---|---|---|
| `central/monitoring-stack/` | Chart monitoring-stack 2.0.0 (umbrella de charts oficiales + `templates/ingesta/`) | `k0s-central`, Applications `monitoring` y `logging` |
| `central/monitoring-laboratorio/` | Values del laboratorio, chart de Kafka, Applications de Argo CD y **[GUIA-MONTAJE.md](central/monitoring-laboratorio/GUIA-MONTAJE.md)** | `k0s-central` |
| `central/herramientas-ingesta/` | `alta-cliente.sh` / `baja-cliente.sh`: alta o baja de la CA de un cliente en el values | Tu equipo |
| `central/infra/` | Base del central como Applications de Argo CD (`aplicaciones/`): local-path, MetalLB, Envoy Gateway, cert-manager, CNPG, SeaweedFS, Secrets del laboratorio | `k0s-central` |
| `central/raiz.yaml` | Aplicación raíz del central: base, kafka, monitoring y logging, por olas | `k0s-central`, `kubectl apply` una vez |
| `cliente/infra/argocd/` | Values del Argo CD del cliente | `k0s-cliente` |
| `cliente/cliente-demo-k8s/` | `raiz.yaml` y las Applications del cliente | `k0s-cliente` |
| `cliente/herramientas-cliente/` | Chart que crea las Applications del cliente (cert-manager, Reloader, ingesta, Prometheus, logging-operator) | `k0s-cliente` |
| `cliente/ingesta-mtls-cliente/` | Chart de la CA y el certificado del cliente | `k0s-cliente` |
| `doc/` | Notas y decisiones pendientes (p. ej. [opciones de WAF/OWASP](doc/opciones-waf-owasp.md)) | — |

| Nodo | IP | kubeconfig |
|---|---|---|
| `k0s-central` | 10.99.90.223 | `~/.kube/k0s-central.yaml` |
| `k0s-cliente` | 10.99.90.179 | `~/.kube/k0s-cliente.yaml` |

Los Secrets del laboratorio van **en claro** (valores aleatorios que solo valen aquí). **Nunca** van aquí
credenciales de verdad (tokens de GitHub, nube, producción), claves privadas ni kubeconfigs. De cada cliente solo se
guarda la parte pública de su CA.
