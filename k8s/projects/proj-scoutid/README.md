# Project onboarding template

Copy this directory to `k8s/projects/<project>/` to onboard a project. Two
independent parts:

## A. Namespace + developer access (always)

Projects own their namespace(s). Create them and grant a developer a
namespace-scoped ServiceAccount token (pasted into Headlamp or used with
kubectl). See `docs/onboarding.md` for the full flow. Files here:

- `namespace-dev.yaml`, `namespace-prod.yaml` — the project's namespace(s).
- `serviceaccount-rbac.yaml` — a SA + RoleBinding (clusterrole `admin` within
  the namespace) per developer. Duplicate per developer / adjust to `view`.

No ResourceQuota or LimitRange is applied by default — the platform monitors
usage and only intervenes reactively (see `k8s/infra-manifest/cluster-infra/monitor-limits/`).

## B. Optional ArgoCD registration (Helm-per-environment)

If the project wants GitOps, fill in `chart/` (one chart) plus
`values-dev.yaml` and `values-prod.yaml` — one values file per environment,
each stating that environment completely. This is deliberately NOT Kustomize
overlays: values are additive, so a dev value can't leak into prod by omission.

Then add an ArgoCD `Application` (project `apps-dev` / `apps-prod`) pointing at
this chart with the right values file. A project may instead just
`helm install` with its SA token and never touch ArgoCD — registration is optional.
