# Maintenance plan

The cluster and its common services are pinned to specific versions (in
`infra/aks.bicep` and each `k8s/argocd/infra-apps/*.yaml`). Pinned versions age;
this document is how we keep them current without surprises.

## Principles

- **Pin everything, upgrade deliberately.** Never track `latest`. An upgrade is a
  reviewed change: read the changelog, bump the version in Git, let ArgoCD sync,
  verify. One component at a time.
- **Match cadence to how fast each thing moves.** Some charts release weekly;
  others are stable for months. Don't upgrade on a fixed calendar for its own
  sake — upgrade the fast-movers often, the stable ones rarely.
- **Test before prod.** When there is a dev/test cluster, upgrade there first.
  The whole platform can be rebuilt from Git (see [`docs/install.md`](install.md)), so a bad
  upgrade is recoverable.

## Cadence by component

Based on each project's real release velocity and blast radius:

| Cadence | Components | Notes |
|---|---|---|
| **Quarterly** (fast-movers) | kube-prometheus-stack, Traefik, ArgoCD, Grafana/Loki/Alloy | Release often; chart-major bumps can change values. Review changelogs. |
| **Semi-annual** (stable) | cert-manager, MinIO, CloudNativePG, Thanos, Headlamp, External Secrets, Gateway API CRDs | Slower cadence, fewer breaking changes. Bump the Gateway API CRDs in step with Traefik (see below). |
| **AKS Kubernetes** | the cluster | Patch upgrades are automatic (`autoUpgradeProfile: patch` in the Bicep). **Minor** upgrades (1.36→1.37) are manual, ~3×/year following the K8s release train — do them before the running minor goes out of AKS support. |

## Upgrade-sensitive components (read the changelog first)

Not all bumps are equal. These carry a real risk of breaking changes:

- **External Secrets Operator** — the project moved `0.x → 1.0 → 2.x` in 2025
  (CRD `v1beta1`→`v1`, API changes). We are already on the `2.x` track and our CRs
  use the `v1` API, so ordinary `2.x` bumps are routine. The chart owns its CRDs,
  so an *in-place* upgrade across that old boundary would need the previous CRDs
  removed first — not a concern for a fresh install.
- **Loki** — the OSS chart **changed repository** in March 2026. `grafana/loki`'s
  chart became Grafana **Enterprise** Logs only at `7.0.0`; the OSS chart forked to
  `grafana-community/helm-charts` (from 6.55.0, renumbered to `18.x`). We track the
  community OSS chart. **Never "upgrade" to grafana.github.io `7.x`** — that is a
  different (enterprise) product, not a newer version of what we run.
- **kube-prometheus-stack** — the chart major version changes frequently and can
  rename values / bump CRDs. Diff the values against the new chart's defaults.
- **Traefik** — chart majors (e.g. 39→41) can change the values schema and the
  Traefik minor (v3.6→v3.7). Verify IngressRoutes / middlewares still render.
- **Gateway API CRDs** — installed by the `gateway-api-crds` ArgoCD app (wave 0),
  pinned by `targetRevision` (a git tag). **Pin to Traefik's version, not to the
  latest release.** Traefik is compiled against a specific Gateway API version;
  installing newer CRDs puts the schema ahead of the code that reads it, with no
  benefit. Check before bumping:
  ```bash
  curl -s https://raw.githubusercontent.com/traefik/traefik/v3.7.6/go.mod | grep gateway-api
  # -> sigs.k8s.io/gateway-api v1.5.1   (use the tag matching the chart's appVersion)
  ```
  The app has `prune: false`, so the CRDs (and any Gateways/HTTPRoutes) are never
  deleted by a sync — upgrades apply in place.
- **cert-manager** — generally smooth, but CRD upgrades must be applied (the
  chart handles this with `crds.enabled: true`).

Slow/low-risk: MinIO, CloudNativePG (operator; watch the PG major it manages),
Thanos, Headlamp.

## How to upgrade a common service

1. Check the new version's changelog for breaking changes / CRD updates.
2. Bump `targetRevision` in the service's `k8s/argocd/infra-apps/<svc>.yaml`.
3. If values changed, update the file under `k8s/infra-manifest/<svc>/`. Validate
   with `helm template <chart> --repo <url> --version <new> -f <values>` before
   committing (catches schema/breaking changes without touching the cluster).
4. Commit. ArgoCD syncs. Watch the app go `Synced/Healthy` and the pods roll.
5. Verify the service functionally (e.g. Grafana loads, a cert issues, Loki
   ingests) — not just that pods are Running.

## AKS upgrades

- **Patches** (`1.36.x`): automatic via the `patch` upgrade channel + NodeImage
  channel in `infra/aks.bicep`. Nothing to do.
- **Minors** (`1.36 → 1.37`): manual. Bump `kubernetesVersion` in
  `infra/aks.bicep` + the param files, `az deployment group create` (or
  `az aks upgrade`). Do it before AKS drops support for the running minor
  (check `az aks get-versions -l <region>`). On a single-node cluster the
  upgrade is briefly disruptive — expect a short control-plane/node blip.

## Automating drift detection

Consider adding **Renovate** (or Dependabot) to the repo. It watches the pinned
chart/image versions and opens PRs when new versions are available — so "what is
behind?" is answered automatically instead of by hand. Pair it with the cadence
above: merge fast-mover PRs promptly, batch the stable ones.

## Current pins (baseline)

As of the initial build:

| Component | Pin |
|---|---|
| AKS Kubernetes | 1.36.2 |
| ArgoCD | v3.4.5 |
| cert-manager | v1.21.0 |
| Traefik | 41.0.2 (v3.7) |
| Gateway API CRDs | v1.5.1 |
| MinIO | 5.4.0 |
| kube-prometheus-stack | 87.19.2 |
| Loki / Alloy | 18.5.4 (grafana-community OSS fork) / 1.11.0 |
| Thanos (stevehipwell) | 1.24.0 (app 0.42.2) |
| External Secrets | 2.8.0 |
| CloudNativePG | 0.29.0 (app 1.30.0) |
| Headlamp | 0.41.0 |
| Velero | 12.1.0 (app 1.18.1) |
| CNPG Barman Cloud Plugin | v0.13.0 |

> The cluster was launched on current versions of the fast-movers (ESO, kps,
> Traefik brought to latest at build time) so the first maintenance cycle isn't a
> migration. Breaking changes handled during that bump, for reference:
> - **ESO 0.x → 2.x**: our CRs were already on the `v1` API, so no manifest change
>   — but the chart owns its CRDs, so an *in-place* upgrade from ArgoCD-installed
>   0.x CRDs needs the old CRDs removed first (helm won't adopt un-owned CRDs). A
>   fresh install is clean.
> - **Traefik v39 → v41**: the chart's top-level `logs:` key became `log:` (level
>   moved directly under it) and access logs are now a separate `accessLog:` key.
