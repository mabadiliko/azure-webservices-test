# 03 — Bootstrap the common services (GitOps / ArgoCD)

The common-services layer is installed and managed **entirely by ArgoCD** from
this repo — there is no manual `helm install`. You install ArgoCD, apply the
app-of-apps root, and ArgoCD brings up every service in dependency (sync-wave)
order.

Prerequisites: docs 01 (cluster) and 02 (Key Vault + identity) done;
`KUBECONFIG` points at the cluster; the repo is pushed to Git (ArgoCD pulls from
it).

ArgoCD deploys the *workloads*, but a few things must exist **before** the root
app syncs — things ArgoCD/Helm can't create for you: the bootstrap secrets in
Key Vault, the Azure identities/roles for ESO/Velero/CNPG backups, and the two
client-id placeholders. Do Part A first, then Part B. (The Gateway API CRDs that
Traefik needs are now installed by ArgoCD itself — the `gateway-api-crds` app in
wave 0 — so they're no longer a manual prerequisite.)

---

## Part A — Prerequisites (before applying the root app)

### A1. Bootstrap secrets

**Key Vault is the source of truth.** Put the infra secrets in the Key Vault
once; ESO's `ExternalSecret`s (in `k8s/infra-manifest/external-secrets/`)
materialize them into the cluster, so a **rebuild recreates them automatically**.

`KV` is the durable vault from doc 02 (`kv-scouterna-webservices` for this
deployment — the vault name is globally unique, so no resource group is needed on
these commands). Because the vault is durable, its secrets often **survive a
cluster teardown** — list them first, and skip any that already exist (or let
`secret set` add a new version):

```bash
KV=kv-scouterna-webservices
az keyvault secret list --vault-name $KV --query "[].name" -o tsv   # what's already there
```

Create the secrets that are missing (random values where noted):

```bash
az keyvault secret set --vault-name $KV --name minio-root-user            --value admin
az keyvault secret set --vault-name $KV --name minio-root-password        --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
az keyvault secret set --vault-name $KV --name grafana-admin-password     --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
az keyvault secret set --vault-name $KV --name grafana-github-client-secret --value "<github-oauth-app-client-secret>"   # from A3
```

> **`grafana-github-client-secret` comes from the GitHub OAuth app in A3**, which
> you reach later. You don't need it to bring the cluster up — set a placeholder
> now and overwrite it after A3 (ESO picks up the new version on its next
> refresh). The only thing that stays broken until then is Grafana's GitHub
> login; everything else, including the break-glass admin password, works. The
> `grafana-github-oauth` `ExternalSecret` must still exist for Grafana to start,
> so do set *some* value here, even a placeholder.

The `ExternalSecret`s then produce the in-cluster secrets consumers expect:
`minio-root`, `loki-minio`, `thanos-objstore` (composed from the MinIO values),
`grafana-admin`, `grafana-github-oauth`. **That's the whole job here — put the
values in the Key Vault; ArgoCD and ESO do the rest.** You do *not* create the
in-cluster secrets by hand.

> **How the ordering works (no hand-seeding):** the sync-waves are arranged so
> secrets exist before the things that use them. The ESO operator is wave 0; the
> `ClusterSecretStore` + `ExternalSecret`s (the `external-secrets-config` app)
> are wave 1, alongside MinIO and ahead of wave-2 monitoring. If a consumer does
> start a moment before its secret is materialized, it simply crash-loops and
> **self-heals** the instant ESO reconciles the value from the Key Vault. Nothing
> to babysit — and a rebuild recreates every secret automatically from KV.

### A2. Fill the client-id placeholders

Two ArgoCD Applications carry `<...>` placeholders that must be set to real
values before they sync (Azure identifiers, not secrets):

- `k8s/argocd/infra-apps/external-secrets.yaml` → `<ESO_CLIENT_ID>`
  (the ESO managed-identity client-id from doc 02).
- `k8s/argocd/infra-apps/velero.yaml` → `<VELERO_CLIENT_ID>`,
  `<BACKUP_STORAGE_ACCOUNT>`, `<SUBSCRIPTION_ID>`, `<NODE_RESOURCE_GROUP>`
  (from A4). Also edit the `ClusterSecretStore` vault URL in
  `k8s/infra-manifest/external-secrets/clustersecretstore.yaml`.

### A3. Grafana GitHub OAuth app

Daily Grafana login is **GitHub OAuth**, restricted to the **Scouterna** org,
with GitHub teams → Grafana roles (config in `kube-prometheus-stack-values.yaml`,
`grafana.ini` `auth.github`). The admin password is **break-glass only**.

1. Create a **GitHub OAuth App** (Scouterna org → Settings → Developer settings →
   OAuth Apps): Homepage `https://grafana.wsinfra.scouterna.net`, callback
   `https://grafana.wsinfra.scouterna.net/login/github`.
2. Put the **Client ID** in `grafana.ini` `auth.github.client_id`
   (`<GITHUB_CLIENT_ID>` in the values).
3. Put the **Client Secret** in Key Vault as `grafana-github-client-secret`
   (or in the `grafana-github-oauth` secret seeded in A1).
4. Set `role_attribute_path` to the real Scouterna team slugs.

### A4. Azure prerequisites for backups (Velero + CNPG)

Backups go to a durable, external storage account (see
`infra/backup-storage.bicep`), created once in the `webservices-infra` RG. These
are `az` steps ArgoCD can't do. See `docs/maintenance.md` and the onboarding doc
for the CNPG per-project flow; the Velero identity setup:

```bash
az deployment group create -g webservices-infra \
  -f infra/backup-storage.bicep -p storageAccountName=<account>

az identity create -g webservices-infra -n id-velero-webservices -l swedencentral
PRINCIPAL=$(az identity show -g webservices-infra -n id-velero-webservices --query principalId -o tsv)
STORAGE_ID=$(az storage account show -g webservices-infra -n <account> --query id -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$STORAGE_ID"   # data plane
az role assignment create --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Reader" --scope "$STORAGE_ID"                          # mgmt plane (REQUIRED)
az identity federated-credential create -g webservices-infra --identity-name id-velero-webservices \
  -n velero-<cluster> --issuer "<cluster oidc issuer from doc 01>" \
  --subject "system:serviceaccount:velero:velero" --audiences "api://AzureADTokenExchange"
```
> **Note:** the Velero identity needs **both** `Storage Blob Data Contributor`
> **and** `Reader`. With only the data-plane role the BackupStorageLocation
> validates as Available but backups stall on a silent 403.

---

## Part B — Install ArgoCD and apply the root app

```bash
kubectl create namespace argocd
# --server-side is REQUIRED: the applicationsets CRD exceeds the client-side
# last-applied-configuration annotation size limit and a plain apply fails on it.
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.5/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

kubectl apply -f k8s/argocd/projects/            # infra + apps-dev + apps-prod
kubectl apply -f k8s/argocd/infra-root-app.yaml  # app-of-apps; recurses infra-apps/ by sync-wave
```

The root app brings up every common service in dependency order:

| Wave | Services |
|---|---|
| 0 | cluster-infra (StorageClasses + ClusterIssuers), cert-manager, external-secrets (ESO operator), gateway-api-crds |
| 1 | traefik, minio, cloudnative-pg, external-secrets-config (ClusterSecretStore + ExternalSecrets), barman-cloud-plugin |
| 2 | monitoring (kube-prometheus-stack + Loki + Alloy) |
| 3 | thanos, headlamp |
| 4 | governance (alerts + dashboard), velero |

### Verify + DNS

```bash
kubectl -n argocd get applications                       # sync/health of every service
kubectl -n traefik get svc traefik                       # note EXTERNAL-IP (the LB public IP)
kubectl -n velero get backupstoragelocation default      # -> Available
```
Point the infra-app DNS (`*.<host>`, e.g. `*.wsinfra.scouterna.net`) at the
Traefik LoadBalancer IP.

---

## ArgoCD access — pure GitOps, no exposed GUI

ArgoCD is operated **declaratively**: all config is in Git, changes happen by
commit → auto-sync. There is deliberately **no ArgoCD ingress and no GUI login
(OAuth)** — smaller attack surface, matches the "everything in Git" model.

- **Observe** with `kubectl -n argocd get applications`.
- **Debug** a stuck sync via a temporary
  `kubectl -n argocd port-forward svc/argocd-server 8080:443`, logging in with
  the break-glass admin (`kubectl -n argocd get secret argocd-initial-admin-secret
  -o jsonpath='{.data.password}' | base64 -d`). Not for daily use.

If a shared dashboard is ever wanted, expose `argocd-server` via Traefik + GitHub
OAuth via ArgoCD's bundled Dex (Scouterna org, teams → RBAC). Not done here by
choice.

**Other infra UIs:** Headlamp uses per-developer **ServiceAccount tokens** (the
token *is* the k8s authorization — a dev sees only their namespaces; see
[onboarding.md](onboarding.md)). Grafana uses **GitHub OAuth** (A3).

---

## Notes (from real ArgoCD bring-ups)

- **Public repo needs no credential.** For a private repo, register an ArgoCD
  repository credential whose `url` scheme **matches** the Application `repoURL`
  (an `https://` repoURL needs an HTTPS/token credential, not an SSH deploy key),
  else `authentication required: Repository not found`.
- **Put the bootstrap secrets in the Key Vault first (Part A1).** They are not in
  Git; ESO materializes them. If the KV values are missing, the `ExternalSecret`s
  stay `SecretSyncedError` and their consumers crash-loop until you set them.
- **Expected non-"Synced/Healthy" that are fine:** `cloudnative-pg` shows
  `Degraded` when no Postgres `Cluster` CRs exist yet (operator idle);
  `cert-manager` and `thanos` can sit `OutOfSync/Healthy` on benign Helm/CRD
  field drift. Pods are Running in all three.
- **CRD name clash:** both Velero and CloudNativePG define a `backups` CRD — use
  the fully-qualified `backups.velero.io` / `backups.postgresql.cnpg.io`.
