# Handed-over project workloads

One `Application` per project workload that has been **handed over** to GitOps.
Committing a file here is all that is needed — the `project-apps-root`
app-of-apps picks it up. No `kubectl`.

## The handover model

A project owns its namespace and installs its own workload **by hand** first
(`helm install` with its own credentials), and tests it there. That is the
normal state for a **dev** environment, and it may stay that way forever.

When the project wants an environment under GitOps — in practice usually
**prod** — it hands the files to the infra team:

1. the chart reference (a published OCI chart, or a chart in `k8s/projects/`),
2. the values file for that environment.

Infra puts the values under `k8s/projects/<project>/<chart-name>/`, adds an
`Application` here, and commits.

**If the by-hand install was correct, ArgoCD adopts the running release**: same
release name, same namespace, same values, so the first sync is a no-op. Nothing
restarts. A handover that recreates pods means something drifted — compare the
committed values against `helm get values <release> -n <namespace>` before
committing, not after.

After handover, **configuration changes go through infra** (i.e. through a
commit). The project stops editing that release by hand; `selfHeal` would revert
it anyway.

## Writing the Application

Use `project: apps-dev` or `apps-prod` — never `infra`. Those AppProjects
deliberately cannot create namespaces, RBAC, databases or secrets; those are
Layer-1, owned by `k8s/projects/<project>/infra/` and synced separately.

For a published chart use the multi-source shape (OCI chart + this repo as
`ref: values`). See `k8s/projects/_template/README.md` §B2 for the layout and
`proj-scoutid` for a worked example.

Set `CreateNamespace=false`: the namespace already exists, created by the
`project-infra` ApplicationSet.
