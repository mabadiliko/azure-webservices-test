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
  project runs this itself (with `kubectl`/`helm` as their GitHub identity, see
  [developer access](#b-developer-access-github-sso)), and *optionally* registers
  it with ArgoCD. Infra does not touch it.

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

It syncs only real manifests: `namespace.yaml` / `namespace-*.yaml`,
`developer-rbac.yaml`, and `database.yaml`. The `*.example` files shipped by the
template are ignored until you copy them to their real name. `_template/` itself
is excluded.

## A. Create the project and its namespace(s)

1. **Copy the template and name it.** Copy `k8s/projects/_template/` to
   `k8s/projects/<project>/`, where `<project>` is your project's name. `PROJECT`
   is a placeholder inside several of the files; replace every occurrence at once.
   Run this **from the repo root**, substituting your project name in **both**
   places (the path to edit, and the replacement text):
   ```bash
   # template form — replace <project> in both spots with your project name:
   grep -rlZ PROJECT k8s/projects/<project>/ | xargs -0 sed -i "s/PROJECT/<project>/g"
   ```
   For example, for a project named `proj-scoutid`:
   ```bash
   grep -rlZ PROJECT k8s/projects/proj-scoutid/ | xargs -0 sed -i "s/PROJECT/proj-scoutid/g"
   ```
   This finds every file under your project dir that contains `PROJECT` and
   replaces it in place — including the `chart/` and `.example` files, so they're
   ready when you activate them later.

   (`GITHUB_LOGIN` in `developer-rbac.yaml.example` is a separate placeholder —
   leave it; it's filled per developer in [section B](#b-developer-access-github-sso).)

2. **Choose the namespace(s).** The template ships `namespace-dev.yaml` and
   `namespace-prod.yaml` as the common case, but the set is **flexible** — the
   ApplicationSet syncs `infra/namespace.yaml` **and** any
   `infra/namespace-*.yaml`. Add or delete files to match what the project needs:

   - **dev + prod (default):** keep both files as-is.
   - **one namespace only:** delete `namespace-prod.yaml`, rename
     `namespace-dev.yaml` to `namespace.yaml`, and inside it set the namespace
     `name` to just `<project>` (drop the `-dev` suffix) and remove the
     `scouterna.se/env` label. For example, `proj-scoutid`:
     ```yaml
     # Namespace for proj-scoutid.
     apiVersion: v1
     kind: Namespace
     metadata:
       name: proj-scoutid
       labels:
         scouterna.se/project: proj-scoutid
     ```
   - **add staging:** copy a namespace file to `namespace-staging.yaml` and set
     its `name`/`env` accordingly.

   > Filenames must be `namespace.yaml` or `namespace-<something>.yaml` — that is
   > what the ApplicationSet's include glob matches.

   Then **commit** — ArgoCD creates the namespace(s). Confirm:
   ```bash
   kubectl get ns -l scouterna.se/project=<project>
   ```

2. **No ResourceQuota / LimitRange is applied.** The project owns the namespace.

## B. Developer access (GitHub SSO)

Developers authenticate with their **GitHub identity** via SSO (Dex fronts
GitHub; the cluster's API server trusts Dex). A developer *is* their GitHub
login — there is **no ServiceAccount and no token to hand out**. Two things gate
access:

1. **Membership in the Scouterna GitHub org** — Dex rejects anyone outside it, so
   a developer must be an org member before they can log in at all.
2. **A RoleBinding** the infra team commits, binding the developer's OIDC
   identity into the namespace(s) they should manage.

The OIDC username is `aks:jwt:<github-login>` (the login, lowercased, with an
`aks:jwt:` prefix). **Infra-team members** are handled separately: membership in
the `Webservices Infra` GitHub team grants cluster-admin cluster-wide — they do
**not** need per-project RoleBindings.

### Grant a project developer access

Copy `infra/developer-rbac.yaml.example` to `infra/developer-rbac.yaml` and fill
it in:

- **the user name** — `aks:jwt:<github-login>` (replace `GITHUB_LOGIN` with the
  developer's GitHub username, lowercased). The RoleBinding name conventionally
  follows the login too (`<github-login>-admin`).
- **`namespace`** — one RoleBinding **per namespace** the developer should
  access. A single-namespace project needs one; a dev/prod project needs one in
  each (copy the block, change `namespace`).
- **access level** — ClusterRole `admin` for full control within the namespace,
  or `view` for read-only.

For a second developer, add another RoleBinding block. **Commit** — ArgoCD
creates the RoleBinding(s). Confirm:
```bash
kubectl auth can-i create deployments -n <namespace> --as="aks:jwt:<github-login>"
```

> The file stays a **`.example`** in the template so ArgoCD never syncs an
> unfilled `GITHUB_LOGIN` placeholder. Only the real, renamed
> `developer-rbac.yaml` is applied.

### Grant a whole GitHub team access (recommended for project teams)

For a project with an actual team, bind a **GitHub team** to the namespaces
instead of listing developers one by one. The infra team commits the binding
**once**; after that, membership is managed entirely in GitHub:

- **add a developer to the team → they get access** on their next login,
- **remove them → access is gone** — no cluster change, no commit either way.

The team appears to Kubernetes RBAC as the group `aks:jwt:<org>:<team>` (the
team's **display name**, e.g. `aks:jwt:Scouterna:WSJ27`). Bind that group with a
RoleBinding **per namespace** the team should manage. In `developer-rbac.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: wsj27-team-admin
  namespace: <project>-prod          # one RoleBinding per namespace
subjects:
  - kind: Group
    name: "aks:jwt:Scouterna:WSJ27"  # the GitHub team (display name, verbatim)
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: admin                        # or `view` for read-only
  apiGroup: rbac.authorization.k8s.io
```

Prefer this over per-developer `kind: User` bindings for anything with more than
one or two people — it keeps developer churn out of the repo entirely. (Mix and
match freely: a `developer-rbac.yaml` can hold both `kind: Group` team bindings
and `kind: User` individual bindings.)

> **Verify the exact team string from a real login** before committing the
> binding — the group uses the team's display name as-is, spaces included (e.g.
> `aks:jwt:Scouterna:WSJ27 Crew`). Check Dex's "login successful" log line for a
> team member: its `groups=[…]` shows the precise strings. A mismatched binding
> silently grants nothing.

### How a developer logs in

**Headlamp (web UI):** browse to `https://headlamp.wsinfra.scouterna.net`, click
**Sign in**, authenticate with GitHub. They see only the namespaces their
RoleBindings grant.

**kubectl / helm (CLI):** one-time setup, then it's transparent:

1. Install the `kubectl oidc-login` plugin ([int128/kubelogin][kubelogin] — note
   this is **not** the Azure `kubelogin`):
   ```bash
   kubectl krew install oidc-login          # if you have krew
   ```
   No krew? Download the release binary for your OS from the [kubelogin
   releases][kubelogin] and put it on your `PATH` as `kubectl-oidc_login`
   (kubectl discovers `kubectl-<name>` binaries as the `kubectl <name>` plugin).
2. Get the shared **OIDC kubeconfig** from the infra team (or the repo). It
   contains no secrets — the cluster address, the public CA, and an `exec` block
   that runs `kubectl oidc-login` against Dex. It is **identical for every
   developer**; identity is established at login time.
3. Run any `kubectl` command. The first one opens a browser for GitHub login;
   the token is then cached and silently refreshed (a browser login roughly
   weekly). Example:
   ```bash
   kubectl get pods -n <namespace>          # works within granted namespaces
   ```

[kubelogin]: https://github.com/int128/kubelogin

## C. The project's own workload (optional ArgoCD registration)

Layer 2 is the project's choice — it can just `helm install` / `kubectl apply`
as their GitHub identity and never touch ArgoCD. If it wants GitOps:

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

## Namespace & PVC backups (Velero)

**Every project namespace is backed up automatically — no onboarding step is
needed.** Velero runs two schedules (`k8s/infra-manifest/velero/schedules/`):

| Schedule | What | When | Retention |
|---|---|---|---|
| `daily-projects` | every project namespace (all except infra ns), **incl. PVC data** | 02:00 daily | 14 days |
| `weekly-full` | the whole cluster (all namespaces) as a safety net | 03:00 Sundays | 35 days |

So a project asking "please back up my PVC" already has it: their namespace and
its persistent volumes are captured daily. Backups go to the `velero` container
in the durable backup storage account (external to the cluster).

> **PVC data capture requires a `VolumeSnapshotClass`** labeled
> `velero.io/csi-volumesnapshot-class: "true"` — provided by
> `k8s/infra-manifest/cluster-infra/snapshotclass/disk-snapshot.yaml`. Without
> it, backups capture namespace/object state but **not** volume contents. (The
> weekly full backup may report `PartiallyFailed` on a few un-snapshottable
> cluster resources — that's expected; it's a best-effort safety net.)

### Restore a namespace or PVC

> These are Velero's standard CSI-restore commands. They have not yet been
> exercised against this cluster — **verify on the first real restore** and
> correct this runbook if anything differs.

Restores need the Velero CLI (`velero` — install from the Velero releases) with
`KUBECONFIG` pointing at the cluster.

1. **Find the backup** to restore from:
   ```bash
   velero backup get                          # list backups
   velero backup describe <backup-name>       # what it contains
   ```
2. **Restore a whole namespace** (recreates its objects + PVCs from snapshots):
   ```bash
   velero restore create --from-backup <backup-name> \
     --include-namespaces <project>-prod
   ```
3. **Restore into a different namespace** (e.g. to inspect data without
   clobbering the live one):
   ```bash
   velero restore create --from-backup <backup-name> \
     --include-namespaces <project>-prod \
     --namespace-mappings <project>-prod:<project>-restore
   ```
4. **Restore only specific resources** (e.g. just PVCs):
   ```bash
   velero restore create --from-backup <backup-name> \
     --include-namespaces <project>-prod \
     --include-resources persistentvolumeclaims,persistentvolumes
   ```
5. **Watch it**:
   ```bash
   velero restore describe <restore-name>
   velero restore logs <restore-name>
   ```

> Velero does not overwrite existing resources by default — to restore over a
> live namespace you typically delete the target objects first, or restore into
> a mapped namespace and swap. Test the exact flow before relying on it.

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
