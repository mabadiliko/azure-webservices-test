// =============================================================================
// Params for the "webservices-v2" AKS cluster.
//
// This file is committed — it holds no secrets, only cluster shape. The Azure
// subscription is selected out-of-band (`az account set`) / by the target
// resource group, so no subscription ID lives here. Edit these values to
// change the cluster, then:
//   az deployment group create -g <rg> -f infra/main.bicep -p infra/env/webservices.bicepparam
// =============================================================================
using '../main.bicep'

param clusterName = 'webservices-v2-test'
param location = 'swedencentral'

// --- Budget-tuned defaults ---
param kubernetesVersion = '1.33.12'
param skuTier = 'Free'          // 'Free' = no paid API-server SLA (budget). 'Standard' to buy the SLA.
param vmSize = 'Standard_D4as_v5' // AMD, 4 vCPU / 16 GB — sized for the resident infra baseline.
param nodeCount = 1              // Manual scaling: bump this + redeploy to add nodes.
param zones = ['1', '2', '3']

// --- Optional Azure integrations (default off) ---
param deployAcrPull = false      // true → grant kubelet identity AcrPull on scouterna.azurecr.io
param deployKeyVault = false      // true (Phase 2) → create KV + federated cred for External Secrets Operator
