# Traefik + Gateway API (k0s-central)

Official chart `traefik/traefik`, Gateway API provider enabled.
Pinned versions live in `versions.env`.

| Component          | Version      | Source                                                    |
|--------------------|--------------|-----------------------------------------------------------|
| Chart / Traefik    | 42.1.1 / v3.7.16 | https://traefik.github.io/charts                      |
| Traefik CRDs       | from chart 42.1.1 | `crds/traefik.io_*.yaml` inside the chart            |
| Gateway API CRDs   | v1.6.3 experimental | kubernetes-sigs/gateway-api release assets         |

## Files
- `versions.env`   – pinned versions (only place to edit when upgrading)
- `values.yaml`    – Helm values (hostPort 80/443, Service ClusterIP, Gateway `traefik-gateway`)
- `update-crds.sh` – regenerates `crds/` from the pinned versions
- `install.sh`     – applies CRDs (server-side) + `helm upgrade --install --skip-crds`
- `crds/`          – generated, do not edit by hand

## Why CRDs are outside Helm
- `traefik/traefik-crds` is deprecated (traefik/traefik-helm-chart#1561) and its
  release Secret exceeds Helm's 1 MB limit with Gateway API included.
- Helm never upgrades CRDs from a chart's `crds/` dir, so they are applied explicitly.
- Ignore the chart NOTES suggesting Gateway API v1.5.1: Traefik v3.7.16 docs/go.mod target v1.6.3.

## Upgrade
1. Bump `TRAEFIK_CHART_VERSION` in `versions.env`.
2. Set `GATEWAY_API_VERSION` to the one stated for that Traefik release in
   `docs/content/reference/install-configuration/providers/kubernetes/kubernetes-gateway.md`.
3. `./update-crds.sh && ./install.sh`
4. `kubectl -n traefik rollout restart deploy/traefik` if only CRDs changed.

## Exposing a service
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: grafana, namespace: monitoring}
spec:
  parentRefs: [{name: traefik-gateway, namespace: traefik}]
  hostnames: ["grafana.local"]
  rules: [{backendRefs: [{name: grafana, port: 80}]}]
```
Then `10.99.90.223 grafana.local` in `/etc/hosts`.
