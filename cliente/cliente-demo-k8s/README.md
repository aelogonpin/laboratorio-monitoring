# cliente-demo-k8s

Despliegue del clúster `cliente-demo` (laboratorio). Su Argo CD lee de esta carpeta del repo público, sin
credenciales. **El central no entra nunca en este clúster**: todo va del cliente hacia fuera (GitHub y la
ingesta mTLS).

| Fichero | Qué es |
|---|---|
| `raiz.yaml` | Aplicación de aplicaciones. Se aplica una vez, a mano. |
| `aplicaciones-cliente-demo/herramientas-cliente.yaml` | Herramientas del clúster (cert-manager, Reloader, External Secrets, Prometheus, logging-operator e ingesta mTLS) desde el chart `herramientas-cliente`. Se declaran `global.appName` y la entrada a Vault (`ingesta.vault`). |
| `aplicaciones-cliente-demo/demo-app.yaml` | La aplicación del cliente. |

Los Secrets `monitoring-secrets` (`clusterName`, `distro`) y `external-secrets/vault-approle` (secret_id del AppRole
de cliente-demo en el Vault del laboratorio) están en `secretos/` y los aplica la app `secretos`.
**No lleva contraseñas de Loki ni Mimir.**

## Alta en el central

El cliente no genera nada: el alta se hace entera en el central (`central/GUIA-CLIENTES-INGESTA.md`). El central crea
su CA y su certificado y los sube a Vault (`ingesta/clientes/cliente-demo`); aquí los ExternalSecret los traen a los
Secrets `ingesta-mtls` e `ingesta-ca-servidor` de `monitoring` y `logging`.

Hasta el alta, los ExternalSecret dan error (no hay nada en Vault) y Prometheus y Fluentd esperan al Secret.

```bash
kubectl get externalsecret -A          # tras el alta: SecretSynced
```
