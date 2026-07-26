# webservices cluster — documentation

| Doc | What it covers |
|-----|----------------|
| [install.md](install.md) | The full build runbook, from empty subscription to running cluster — one continuous session, dependency-ordered (prerequisites → provision → cluster-derived wiring → ArgoCD). Non-obvious pitfalls called out inline. |
| [onboarding.md](onboarding.md) | How a project gets namespace(s), a developer SA token, and optional ArgoCD registration. |
| [maintenance.md](maintenance.md) | Version pins, upgrade cadences, and how to keep the platform current. |

## What the cluster is

A shared Scouterna Kubernetes cluster (AKS, `swedencentral`), budget-sized
(single node, manual scaling), portable-by-intent (few Azure-specific pieces).
The infra group owns the cluster + common services via ArgoCD + Helm; projects
own their namespaces. See the [top-level README](../README.md) for the full
design rationale.
