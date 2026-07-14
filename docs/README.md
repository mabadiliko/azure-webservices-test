# webservices cluster — documentation

Runbooks to build the cluster from scratch, in order. Following 01 → 03 on a
fresh subscription reproduces the whole platform; non-obvious pitfalls are
called out inline.

| Doc | What it covers |
|-----|----------------|
| [01-provision-cluster.md](01-provision-cluster.md) | vCPU quota, Bicep deploy, kubeconfig, node/Cilium verification. |
| [02-keyvault-and-identity.md](02-keyvault-and-identity.md) | Durable Key Vault, managed identity, role grant, Workload Identity federation. |
| [03-bootstrap-services.md](03-bootstrap-services.md) | Prerequisites (bootstrap secrets, Gateway CRDs, backup identities) then install everything via ArgoCD (no manual helm). |
| [onboarding.md](onboarding.md) | How a project gets namespace(s), a developer SA token, and optional ArgoCD registration. |
| [maintenance.md](maintenance.md) | Version pins, upgrade cadences, and how to keep the platform current. |

## What the cluster is

A shared Scouterna Kubernetes cluster (AKS, `swedencentral`), budget-sized
(single node, manual scaling), portable-by-intent (few Azure-specific pieces).
The infra group owns the cluster + common services via ArgoCD + Helm; projects
own their namespaces. See the top-level plan for the full design rationale.

## Reproducibility status

The repo captures the desired state (Bicep + Helm values) AND the executable
procedure (these runbooks). The definitive proof — tear down and rebuild purely
from these docs — has not yet been run; do that before the production cutover.
