# Installing the Webservices v2 cluster

This is the full runbook: from an empty subscription to a running, GitOps-managed
cluster. It is **one continuous shell session** — work top to bottom in a single
terminal. The variables you set in §0 stay live through every later command, so
they are never repeated; a command near the end still uses a variable set at the
start.

The order follows the **dependencies**, not the topic:

1. **Prerequisites** that need nothing from the cluster (quota, GitHub OAuth app,
   Key Vault, identities, secrets, backup storage) — done first, before you spend
   anything on a cluster.
2. **Provision** the cluster.
3. **Cluster-derived wiring** — the few things that need values only a running
   cluster produces (its OIDC issuer, its node resource group).
4. **Bootstrap ArgoCD**, which brings up every common service from Git.

Prerequisite tooling: `az` logged in and pointed at the right subscription
(`az account set --subscription <id>`); `bicep` CLI **0.44.1+** (older versions
can't type-check the `2026-03-01` AKS API — `az bicep upgrade`); `kubectl`; `git`.
The common services are installed **entirely by ArgoCD** — there is no manual
`helm install`.

---

## 0. Environment variables (set these once)

Set these at the top of your shell session. Defaults are the real Scouterna
production values; override any of them for a test deploy (e.g. a throwaway
`CLUSTER`/`CLUSTER_RG`). Everything below refers to these — they are never
re-declared.

```bash
# --- Cluster ---
CLUSTER=webservices-v2            # AKS cluster name (also the dnsPrefix)
CLUSTER_RG=webservices-v2         # resource group that will hold the cluster
LOCATION=swedencentral            # Azure region for everything here

# --- Durable infrastructure (survives cluster teardown/rebuild) ---
INFRA_RG=webservices-infra        # RG holding the Key Vault, identities, backup storage
KEY_VAULT_NAME=kv-scouterna-webservices       # Key Vault name (globally unique, 3-24 chars)
BACKUP_STORAGE_ACCOUNT=stwsv2backup              # backup storage account (globally unique, 3-24 lowercase alnum)

# --- Identities (in $INFRA_RG; persist across rebuilds) ---
ESO_IDENTITY=id-eso-webservices       # managed identity ESO authenticates as
VELERO_IDENTITY=id-velero-webservices # managed identity Velero authenticates as
FEDCRED_ESO=eso-$CLUSTER              # ESO federated-credential name (one per cluster)
FEDCRED_VELERO=velero-$CLUSTER        # Velero federated-credential name (one per cluster)

# --- DNS / access ---
HOST=wsv2test.j26.se        # DNS suffix for the infra apps (Grafana, Headlamp, ...)

# --- Subscription (set EXPLICITLY — see the warning below) ---
SUBSCRIPTION_ID=<the-target-subscription-id>
az account set --subscription "$SUBSCRIPTION_ID"
```

> ⚠️ **Pin the subscription before anything else.** `az` remembers a default
> subscription across sessions, and it may not be the one you think — a login for
> unrelated work silently changes it. Every command below acts on whatever
> subscription is active, including the destructive ones (`az group delete` in a
> teardown). Deploying — or deleting — in the wrong subscription is the single
> most damaging mistake available here, so set it explicitly rather than deriving
> it from the current login, then **verify** you are where you intend to be:
>
> ```bash
> az account show --query "{name:name, id:id}" -o table   # is this the right one?
> az group list --query "[].name" -o tsv | head           # do these look familiar?
> ```
>
> Re-run the `az account set` line whenever you open a new terminal for this
> runbook.

> A few values are read from the *running cluster* later (its OIDC issuer, its
> node resource group) and are set into variables at that point (§7, §8).

---

# Part 1 — Prerequisites (no cluster needed)

Everything in Part 1 can be done before the cluster exists. On a **rebuild**, the
durable pieces ($INFRA_RG, $KEY_VAULT_NAME, the identities, $BACKUP_STORAGE_ACCOUNT, the secrets) usually
already exist and these steps are idempotent no-ops — safe to re-run.

## 1. vCPU quota (do this FIRST — it blocks the deploy)

A fresh subscription in `$LOCATION` typically has **0** quota for the VM family we
use and a low total-regional cap. Check and raise before deploying.

```bash
SCOPE="subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Compute/locations/$LOCATION"
az quota show --resource-name standardDASv5Family --scope "$SCOPE" --query '{name:name.value, limit:properties.limit.value}' -o table
az quota show --resource-name cores              --scope "$SCOPE" --query '{name:name.value, limit:properties.limit.value}' -o table
```

The bare `-o table` prints only the `Name` column — the limit lives in a nested
field it drops; the `--query` above pulls out the number. One `Standard_D4as_v5`
node needs **4 vCPU**; if both limits are already ≥ 4 (with regional headroom) you
can skip ahead. A limit of **0** (common on a fresh subscription) blocks the
deploy — raise it (values are examples; leave headroom for a 2nd node + surge):

```bash
az quota update --resource-name standardDASv5Family --scope "$SCOPE" --limit-object value=16 --resource-type dedicated
az quota update --resource-name cores               --scope "$SCOPE" --limit-object value=32 --resource-type dedicated
```

**Gotchas:**
- The cluster uses **`Standard_D4as_v5`** (AMD, `standardDASv5Family`). The Intel
  `Standard_D4s_v5` (`standardDSv5Family`) was tried first but the direct quota
  API **refuses** that family here (`QuotaNotAvailableForResource`) — AMD is the
  grantable one. D4as_v5 is equivalent (4 vCPU / 16 GB).
- `az quota update` needs the `quota` CLI extension (`az extension add --name quota`).
- On some subscriptions (notably **Sponsorship**) `az quota update` is rejected —
  raise it from the portal instead: *Subscription → Usage + quotas → find the
  family → Request increase*.
- Ephemeral OS disk is **not supported** on D4as_v5 — we use a managed OS disk
  (already set in `infra/aks.bicep`).

## 2. GitHub OAuth apps (Grafana login + Dex SSO)

The cluster uses GitHub as its identity provider in **two independent places**, so
you need **two separate GitHub OAuth Apps** (they have different callback URLs and
cannot share one registration):

| OAuth App | Used by | Why separate |
|---|---|---|
| **Grafana** | Grafana's own `auth.github` login | Callback `…/login/github` |
| **Dex** | Dex → Headlamp *and* `kubectl` SSO | Callback `…/callback`; Dex fronts all cluster auth |

Both are restricted to the **Scouterna** org. Do this before writing the Key Vault
secrets (§6) so both client secrets are ready.

### 2a. Grafana OAuth app

Daily Grafana login is **GitHub OAuth**, with GitHub teams → Grafana roles (config
in `kube-prometheus-stack-values.yaml`, `grafana.ini` `auth.github`). The admin
password is **break-glass only**.

1. Create a **GitHub OAuth App** (Scouterna org → Settings → Developer settings →
   OAuth Apps): Homepage `https://grafana.$HOST`, callback
   `https://grafana.$HOST/login/github`.
2. Capture its **Client ID** and **Client Secret** — the ID fills a Grafana
   manifest (§9), the secret goes into Key Vault (§6):
   ```bash
   GITHUB_CLIENT_ID=<client-id-from-the-grafana-oauth-app>
   GITHUB_CLIENT_SECRET=<client-secret-from-the-grafana-oauth-app>
   ```
3. Later, set `role_attribute_path` in the Grafana values to the real Scouterna
   team slugs.

### 2b. Dex OAuth app (developer SSO for Headlamp + kubectl)

Dex is the cluster's OIDC provider: developers log in to **Headlamp** and get
**`kubectl` credentials** as their GitHub identity, with GitHub teams mapped to
RBAC. Without this, Headlamp and `kubectl` SSO do not work. See
[onboarding.md](onboarding.md) section B.

1. Create a **second GitHub OAuth App**: Homepage `https://dex.$HOST`, callback
   **`https://dex.$HOST/callback`**.
2. Capture its Client ID and Client Secret, plus invent a random shared secret for
   the Dex↔Headlamp static client:
   ```bash
   DEX_GITHUB_CLIENT_ID=<client-id-from-the-dex-oauth-app>
   DEX_GITHUB_CLIENT_SECRET=<client-secret-from-the-dex-oauth-app>
   DEX_HEADLAMP_CLIENT_SECRET=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
   ```
   `DEX_GITHUB_CLIENT_ID` fills a Dex manifest (§9); the two secrets go into Key
   Vault (§6). The Headlamp secret is **not** issued by GitHub — it is a value you
   invent, shared between Dex's `headlamp` static client and Headlamp itself.

> Deferring GitHub login? Set the variables to placeholder strings now — the
> cluster comes up fine, and only the GitHub logins stay inactive until you set the
> real values, re-write the Key Vault secrets (§6), re-fill the manifests (§9), and
> re-push. Note that deferring the **Dex** app also defers `kubectl` SSO, so you
> will be relying on the admin kubeconfig until it is configured.

## 3. Durable Key Vault

The Key Vault lives in the **durable** resource group ($INFRA_RG) so it survives
cluster teardown/rebuild.

```bash
az group create -n $INFRA_RG -l $LOCATION
az deployment group create -g $INFRA_RG -f infra/keyvault.bicep -p keyVaultName=$KEY_VAULT_NAME
```

The `-g $INFRA_RG` on the deployment is what places the vault in that resource
group — the Bicep names no RG itself. The vault inherits the RG's location
(`keyvault.bicep` uses `resourceGroup().location`), so the RG's `-l $LOCATION` puts
the vault in the right region too.

> **Gotcha:** Key Vault names are globally unique across ALL Azure tenants, and
> `az keyvault check-name` is optimistic (can report a taken name as available). A
> generic name like `kv-webservices` was already taken → deploy failed with
> `VaultAlreadyExists`. Use a distinctive namespaced name. The vault uses **RBAC
> authorization** + **purge protection** (see the Bicep).

## 4. Managed identities + Key Vault role grant

Two managed identities live in $INFRA_RG and persist across rebuilds: one for ESO
(reads Key Vault), one for Velero (writes backups). Create them and grant ESO read
access to the vault:

```bash
KEY_VAULT_ID=$(az keyvault show -n $KEY_VAULT_NAME --query id -o tsv)

# ESO identity — reads secrets from the Key Vault
az identity create -g $INFRA_RG -n $ESO_IDENTITY -l $LOCATION
ESO_PRINCIPAL=$(az identity show -g $INFRA_RG -n $ESO_IDENTITY --query principalId -o tsv)
az role assignment create --assignee-object-id "$ESO_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$KEY_VAULT_ID"

# Velero identity — created now; its role grants (on the backup storage) are in §5
az identity create -g $INFRA_RG -n $VELERO_IDENTITY -l $LOCATION
```

The federated credentials that bind these identities to the *cluster* come later
(§7) — they need the cluster's OIDC issuer, which doesn't exist yet.

## 5. Backup storage account (Velero + CNPG)

Backups go to a durable, external storage account in $INFRA_RG (see
`infra/backup-storage.bicep`). Storage account names are **globally unique, 3–24
chars, lowercase alphanumeric only** (no hyphens). On a rebuild it usually already
exists — the deployment is idempotent.

```bash
az deployment group create -g $INFRA_RG -f infra/backup-storage.bicep -p storageAccountName=$BACKUP_STORAGE_ACCOUNT

VELERO_PRINCIPAL=$(az identity show -g $INFRA_RG -n $VELERO_IDENTITY --query principalId -o tsv)
STORAGE_ID=$(az storage account show -g $INFRA_RG -n $BACKUP_STORAGE_ACCOUNT --query id -o tsv)
az role assignment create --assignee-object-id "$VELERO_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$STORAGE_ID"   # data plane
az role assignment create --assignee-object-id "$VELERO_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Reader" --scope "$STORAGE_ID"                          # mgmt plane (REQUIRED)
```

> **Note:** the Velero identity needs **both** `Storage Blob Data Contributor`
> **and** `Reader`. With only the data-plane role the BackupStorageLocation
> validates as Available but backups stall on a silent 403.

## 6. Write the bootstrap secrets to Key Vault

**Key Vault is the source of truth.** ESO's `ExternalSecret`s (in
`k8s/infra-manifest/external-secrets/`) materialize these into the cluster, so a
**rebuild recreates them automatically** — you never hand-create in-cluster
secrets.

