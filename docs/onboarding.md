# Onboarding a project

Projects own their namespace(s) and manage resources inside them however they
like. The platform does not set quotas by default — it monitors usage (see
governance-by-observation below) and intervenes only reactively.

Two independent parts: **namespace + developer access** (always), and
**optional ArgoCD registration**.

## A. Namespace + developer access (always)

1. **Create the namespace(s).** Copy `k8s/projects/_template/` to
   `k8s/projects/<project>/`, edit the `namespace-*.yaml` (replace `PROJECT`),
   and apply:
   ```bash
   kubectl apply -f k8s/projects/<project>/namespace-dev.yaml
   ```

2. **Create a per-developer ServiceAccount + RoleBinding.** Edit
   `serviceaccount-rbac.yaml` (replace `PROJECT` and `DEVELOPER`; use ClusterRole
   `admin` for full control in the namespace, or `view` for read-only), apply it,
   then mint a token:
   ```bash
   kubectl -n <project>-dev create token <developer> --duration=8760h
   ```
   Send the token to the developer. They log in at
   `https://headlamp.wsinfra.scouterna.net` (paste the token) and see only
   their namespace(s), or use it with `kubectl`.

3. **No ResourceQuota / LimitRange is applied.** The project owns the namespace.

## B. Optional ArgoCD registration (Helm-per-environment)

Not mandatory — a project can just `helm install` / `kubectl apply` with its SA
token. If it wants GitOps:

1. Fill in `k8s/projects/<project>/chart/` plus `values-dev.yaml` and
   `values-prod.yaml`. Each values file states its environment **completely**
   (additive — no Kustomize overlays, so no dev value leaks into prod).
2. Add an ArgoCD `Application` (project `apps-dev` or `apps-prod`) pointing at
   the chart with the right values file. The tighter AppProjects restrict apps
   to this repo and to creating only their own Namespace.

## Secrets (via Key Vault)

A project needing centralized secrets uses an `ExternalSecret` referencing keys
in the shared Key Vault (see the External Secrets Operator setup). No CSI mount
dance — ESO materializes a native Secret. A project can also just create plain
Kubernetes Secrets in its own namespace.

## Add a database with backups (PostgreSQL / CloudNativePG)

Projects get PostgreSQL via CloudNativePG — declare a `Cluster` and the operator
runs it. Backups go to a **per-project container** in the durable backup storage
account (external to the cluster), via the **Barman Cloud Plugin** (the
supported method; the classic `spec.backup.barmanObjectStore` is deprecated).

1. **Create the project's backup container** (isolates its backups):
   ```bash
   scripts/onboard-cnpg-backup.sh <project>     # creates container cnpg-<project>
   ```
2. **Copy the reference manifests** from
   `k8s/projects/_template/chart/postgres-cluster.yaml.example` into the
   project, replacing `PROJECT`. They include:
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

## Governance by observation (what the infra group watches)

- Grafana dashboard "Namespace Resource Usage" — CPU/memory/PVC per namespace.
- Soft-threshold alerts (`governance-observation` PrometheusRule) notify the
  infra group if a namespace requests a large share of the cluster or a PVC
  fills up. They never block.
- If a namespace starves others, the infra group applies a reactive
  LimitRange / ResourceQuota (`k8s/infra-manifest/cluster-infra/monitor-limits/`)
  to that specific namespace — a temporary corrective, removed once resolved.
