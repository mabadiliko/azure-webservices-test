# Onboarding a project

Projects own their namespace(s) and manage resources inside them however they
like. The platform does not set quotas by default — it monitors usage (see
[governance by observation](#governance-by-observation-what-the-infra-group-watches)
below) and intervenes only reactively.

Onboarding has two layers, split by who is allowed to do what:

- **Layer 1 — infra-owned resources** a project *cannot* create for itself:
  its namespace(s), developer access (RBAC), and any shared services like a
  database. These live in `k8s/projects/<project>/infra/` and are applied
  **automatically by ArgoCD** — the infra team just commits the files.
- **Layer 2 — the project's own workload** (its Deployment, Ingress, …). The
  project runs this itself with its access token, and *optionally* registers it
  with ArgoCD. Infra does not touch it.

The whole point of Layer 1 being GitOps: on a long-lived shared cluster with
maintainers coming and going, Git is the source of truth. What's committed is
what's running; ArgoCD self-heals drift; a successor onboards by reading the
repo, not by hoping a runbook is current.

## How Layer 1 is applied (no manual kubectl)

An ApplicationSet (`k8s/argocd/projects-root/projectset.yaml`) watches
`k8s/projects/*/infra/`. For every project directory it finds, it generates an
ArgoCD `Application` that syncs that project's `infra/` folder under the
`project-infra` AppProject. So **committing a project's `infra/` files is what
deploys them** — there is no `kubectl apply` step.

It syncs only real manifests: `namespace-*.yaml`, `serviceaccount-rbac.yaml`,
and `database.yaml`. The `*.example` files shipped by the template are ignored
until you copy them to their real name. `_template/` itself is excluded.

## A. Namespace + developer access

1. **Copy the template and name it.** Copy `k8s/projects/_template/` to
   `k8s/projects/<project>/`. `PROJECT` is a placeholder in several files;
   replace every occurrence at once:
   ```bash
   grep -rlZ PROJECT k8s/projects/<project>/ \
     | xargs -0 sed -i "s/PROJECT/<project>/g"
   ```
   (`DEVELOPER` in `serviceaccount-rbac.yaml.example` is a separate placeholder —
   leave it; fill it in per developer in step 3.)

2. **Choose the namespace(s).** The template ships `namespace-dev.yaml` and
   `namespace-prod.yaml` as the common case, but the set is **flexible** — the
   ApplicationSet syncs *any* `infra/namespace-*.yaml`:
   - a small project may keep just one (rename to e.g. `namespace.yaml` and drop
     the `-dev`/`-prod` suffix on the namespace name);
   - a project needing staging adds `namespace-staging.yaml`.

   Delete or add files to match. Then **commit** — ArgoCD creates the
   namespaces. Confirm:
   ```bash
   kubectl get ns -l scouterna.se/project=<project>
   ```

3. **Grant a developer access.** Copy
   `infra/serviceaccount-rbac.yaml.example` to `infra/serviceaccount-rbac.yaml`
   and fill in real values (replace `DEVELOPER`; use ClusterRole `admin` for full
   control within the namespace, or `view` for read-only). Commit — ArgoCD
   creates the ServiceAccount + RoleBinding. Then mint a token:
   ```bash
   kubectl -n <project>-dev create token <developer> --duration=8760h
   ```
   Send the token to the developer. They log in at
   `https://headlamp.wsinfra.scouterna.net` (paste the token) and see only their
   namespace(s), or use it with `kubectl`.

   > The token file stays a **`.example`** in the template so ArgoCD never syncs
   > an unfilled `DEVELOPER` placeholder. Only the real, renamed file is applied.

4. **No ResourceQuota / LimitRange is applied.** The project owns the namespace.

## B. The project's own workload (optional ArgoCD registration)

Layer 2 is the project's choice — it can just `helm install` / `kubectl apply`
with its token and never touch ArgoCD. If it wants GitOps:

1. Fill in `k8s/projects/<project>/chart/` plus `values-dev.yaml` and
   `values-prod.yaml` — one values file per environment, each stating that
   environment **completely** (additive — no Kustomize overlays, so no dev value
   leaks into prod). A project with staging adds `values-staging.yaml`.
2. Add an ArgoCD `Application` (project `apps-dev` or `apps-prod`) pointing at
   the chart with the right values file. Those AppProjects are tightly scoped:
   they restrict apps to this repo and to creating only their own Namespace —
   they deliberately **cannot** create the Layer-1 resources (namespaces, RBAC,
   databases). That privilege stays with `project-infra`.

## Secrets (via Key Vault)

A project needing centralized secrets uses an `ExternalSecret` referencing keys
in the shared Key Vault (see the External Secrets Operator setup). No CSI mount
dance — ESO materializes a native Secret. A project can also just create plain
Kubernetes Secrets in its own namespace.

## Add a database with backups (PostgreSQL / CloudNativePG)

A database is a **Layer-1 (infra-owned) resource** — it wires into the shared
CNPG operator, the durable backup storage account, and the shared Key Vault, so
the infra team stands it up even for a project that otherwise self-manages. It
lives in the project's `infra/` directory so it deploys into the project's own
namespace, under the project's scope, via the same ApplicationSet.

Backups go to a **per-project container** in the durable backup storage account
(external to the cluster), via the **Barman Cloud Plugin** (the supported
method; the classic `spec.backup.barmanObjectStore` is deprecated).

1. **Create the project's backup container** (isolates its backups):
   ```bash
   scripts/onboard-cnpg-backup.sh <project>     # creates container cnpg-<project>
   ```
2. **Activate the database manifests.** Copy
   `k8s/projects/<project>/infra/database.yaml.example` to
   `infra/database.yaml` (the `PROJECT` placeholders were already replaced in
   step A1). Commit — ArgoCD applies it. It contains:
   - an `ExternalSecret` that materializes the storage key from Key Vault
     (secret `backup-storage-account-key`) into `backup-storage-key`,
   - an `ObjectStore` (destination = the project's container),
   - a `Cluster` that references the plugin in `spec.plugins`,
   - a daily `ScheduledBackup` (`method: plugin`).
3. **Verify**: the `Cluster` reaches `Cluster in healthy state` and its
   `ContinuousArchiving` condition is `True`; a `Backup` completes and blobs
   appear under `cnpg-<project>/base/…` and `…/wals/…` in the storage account.

> The Barman Cloud Plugin must be installed (infra app `barman-cloud-plugin`).
> Auth is currently a storage-account key via ESO; Workload Identity for CNPG
> is a future improvement. Remember `backups.velero.io` naming does **not** apply
> here — CNPG uses `backups.postgresql.cnpg.io`.

## Removing a project

The ApplicationSet runs with **prune disabled** for exactly one reason: removing
a project's directory from Git must not silently delete a live namespace and all
its data. To decommission a project, delete its namespace(s) deliberately
(`kubectl delete ns <project>-dev …`) and *then* remove
`k8s/projects/<project>/` from Git.

## Governance by observation (what the infra group watches)

- Grafana dashboard "Namespace Resource Usage" — CPU/memory/PVC per namespace.
- Soft-threshold alerts (`governance-observation` PrometheusRule) notify the
  infra group if a namespace requests a large share of the cluster or a PVC
  fills up. They never block.
- If a namespace starves others, the infra group applies a reactive
  LimitRange / ResourceQuota (`k8s/infra-manifest/cluster-infra/monitor-limits/`)
  to that specific namespace — a temporary corrective, removed once resolved.