First let yourself write secrets (under an RBAC vault even the creator needs an
explicit role), then set the four secrets. The GitHub client secret is the real
value from §2.

```bash
# Grant yourself write access (once), then wait for RBAC to propagate
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Key Vault Secrets Officer" --scope "$KEY_VAULT_ID"
sleep 20

az keyvault secret list --vault-name $KEY_VAULT_NAME --query "[].name" -o tsv   # what already exists (durable vault)

az keyvault secret set --vault-name $KEY_VAULT_NAME --name minio-root-user             --value admin
az keyvault secret set --vault-name $KEY_VAULT_NAME --name minio-root-password         --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name grafana-admin-password      --value "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name grafana-github-client-secret --value "$GITHUB_CLIENT_SECRET"

# Dex SSO (§2b) — without these, Headlamp and kubectl SSO do not work
az keyvault secret set --vault-name $KEY_VAULT_NAME --name dex-github-client-secret   --value "$DEX_GITHUB_CLIENT_SECRET"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name dex-headlamp-client-secret --value "$DEX_HEADLAMP_CLIENT_SECRET"
```

**Sealed Secrets sealing key (do this once; it must survive every rebuild).** The
Sealed Secrets controller would otherwise generate its own RSA key on first start
and self-rotate it — a rebuild would then mint a *new* key and make every
committed `SealedSecret` undecryptable. So we generate one long-lived key pair,
store it in the durable Key Vault, and let ESO re-materialize it on each rebuild
*before* the controller starts (which adopts it instead of generating a fresh
one). Auto-rotation is disabled in the controller values (`keyrenewperiod "0"`).
Generate and store the pair **only if it isn't already in the vault** (a rebuild
must reuse the existing one):

