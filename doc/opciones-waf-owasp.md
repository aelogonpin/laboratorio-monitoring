# WAF / OWASP CRS con Envoy Gateway: opciones (pendiente)

**Decisión (2026-11-13):** de momento **sin WAF que bloquee**. Si se añade algo, será el **OWASP Core Rule Set en
modo detección** (`SecRuleEngine DetectionOnly`) para ver patrones raros en los logs, sin cortar tráfico.

## Dónde tendría sentido

- **Grafana** (única entrada pública con login): sí, en su HTTPRoute.
- **Ingesta mTLS**: no. Antes de llegar a la ruta ya se ha validado el certificado del cliente y solo se aceptan
  `/api/v1/push` y `/loki/api/v1/push`. Los cuerpos son métricas y logs comprimidos de varios MB: el CRS solo daría
  falsos positivos y gastaría CPU. Ahí protegen el mTLS, `ipPermitidas` y los límites por tenant de Mimir y Loki.

## Opciones

Todas usan el motor **Coraza** (proyecto OWASP, Apache 2.0) con las reglas **OWASP CRS**, salvo CrowdSec y open-appsec.

| Opción | Licencia | Cómo se engancha | Madurez | Notas |
|---|---|---|---|---|
| Coraza como **módulo dinámico** de Envoy | Libre | `EnvoyExtensionPolicy` → `dynamicModule` | Reciente (ABI estable desde Envoy 1.37) | Rendimiento nativo, sin WASM. Cargarlo desde un volumen de imagen pide Kubernetes ≥ 1.35. **Primera opción** |
| **coraza-proxy-wasm** | Libre | `EnvoyExtensionPolicy` → `wasm` | Más rodado | Mismo motor y reglas; más lento y más memoria (WASM) |
| **CrowdSec AppSec** | Libre (versión comunitaria) | Bouncer de Envoy Gateway por `ext_authz` | Estable | Reglas compatibles con CRS y **baneo de IPs por reputación** (listas comunitarias). Para un "auto-ban" sin scripts propios |
| open-appsec | Versión comunitaria gratis; no está claro si cubre Envoy | `EnvoyPatchPolicy` | Alpha, solo con el Operator | Descartado por ahora |
| TEG (Tetrate Enterprise Gateway) | **De pago** | Coraza ya viene en la imagen (`ExtendedSecurityPolicy`) | Estable | Es la que describe el documento "razon"; no es el Envoy Gateway libre |

## Avisos

- Envoy Gateway **no valida la sintaxis de las reglas** al crear la política: los errores salen en los logs de Envoy
  y una configuración mala puede hacer que Envoy rechace el listener. Probar siempre en el laboratorio.
- Empezar en `DetectionOnly`, revisar falsos positivos en Loki (los ataques llevan el ID de la regla, p. ej.
  949110/949111) y solo después, si se quiere, pasar a `On`.
- Una política de ruta tiene prioridad sobre la del Gateway: cuidado con que una política de una ruta anule la del
  dominio.

## Fuentes

- Módulos dinámicos en Envoy Gateway: https://gateway.envoyproxy.io/docs/tasks/extensibility/dynamic-modules/
- coraza-proxy-wasm: https://github.com/corazawaf/coraza-proxy-wasm
- CrowdSec con Envoy Gateway: https://docs.crowdsec.net/docs/appsec/quickstart/envoy-gateway
- open-appsec con Envoy Gateway: https://docs.openappsec.io/getting-started/start-with-kubernetes/integrate-with-envoy-gateway
- Coraza en TEG (de pago): https://docs.tetrate.io/envoy-gateway/howto/coraza
