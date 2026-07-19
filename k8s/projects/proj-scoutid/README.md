# Project onboarding template

Copy this directory to `k8s/projects/<project>/` to onboard a project, then
replace the `proj-scoutid` placeholder everywhere:

```bash
grep -rlZ proj-scoutid k8s/projects/<project>/ | xargs -0 sed -i "s/proj-scoutid/<project>/g"
```

See [`docs/onboarding.md`](../../../docs/onboarding.md) for the full flow. In
brief, two layers:

## `infra/` — infra-owned, auto-applied by ArgoCD

Resources a project cannot create for itself. An ApplicationSet watches
`k8s/projects/*/infra/` and syncs these on commit — **no manual kubectl**:

- `namespace-dev.yaml`, `namespace-prod.yaml` — the project's namespace(s). The
  set is flexible: keep one, use dev+prod, or add `namespace-staging.yaml`. Any
  `namespace-*.yaml` here is synced.
- `serviceaccount-rbac.yaml.example` — a per-developer SA + RoleBinding
  (clusterrole `admin` within the namespace, or `view`). Copy to
  `serviceaccount-rbac.yaml` and fill in real names to activate it; the
  `.example` is never synced (so an unfilled `DEVELOPER` placeholder can't leak
  in).
- `database.yaml.example` — optional CloudNativePG `Cluster` + backups. Copy to
  `database.yaml` to activate.

No ResourceQuota or LimitRange is applied by default — the platform monitors
usage and only intervenes reactively (see
`k8s/infra-manifest/cluster-infra/monitor-limits/`).

## `chart/` — the project's own workload (optional GitOps)

Never auto-synced. If the project wants GitOps, fill in `chart/` plus
`values-dev.yaml` and `values-prod.yaml` — one values file per environment,
each stating that environment completely (additive, NOT Kustomize overlays, so
a dev value can't leak into prod by omission). Then add an ArgoCD `Application`
under project `apps-dev` / `apps-prod`. A project may instead just `helm install`
with its SA token and never touch ArgoCD — registration is optional.
