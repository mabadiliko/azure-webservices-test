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

### A1. Grafana GitHub OAuth app

Daily Grafana login is **GitHub OAuth**, restricted to the **Scouterna** org,
with GitHub teams → Grafana roles (config in `kube-prometheus-stack-values.yaml`,
`grafana.ini` `auth.github`). The admin password is **break-glass only**. Do this
first so its **Client Secret** is ready to write with the other secrets in A2.

1. Create a **GitHub OAuth App** (Scouterna org → Settings → Developer settings →
   OAuth Apps): Homepage `https://grafana.wsinfra.scouterna.net`, callback
   `https://grafana.wsinfra.scouterna.net/login/github`.
2. Note the **Client ID** — it fills `<GITHUB_CLIENT_ID>` in A4.
3. Note the **Client Secret** — it becomes the `grafana-github-client-secret`
   Key Vault entry in A2.
4. Set `role_attribute_path` to the real Scouterna team slugs.

### A2. Bootstrap secrets

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

Create the secrets that are missing (random values where noted; the GitHub
client secret is the real value from A1):

```bash
az keyvault secret set --vault-name $KV --name minio-root-user            --value admin
az keyvault secret set --vault-name $KV --name minio-root-password        --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
az keyvault secret set --vault-name $KV --name grafana-admin-password     --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
az keyvault secret set --vault-name $KV --name grafana-github-client-secret --value "<client-secret-from-A1>"
```

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

### A3. Azure prerequisites for backups (Velero + CNPG)

Backups go to a durable, external storage account (see
`infra/backup-storage.bicep`), created once in the `webservices-infra` RG. These
are `az` steps ArgoCD can't do. See `docs/maintenance.md` and the onboarding doc
for the CNPG per-project flow; the Velero identity setup:

The `ACCOUNT` variable below is the durable backup storage account —
`stwsv2backup` for this deployment (it's used in three of the commands, so it's
set once). Storage account names are **globally unique, 3–24 chars, lowercase
alphanumeric only** (no hyphens), so a fresh deployment needs a distinctive name.
Because the account lives in the durable RG it usually **already exists** on a
rebuild — the deployment is then idempotent (safe to re-run) and the `az identity
create` below will say the identity already exists, which is fine.

```bash
ACCOUNT=stwsv2backup            # the durable backup storage account (used 3× below)
FEDCRED=velero-webservices-v2   # name for Velero's federated credential — one per
                                # cluster, your choice (e.g. velero-<cluster-name>)
CLUSTER_RG=webservices-v2       # the CLUSTER's resource group (doc 01) — note this
                                # differs from the durable webservices-infra RG below
CLUSTER=webservices-v2          # the cluster name (doc 01)

az deployment group create -g webservices-infra \
  -f infra/backup-storage.bicep -p storageAccountName=$ACCOUNT

az identity create -g webservices-infra -n id-velero-webservices -l swedencentral
PRINCIPAL=$(az identity show -g webservices-infra -n id-velero-webservices --query principalId -o tsv)
STORAGE_ID=$(az storage account show -g webservices-infra -n $ACCOUNT --query id -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$STORAGE_ID"   # data plane
az role assignment create --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Reader" --scope "$STORAGE_ID"                          # mgmt plane (REQUIRED)

# Same OIDC issuer used for the ESO federated credential in doc 02 step 3.
ISSUER=$(az aks show -g $CLUSTER_RG -n $CLUSTER --query oidcIssuerProfile.issuerUrl -o tsv)
az identity federated-credential create -g webservices-infra --identity-name id-velero-webservices \
  -n $FEDCRED --issuer "$ISSUER" \
  --subject "system:serviceaccount:velero:velero" --audiences "api://AzureADTokenExchange"
```
> **Note:** the Velero identity needs **both** `Storage Blob Data Contributor`
> **and** `Reader`. With only the data-plane role the BackupStorageLocation
> validates as Available but backups stall on a silent 403.

### A4. Fill the placeholders, then commit + push

First gather the values the manifests need (the ESO and GitHub client-ids come
from doc 02 and A1; the rest are read back here):