```bash
if ! az keyvault secret show --vault-name $KEY_VAULT_NAME --name sealed-secrets-tls-key >/dev/null 2>&1; then
  openssl req -x509 -nodes -newkey rsa:4096 -keyout /tmp/ss-tls.key -out /tmp/ss-tls.crt \
    -subj "/CN=sealed-secret/O=sealed-secret" -days 3650
  az keyvault secret set --vault-name $KEY_VAULT_NAME --name sealed-secrets-tls-crt --file /tmp/ss-tls.crt
  az keyvault secret set --vault-name $KEY_VAULT_NAME --name sealed-secrets-tls-key --file /tmp/ss-tls.key
  shred -u /tmp/ss-tls.key /tmp/ss-tls.crt    # never leave the private key on disk
fi
```

The `ExternalSecret`s then produce the in-cluster secrets consumers expect:
`minio-root`, `loki-minio`, `thanos-objstore` (composed from the MinIO values),
`grafana-admin`, `grafana-github-oauth`, `dex-oauth` (Dex's GitHub + Headlamp
client secrets), `headlamp-oidc` (the same Headlamp secret, in its own namespace),
and the Sealed Secrets `sealed-secrets-key` (a `kubernetes.io/tls` Secret labelled
`active`, which the controller adopts).

> **How the ordering works (no hand-seeding):** sync-waves are arranged so secrets
> exist before the things that use them. The ESO operator is wave 0; the
> `ClusterSecretStore` + `ExternalSecret`s (the `external-secrets-config` app) are
> wave 1, alongside MinIO and ahead of wave-2 monitoring. If a consumer starts a
> moment before its secret is materialized it crash-loops and **self-heals** the
> instant ESO reconciles the value. A rebuild recreates every secret from the Key Vault.

