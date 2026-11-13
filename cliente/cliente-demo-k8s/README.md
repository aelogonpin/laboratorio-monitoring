# cliente-demo-k8s

Despliegue del clúster `cliente-demo` (laboratorio). Su Argo CD lee de esta carpeta del repo público, sin
credenciales. **El central no entra nunca en este clúster**: todo va del cliente hacia fuera (GitHub y la
ingesta mTLS).

| Fichero | Qué es |
|---|---|
| `raiz.yaml` | Aplicación de aplicaciones. Se aplica una vez, a mano. |
| `aplicaciones-cliente-demo/herramientas-cliente.yaml` | Herramientas del clúster (cert-manager, Reloader, Prometheus, logging-operator e ingesta mTLS) desde el chart `herramientas-cliente`. Solo se declara `global.appName`. |
| `aplicaciones-cliente-demo/demo-app.yaml` | La aplicación del cliente. |

El Secret `monitoring-secrets` (`clusterName`, `distro`) está en `secretos/` y lo aplica la app `secretos`.
**No lleva contraseñas de Loki ni Mimir.**

## Alta en el central

Al primer arranque, cert-manager crea la CA del cliente. Su parte pública se manda al central, que la da de alta
(`alta-cliente.sh cliente-demo ca.crt <ip>/32`) y comprueba la huella por otro canal:

```bash
kubectl -n cert-manager get secret ingesta-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
```

Hasta el alta, Prometheus y Fluentd reintentan (rechazo TLS). Copia de seguridad del Secret `ingesta-ca`: si se
pierde, cert-manager crea otra CA y hay que repetir el alta.