```bash
ESO_CLIENT_ID=$(az identity show -g webservices-infra -n id-eso-webservices --query clientId -o tsv)
VELERO_CLIENT_ID=$(az identity show -g webservices-infra -n id-velero-webservices --query clientId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
NODE_RESOURCE_GROUP=$(az aks show -g $CLUSTER_RG -n $CLUSTER --query nodeResourceGroup -o tsv)
# BACKUP_STORAGE_ACCOUNT is $ACCOUNT (stwsv2backup); GITHUB_CLIENT_ID is from the A1 OAuth app;
# KEY_VAULT_NAME is your durable vault (kv-scouterna-webservices).
```

Now fill the `<...>` placeholders in the manifests with the values above (the
`<PLACEHOLDER>` in each file takes the matching `$PLACEHOLDER`). They are Azure
identifiers, not secrets — safe to commit:

- `k8s/argocd/infra-apps/external-secrets.yaml` → `<ESO_CLIENT_ID>` = `$ESO_CLIENT_ID`.
- `k8s/infra-manifest/monitoring/kube-prometheus-stack-values.yaml` →
  `<GITHUB_CLIENT_ID>` = the Client ID from the A1 OAuth app.
- `k8s/argocd/infra-apps/velero.yaml` → `<VELERO_CLIENT_ID>` = `$VELERO_CLIENT_ID`,
  `<BACKUP_STORAGE_ACCOUNT>` = `$ACCOUNT`, `<SUBSCRIPTION_ID>` = `$SUBSCRIPTION_ID`,
  `<NODE_RESOURCE_GROUP>` = `$NODE_RESOURCE_GROUP`.
- `k8s/infra-manifest/external-secrets/clustersecretstore.yaml` → the `vaultUrl`
  host `<KEY_VAULT_NAME>` = your durable vault (`kv-scouterna-webservices`).

**Then commit and push.** ArgoCD syncs from the Git repo, not your working tree —
an unpushed edit has no effect. Push before you apply the root app in Part B (and
push again whenever you change a filled-in value later):

```bash
git commit -am "Fill infra client-ids / vault URL"
git push
```

---

## Part B — Install ArgoCD and apply the root app

```bash
kubectl create namespace argocd
# --server-side is REQUIRED: the applicationsets CRD exceeds the client-side
# last-applied-configuration annotation size limit and a plain apply fails on it.
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.5/manifests/install.yaml

# Wait for ArgoCD to be ready before applying the root app. The
# application-controller (a StatefulSet) is what reconciles the root app, so wait
# for it too — not just the server. Each command blocks until its rollout is done.
kubectl -n argocd rollout status deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd rollout status statefulset/argocd-application-controller

kubectl apply -f k8s/argocd/projects/            # infra + apps-dev + apps-prod
kubectl apply -f k8s/argocd/infra-root-app.yaml  # app-of-apps; recurses infra-apps/ by sync-wave
```

After you apply the root app, it takes a minute or two for ArgoCD to discover the
child apps and start syncing them wave by wave — `kubectl -n argocd get applications`
showing nothing (or apps briefly `Missing`/`OutOfSync`) in the first moments is
normal, not a failure. Watch them progress with the verify commands below.

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
[onboarding.md](onboarding.md)). Grafana uses **GitHub OAuth** (A1).

---

## Notes (from real ArgoCD bring-ups)

- **Public repo needs no credential.** For a private repo, register an ArgoCD
  repository credential whose `url` scheme **matches** the Application `repoURL`
  (an `https://` repoURL needs an HTTPS/token credential, not an SSH deploy key),
  else `authentication required: Repository not found`.
- **Put the bootstrap secrets in the Key Vault first (Part A2).** They are not in
  Git; ESO materializes them. If the KV values are missing, the `ExternalSecret`s
  stay `SecretSyncedError` and their consumers crash-loop until you set them.
- **Expected non-"Synced/Healthy" that are fine:** `cloudnative-pg` shows
  `Degraded` when no Postgres `Cluster` CRs exist yet (operator idle);
  `cert-manager` and `thanos` can sit `OutOfSync/Healthy` on benign Helm/CRD
  field drift. Pods are Running in all three.
- **CRD name clash:** both Velero and CloudNativePG define a `backups` CRD — use
  the fully-qualified `backups.velero.io` / `backups.postgresql.cnpg.io`.