> **Why infra secrets stay on KV/ESO (not Sealed Secrets):** the cluster also runs
> Sealed Secrets (the self-service, commit-safe path for *projects*), so it's fair
> to ask why these infra secrets aren't sealed instead. They shouldn't be, for
> three reasons: **(1) dependency direction** — Sealed Secrets is *built on top of*
> KV/ESO here (its sealing key is itself an `ExternalSecret` from the Key Vault),
> so sealing an infra secret wouldn't remove the KV dependency, only add the
> controller as an extra hop that must be healthy. **(2) Bootstrap ordering** —
> these secrets are consumed in waves 1–2; the sealed-secrets controller is itself
> wave 2, so a sealed infra secret would gain a longer, more fragile dependency
> chain than reading straight from KV. **(3) Value handling** — the random secrets
> (`minio-*`, `grafana-admin-password`) are generated with `openssl rand` directly
> into KV and no human ever sees the plaintext; the GitHub client secrets are
> external values you must custody centrally and rotate. Sealing either would mean
> handling the raw plaintext locally at `kubeseal` time — a downgrade. So: **infra
> secrets → KV/ESO** (early, durable, controller-independent); **project secrets →
> Sealed Secrets or KV/ESO**, the project's choice (see onboarding.md "Secrets").

---

# Part 2 — Provision the cluster

