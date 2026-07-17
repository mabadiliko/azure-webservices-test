# 01 — Provision the AKS cluster

Everything here is `az` + Bicep. Prerequisite: `az` logged in and pointed at the
right subscription (`az account set --subscription <id>`), `bicep` CLI **0.44.1+**
(older versions can't type-check the `2026-03-01` AKS API — `az bicep upgrade`).

## 1. vCPU quota (do this FIRST — it blocks the deploy)

A fresh subscription in `swedencentral` typically has **0** quota for the VM
family we use and a low total-regional cap. Check and raise before deploying.

```bash
SCOPE="subscriptions/<sub-id>/providers/Microsoft.Compute/locations/swedencentral"
az quota show --resource-name standardDASv5Family --scope "$SCOPE" -o table
az quota show --resource-name cores              --scope "$SCOPE" -o table
```

Raise them (values are examples — 1 node = 4 vCPU; leave headroom for a 2nd
node + upgrade surge):

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
- Ephemeral OS disk is **not supported** on D4as_v5 — we use a managed OS disk
  (already set in `infra/aks.bicep`).

## 2. Review the param file

`infra/env/webservices.bicepparam` holds the cluster shape (name, region, VM
size, node count, SLA tier). It is committed and holds no secrets — the Azure
subscription is selected via `az account set` / the target resource group, not
in the param file. Edit it if you want to change any of those values.

## 3. Deploy

```bash
az group create -n <rg> -l swedencentral
az deployment group what-if -g <rg> -f infra/main.bicep -p infra/env/webservices.bicepparam   # preview, creates nothing
az deployment group create  -g <rg> -f infra/main.bicep -p infra/env/webservices.bicepparam
```

`what-if` validates against the live provider — it is where quota/size problems
surface before you spend. Deploy takes ~5–10 min.

## 4. Get credentials + verify

```bash
az aks get-credentials -g <rg> -n webservices-v2 --admin --file ./.kube-webservices   # gitignored (.kube-*)
export KUBECONFIG=$PWD/.kube-webservices
kubectl get nodes -o wide                 # Ready, Standard_D4as_v5, AzureLinux
kubectl -n kube-system get pods | grep cilium   # cilium + cilium-operator Running (eBPF dataplane)
```

The `--admin` kubeconfig is the infra bootstrap credential.

Optionally confirm the OIDC issuer is enabled (doc 02 fetches it itself when it
sets up the Key Vault federation, so there's nothing to copy down here):

```bash
az aks show -g <rg> -n webservices-v2 --query oidcIssuerProfile.issuerUrl -o tsv
```
