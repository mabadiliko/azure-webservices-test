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
  The whole platform can be rebuilt from Git (see `docs/01`–`03`), so a bad
  upgrade is recoverable.

## Cadence by component

Based on each project's real release velocity and blast radius:

| Cadence | Components | Notes |
|---|---|---|
| **Quarterly** (fast-movers) | kube-prometheus-stack, Traefik, ArgoCD, Grafana/Loki/Alloy | Release often; chart-major bumps can change values. Review changelogs. |
| **Semi-annual** (stable) | cert-manager, MinIO, CloudNativePG, Thanos, Headlamp, External Secrets | Slower cadence, fewer breaking changes. |
| **AKS Kubernetes** | the cluster | Patch upgrades are automatic (`autoUpgradeProfile: patch` in the Bicep). **Minor** upgrades (1.33→1.34) are manual, ~3×/year following the K8s release train — do them before the running minor goes out of AKS support. |

## Upgrade-sensitive components (read the changelog first)

Not all bumps are equal. These carry a real risk of breaking changes:

- **External Secrets Operator** — the project moved `0.x → 1.0 → 2.x` in 2025
  (CRD `v1beta1`→`v1`, API changes). Our pin is on the old `0.x` track. Moving to
  `2.x` is a **migration, not a bump** — plan it as its own task with the ESO
  upgrade guide, and re-verify the `ClusterSecretStore` + `ExternalSecret`s.
- **kube-prometheus-stack** — the chart major version changes frequently and can
  rename values / bump CRDs. Diff the values against the new chart's defaults.
- **Traefik** — chart majors (e.g. 39→41) can change the values schema and the
  Traefik minor (v3.6→v3.7). Verify IngressRoutes / middlewares still render.
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

- **Patches** (`1.33.x`): automatic via the `patch` upgrade channel + NodeImage
  channel in `infra/aks.bicep`. Nothing to do.
- **Minors** (`1.33 → 1.34`): manual. Bump `kubernetesVersion` in
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
| AKS Kubernetes | 1.33.12 |
| ArgoCD | v3.4.5 |
| cert-manager | v1.20.2 |
| Traefik | 41.0.2 (v3.7) |
| MinIO | 5.4.0 |
| kube-prometheus-stack | 87.15.1 |
| Loki / Alloy | 6.49.0 / 1.5.0 |
| Thanos (stevehipwell) | 1.23.1 (app 0.41.0) |
| External Secrets | 2.7.0 |
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
