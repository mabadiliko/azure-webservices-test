# 02 — Durable Key Vault + Workload Identity for ESO

Sets up centralized secrets. The Key Vault and its managed identity live in a
**separate, durable resource group** (e.g. `webservices-infra`) so they survive
cluster teardown/rebuild. Only the *federated credential* is cluster-specific.

Prerequisite: doc 01 done; you have the cluster's OIDC issuer URL.

## 1. Create the durable RG + Key Vault

```bash
az group create -n webservices-infra -l swedencentral
az deployment group create -g webservices-infra \
  -f infra/keyvault.bicep -p keyVaultName=<globally-unique-name>
```

**Gotcha:** KV names are globally unique across ALL Azure tenants, and
`az keyvault check-name` is optimistic (can report a taken name as available).
A generic name like `kv-webservices` was already taken → deploy failed with
`VaultAlreadyExists`. Use a distinctive namespaced name (e.g. one that includes
the org). The vault uses **RBAC authorization** + **purge protection** (see the Bicep).

## 2. Managed identity + role grant

```bash
az identity create -g webservices-infra -n id-eso-webservices -l swedencentral
PRINCIPAL=$(az identity show -g webservices-infra -n id-eso-webservices --query principalId -o tsv)
CLIENT_ID=$(az identity show -g webservices-infra -n id-eso-webservices --query clientId  -o tsv)
KV_ID=$(az keyvault show -n <kv-name> --query id -o tsv)

az role assignment create --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$KV_ID"
```

## 3. Federate the identity to the ESO ServiceAccount

Binds the identity to the cluster's OIDC issuer for the SA ESO runs as.
**Per-cluster:** on a rebuild, add a new federated credential for the new
cluster's issuer (the identity + role grant persist).

```bash
ISSUER="<cluster oidc issuer url from doc 01>"
az identity federated-credential create -g webservices-infra --identity-name id-eso-webservices \
  -n eso-<cluster> \
  --issuer "$ISSUER" \
  --subject "system:serviceaccount:external-secrets:external-secrets" \
  --audiences "api://AzureADTokenExchange"
```

## 4. Let yourself write secrets (RBAC vault)

Under RBAC even the vault creator needs an explicit role to read/write secrets:

```bash
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Key Vault Secrets Officer" --scope "$KV_ID"
# wait ~20s for RBAC to propagate before the first secret write
```

`$CLIENT_ID` is used when installing ESO (doc 03). ESO install + the
`ClusterSecretStore` + a validation `ExternalSecret` are in doc 03.