## 7a. Review params + deploy

`infra/env/webservices.bicepparam` holds the cluster shape (name, region, VM size,
node count, SLA tier). It is committed and holds no secrets. If you changed any
`$CLUSTER`/`$LOCATION` above for a test, edit the param file to match.

```bash
az group create -n $CLUSTER_RG -l $LOCATION
az deployment group what-if -g $CLUSTER_RG -f infra/main.bicep -p infra/env/webservices.bicepparam   # preview, creates nothing
az deployment group create  -g $CLUSTER_RG -f infra/main.bicep -p infra/env/webservices.bicepparam
```

`$CLUSTER_RG` is the cluster's resource group, distinct from the durable
`$INFRA_RG`. AKS also auto-creates a *node* resource group (named
`MC_<cluster-rg>_<cluster>_<location>` by Azure) for the VMs/disks/LB; you don't
create it, and `az group delete -g $CLUSTER_RG` removes both.

A good `what-if` ends with `Resource changes: 1 to create.` and a
`+ Microsoft.ContainerService/managedClusters/<cluster>` block. Bicep also lints
`no-unused-params` for `deployAcrPull`/`deployKeyVault` — harmless, they're
declared for later. Deploy takes ~5–10 min.

## 7b. Get credentials + verify

```bash
az aks get-credentials -g $CLUSTER_RG -n $CLUSTER --admin --file ./.kube-webservices   # gitignored (.kube-*)
export KUBECONFIG=$PWD/.kube-webservices
kubectl get nodes -o wide                        # Ready, Standard_D4as_v5, AzureLinux
kubectl -n kube-system get pods | grep cilium    # cilium + cilium-operator Running (eBPF dataplane)
```

The `--admin` kubeconfig is the infra bootstrap credential.

---

# Part 3 — Cluster-derived wiring

These steps need values only the *running* cluster produces. Fetch them into
variables now.

## 8. Federate the identities to the cluster's OIDC issuer

The cluster's OIDC issuer is **per-cluster** — a rebuild mints a new one, so this
is the one identity step that must be redone each rebuild (the identities and role
grants from Part 1 persist). Both ESO and Velero bind to the same issuer.

```bash
ISSUER=$(az aks show -g $CLUSTER_RG -n $CLUSTER --query oidcIssuerProfile.issuerUrl -o tsv)

az identity federated-credential create -g $INFRA_RG --identity-name $ESO_IDENTITY \
  -n $FEDCRED_ESO --issuer "$ISSUER" \
  --subject "system:serviceaccount:external-secrets:external-secrets" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create -g $INFRA_RG --identity-name $VELERO_IDENTITY \
  -n $FEDCRED_VELERO --issuer "$ISSUER" \
  --subject "system:serviceaccount:velero:velero" \
  --audiences "api://AzureADTokenExchange"
```

## 9. Fill the manifest placeholders, then commit + push

Gather the remaining values, then fill the `<...>` placeholders in the manifests.
These are Azure identifiers, not secrets — safe to commit.

```bash
ESO_CLIENT_ID=$(az identity show -g $INFRA_RG -n $ESO_IDENTITY --query clientId -o tsv)
VELERO_CLIENT_ID=$(az identity show -g $INFRA_RG -n $VELERO_IDENTITY --query clientId -o tsv)
NODE_RESOURCE_GROUP=$(az aks show -g $CLUSTER_RG -n $CLUSTER --query nodeResourceGroup -o tsv)
echo "ESO_CLIENT_ID=$ESO_CLIENT_ID"
echo "VELERO_CLIENT_ID=$VELERO_CLIENT_ID"
echo "NODE_RESOURCE_GROUP=$NODE_RESOURCE_GROUP"
echo "SUBSCRIPTION_ID=$SUBSCRIPTION_ID  BACKUP_STORAGE_ACCOUNT=$BACKUP_STORAGE_ACCOUNT  KEY_VAULT_NAME=$KEY_VAULT_NAME"
echo "GITHUB_CLIENT_ID=$GITHUB_CLIENT_ID           # Grafana app, from §2a"
echo "DEX_GITHUB_CLIENT_ID=$DEX_GITHUB_CLIENT_ID   # Dex app, from §2b"
```

