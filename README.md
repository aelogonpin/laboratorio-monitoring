# laboratorio-monitoring · rama `testing`

Rama del curso: el mismo stack que `main`, montado desde cero en `k0s-central` (10.99.90.58) y `k0s-cliente`
(10.99.90.218) y añadido pieza a pieza, una clase cada vez. **`main` es la solución**: cuando termina una clase,
se compara con ella:

```bash
git diff main testing -- central/infra/aplicaciones/
```

Los Argo CD de los dos clústeres leen esta rama (`targetRevision: testing`).

| Clase | Qué entra |
|---|---|
| 2 | `central/raiz.yaml` y local-path. Argo CD v3.6.1 se instala a mano (install.yaml estándar), fuera del repo |
| 3 | MetalLB 0.16.1 (pool = IP del nodo), Envoy Gateway 1.9.3 (con Gateway API v1.6.1), `red/`: EnvoyProxy, GatewayClass y Gateway `principal` :80. El PodMonitor de Envoy llega con Prometheus (clase 6) |

Repo **público**: nada de credenciales reales, claves privadas ni kubeconfigs.
