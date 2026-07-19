#!/usr/bin/env bash
# Provision per-project CloudNativePG backup access to Azure Blob.
#
# Creates a dedicated container `cnpg-<project>` in the durable backup storage
# account, so each project's Postgres backups are isolated in their own
# container. Auth is via the storage-account key (delivered to the cluster by
# ESO from Key Vault) — see the reference manifest in
# k8s/projects/_template/infra/database.yaml.example.
#
# (Workload Identity for CNPG backups is a future improvement; the plugin's
# Managed-Identity path is currently finicky with multiple node identities.)
#
# Usage:
#   scripts/onboard-cnpg-backup.sh <project>
# Example:
#   scripts/onboard-cnpg-backup.sh platsbank
set -euo pipefail

PROJECT="${1:?project name required}"

# --- Environment (adjust to your deployment) ---
INFRA_RG="webservices-infra"
STORAGE_ACCOUNT="stwsv2backup"
CONTAINER="cnpg-${PROJECT}"

echo "==> container ${CONTAINER} in ${STORAGE_ACCOUNT}"
az storage container create --account-name "$STORAGE_ACCOUNT" --auth-mode login \
  --name "$CONTAINER" >/dev/null

echo ""
echo "Container ready. Next:"
echo "  1. Ensure the storage account key is in Key Vault (secret"
echo "     'backup-storage-account-key'); ESO materializes it in the namespace."
echo "  2. In the project's manifests (copy the reference example):"
echo "       ObjectStore.spec.configuration.destinationPath:"
echo "         https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}"
echo "  3. Reference the plugin in Cluster.spec.plugins and add a ScheduledBackup."