Fill each `<PLACEHOLDER>` with the matching value:

- `k8s/argocd/infra-apps/external-secrets.yaml` → `<ESO_CLIENT_ID>` = `$ESO_CLIENT_ID`.
- `k8s/infra-manifest/monitoring/kube-prometheus-stack-values.yaml` →
  `<GITHUB_CLIENT_ID>` = `$GITHUB_CLIENT_ID` (the **Grafana** app, §2a).
- `k8s/infra-manifest/dex/values.yaml` → `<GITHUB_CLIENT_ID>` =
  `$DEX_GITHUB_CLIENT_ID` (the **Dex** app, §2b). ⚠️ Both files use the same
  placeholder name but take **different** client ids — filling either with the
  other's value breaks that login.
- `k8s/argocd/infra-apps/velero.yaml` → `<VELERO_CLIENT_ID>` = `$VELERO_CLIENT_ID`,
  `<BACKUP_STORAGE_ACCOUNT>` = `$BACKUP_STORAGE_ACCOUNT`, `<SUBSCRIPTION_ID>` = `$SUBSCRIPTION_ID`,
  `<NODE_RESOURCE_GROUP>` = `$NODE_RESOURCE_GROUP`.
- `k8s/infra-manifest/external-secrets/clustersecretstore.yaml` → the `vaultUrl`
  host `<KEY_VAULT_NAME>` = `$KEY_VAULT_NAME`.

**Then commit and push.** ArgoCD syncs from the Git repo, not your working tree —
an unpushed edit has no effect. Push before applying the root app (§10), and again
whenever you change a filled-in value later:

```bash
git commit -am "Fill infra client-ids / vault URL"
git push
```

> **Don't miss the `clustersecretstore.yaml` `vaultUrl`.** It's a separate file
> from the client-ids and easy to skip — a left-over `<KEY_VAULT_NAME>` there is
> the most common cause of a stalled bring-up (see Troubleshooting).

---

# Part 4 — Bootstrap ArgoCD

## 10. Install ArgoCD and apply the root app

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

After you apply the root app it takes a minute or two for ArgoCD to discover the
child apps and start syncing them wave by wave — `get applications` showing
nothing (or apps briefly `Missing`/`OutOfSync`) at first is normal.

The root app brings up every common service in dependency order:

| Wave | Services |
|---|---|
| 0 | cluster-infra (StorageClasses + ClusterIssuers), cert-manager, external-secrets (ESO operator), gateway-api-crds |
| 1 | traefik, minio, minio-buckets, cloudnative-pg, external-secrets-config (ClusterSecretStore + ExternalSecrets), barman-cloud-plugin, sealed-secrets-key (durable sealing key ExternalSecret) |
| 2 | monitoring (kube-prometheus-stack + Loki + Alloy), dex, sealed-secrets (controller — after its key) |
| 3 | thanos, headlamp |
| 4 | governance (alerts + dashboard), velero |

## 11. Verify + DNS

```bash
kubectl -n argocd get applications                  # sync/health of every service
kubectl -n traefik get svc traefik                  # note EXTERNAL-IP (TWO IPs — v4 and v6)
kubectl -n velero get backupstoragelocation default # -> Available
```

Give it a few minutes and re-run `get applications` — apps should progress to
`Synced`/`Healthy` wave by wave. Then point the infra-app DNS (`*.$HOST`) at the
Traefik LoadBalancer.

If some apps don't come up, see **Troubleshooting** below — the most common cause
is an unfilled placeholder from §9.

### Dual-stack DNS

