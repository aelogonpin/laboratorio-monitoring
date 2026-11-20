# laboratorio-monitoring

Laboratorio de un stack central de monitorización (Grafana, Mimir, Loki, kube-prometheus-stack, logging-operator)
con **ingesta mTLS por cliente** y multitenancy: cada clúster cliente envía sus métricas y logs al central con su
propio certificado, y el central fija su tenant. **El central es el dueño de los certificados**: crea la CA y el
certificado de cada cliente, los renueva y los deja en Vault; cada cliente los trae con External Secrets. El central
nunca entra en los clientes.

Tres clústeres k0s de un nodo; sus Argo CD leen este repo (público, sin credenciales).

| Carpeta | Qué es | Dónde |
|---|---|---|
| `central/monitoring-stack/` | Chart monitoring-stack 3.0.0 (umbrella de charts oficiales + `templates/ingesta/`). Diseño de la ingesta: [doc/ingesta-mtls.md](central/monitoring-stack/doc/ingesta-mtls.md) | `k0s-central`, Applications `monitoring`, `logging` y `logging-operator` |
| `central/monitoring-laboratorio/` | Values del laboratorio, chart de Kafka, Applications de Argo CD y **[GUIA-MONTAJE.md](central/monitoring-laboratorio/GUIA-MONTAJE.md)** | `k0s-central` |
| `central/GUIA-CLIENTES-INGESTA.md` | Guía de alta, renovación, cambio de CA y baja de clientes, paso a paso | Tu equipo |
| `central/infra/` | Base del central como Applications de Argo CD (`aplicaciones/`): local-path, MetalLB, Envoy Gateway, cert-manager, CNPG, SeaweedFS, External Secrets, el Vault del laboratorio y sus Secrets. `cloud-init.yaml` para las VMs | `k0s-central` |
| `central/raiz.yaml` | Aplicación raíz del central, por olas | `k0s-central`, `kubectl apply` una vez |
| `cliente/herramientas-cliente/` | Chart que crea las Applications de cada cliente (cert-manager, Reloader, External Secrets, Prometheus, logging-operator) y trae de Vault su certificado de la ingesta | Clientes |
| `cliente/cliente-demo-k8s/`, `cliente/cliente-b-k8s/` | `raiz.yaml` y las Applications de cada cliente | `k0s-cliente`, `k0s-cliente-b` |
| `doc/` | Notas y decisiones pendientes (p. ej. [opciones de WAF/OWASP](doc/opciones-waf-owasp.md)) | — |

| Nodo | IP | kubeconfig | Papel |
|---|---|---|---|
| `k0s-central` | 10.99.90.58 | `~/.kube/k0s-central.yaml` | Monitorización central, Vault del laboratorio |
| `k0s-cliente` | 10.99.90.218 | `~/.kube/k0s-cliente.yaml` | Cliente `cliente-demo` |
| `k0s-cliente-b` | 10.99.90.254 | `~/.kube/k0s-cliente-b.yaml` | Cliente `cliente-b` |

Los Secrets del laboratorio van **en claro** (valores aleatorios que solo valen aquí, también los del Vault de
pruebas). **Nunca** van aquí credenciales de verdad (tokens de GitHub, nube, producción), claves privadas ni
kubeconfigs. Los certificados de los clientes no están en el repo: los crea el central y viajan por Vault.
