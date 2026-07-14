// =============================================================================
// main.bicep — orchestrator for the "webservices-v2" cluster deployment.
//
// Deploys the AKS cluster (aks.bicep) and, when enabled, the optional Azure
// integrations. Keep real values in a GITIGNORED infra/env/*.bicepparam
// (copy the .example). This is a public repo — no identifiers in Git.
// =============================================================================

@description('Cluster name')
param clusterName string = 'webservices-v2'

@description('Azure region. Sweden Central.')
param location string = 'swedencentral'

@description('Kubernetes version.')
param kubernetesVersion string = '1.33.12'

@description('SLA tier (Free = no paid SLA')
@allowed(['Free', 'Standard'])
param skuTier string = 'Free'

@description('Node pool VM size. D4as_v5 = AMD, 4 vCPU / 16 GB.')
param vmSize string = 'Standard_D4as_v5'

@description('Node count (manual scaling).')
param nodeCount int = 1

@description('Availability zones.')
param zones string[] = ['1', '2', '3']

@description('Grant the kubelet identity AcrPull on the shared ACR. Off by default.')
param deployAcrPull bool = false

@description('Create a Key Vault + federated credential for External Secrets Operator.')
param deployKeyVault bool = false

module aks 'aks.bicep' = {
  name: 'aks'
  params: {
    clusterName: clusterName
    location: location
    kubernetesVersion: kubernetesVersion
    skuTier: skuTier
    vmSize: vmSize
    nodeCount: nodeCount
    zones: zones
  }
}

// ---- Optional Azure integrations (modules added in later phases) ----
// When implemented, gate them with the flags above, e.g.:
//   module acrPull 'acr-pull.bicep'  = if (deployAcrPull)  { ... }
//   module keyVault 'keyvault.bicep' = if (deployKeyVault) { params: { oidcIssuerUrl: aks.outputs.oidcIssuerUrl ... } }
// Placeholders now so the flags exist in the param surface from the start.

output oidcIssuerUrl string = aks.outputs.oidcIssuerUrl
output kubeletIdentityObjectId string = aks.outputs.kubeletIdentityObjectId
output clusterName string = aks.outputs.clusterName
output clusterFqdn string = aks.outputs.clusterFqdn