The cluster is dual-stack, so the Traefik LoadBalancer has **both** an IPv4 and an
IPv6 public IP. `*.$HOST` needs an **A** record and an **AAAA** record — publishing
only the A record leaves the cluster reachable over IPv4 only, regardless of the
cluster's IPv6 support.

Grab them separately (order within `.status` is not guaranteed, so select by family
rather than by index):

```bash
LB_IPS=$(kubectl -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[*].ip}' | tr ' ' '\n')
LB_V4=$(echo "$LB_IPS" | grep -v ':' | head -1)
LB_V6=$(echo "$LB_IPS" | grep ':'    | head -1)
echo "A    *.$HOST -> $LB_V4"
echo "AAAA *.$HOST -> $LB_V6"
```

Both records must exist before cert-manager can complete HTTP-01 challenges from
IPv6-only validation paths.

> **IPv6 is fixed at cluster creation.** `ipFamilies` in `infra/aks.bicep` is
> immutable — an existing IPv4-only cluster cannot be converted to dual-stack in
> place. If you inherit a single-stack cluster, it must be rebuilt.

---

## ArgoCD access — pure GitOps, no exposed GUI

ArgoCD is operated **declaratively**: all config is in Git, changes happen by
commit → auto-sync. There is deliberately **no ArgoCD ingress and no GUI login** —
smaller attack surface, matches the "everything in Git" model.

- **Observe** with `kubectl -n argocd get applications`.
- **Debug** a stuck sync via a temporary
  `kubectl -n argocd port-forward svc/argocd-server 8080:443`, logging in with the
  break-glass admin (`kubectl -n argocd get secret argocd-initial-admin-secret
  -o jsonpath='{.data.password}' | base64 -d`). Not for daily use.

If a shared dashboard is ever wanted, expose `argocd-server` via Traefik + GitHub
OAuth via ArgoCD's bundled Dex (Scouterna org, teams → RBAC). Not done here by
choice.

**Other infra UIs:** Headlamp uses **GitHub SSO via Dex** (§2b) — a developer logs
in as their GitHub identity and sees only the namespaces their RBAC allows; the
same Dex client also issues `kubectl` credentials. There are no ServiceAccount
tokens to hand out (AKS caps them at 24h, which is why this model was adopted).
See [onboarding.md](onboarding.md) section B. Grafana uses its own **GitHub
OAuth** app (§2a).

---

## Troubleshooting (from real bring-ups)

- **Unfilled placeholder = stalled bring-up.** If apps don't reach
  `Synced`/`Healthy`, first check every §9 placeholder was filled, in the right
  file, with the right value — all four files. It's easy to fill the client-ids
  and miss the `vaultUrl` in `clustersecretstore.yaml`.
- **Store `Ready` but ExternalSecrets `SecretSyncedError`.** A misleading symptom:
  the `ClusterSecretStore` can report `Ready`/`store validated` while still
  pointing at a placeholder vault — Workload-Identity validation doesn't do a live
  fetch — so the `ExternalSecret`s fail with `SecretSyncedError` ("could not get
  secret data from provider") even though the store looks healthy. Check it:
  ```bash
  kubectl get clustersecretstore azure-kv -o jsonpath='{.spec.provider.azurekv.vaultUrl}{"\n"}'
  kubectl get externalsecrets -A     # READY should become True once the URL is real
  ```
  After correcting a value, commit + push, then let ArgoCD re-sync (or
  `kubectl -n external-secrets rollout restart deploy/external-secrets` to force
  ESO to re-evaluate the store immediately).
- **Public repo needs no credential.** For a *private* repo, register an ArgoCD
  repository credential whose `url` scheme **matches** the Application `repoURL`
  (an `https://` repoURL needs an HTTPS/token credential, not an SSH deploy key),
  else `authentication required: Repository not found`.
- **Expected non-"Synced/Healthy" that are fine:** `cloudnative-pg` shows
  `Degraded` when no Postgres `Cluster` CRs exist yet (operator idle);
  `cert-manager`, `thanos`, `external-secrets-config` can sit `OutOfSync/Healthy`
  on benign Helm/CRD field drift. Pods are Running.
- **CRD name clash:** both Velero and CloudNativePG define a `backups` CRD — use
  the fully-qualified `backups.velero.io` / `backups.postgresql.cnpg.io`.
```
