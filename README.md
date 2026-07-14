# Webservices v2

A shared Kubernetes platform for Swedish Scouting (Scouterna) — one cluster in
Azure that many projects use, over many years.

The infrastructure group owns the cluster and a set of common services (ingress,
monitoring, logging, object storage, databases, secrets). Projects get their own
namespaces and run whatever they like inside them. Everything here is
Infrastructure-as-Code: the cluster in **Bicep**, everything on top in **Helm +
ArgoCD**, so the whole platform can be torn down and rebuilt from this repo.

---

## Design principles

- **One cluster, budget-first.** A single, modestly-sized cluster. Scaling is a
  deliberate, reviewed change (edit a parameter, redeploy) — never automatic.
- **Projects own their namespaces.** No resource quotas by default. The platform
  *observes* usage and intervenes reactively only if one project starves others.
- **Portable by intent.** As few Azure-specific pieces as possible, so the
  cluster could in principle move to another cloud or distro. The Azure surface
  is small and clearly marked (see [Portability](#portability)).
- **GitOps.** The infra group manages the common services declaratively via
  ArgoCD. Projects *may* register with ArgoCD too, but it is optional.
- **Reproducible.** The runbooks in [`docs/`](docs/) rebuild the whole platform
  from scratch. This has been proven end-to-end (full teardown + rebuild).

---

## Architecture at a glance

```
                        Internet
                           |
                 +---------v---------+     Azure LoadBalancer (public IP)
                 |      Traefik      |     ingress + TLS
                 +---------+---------+      (cert-manager / Let's Encrypt)
                           |
          +----------------+----------------+
          |                                 |
   +------v-------+                 +--------v--------+
   |   project    |   ...projects   |     common      |  owned by the infra
   |  namespaces  |                 |    services     |  group, managed by
   +--------------+                 +-----------------+  ArgoCD

   common services:  Traefik . cert-manager . MinIO (object storage) .
   kube-prometheus-stack (Prometheus/Grafana/Alertmanager) . Loki (logs) .
   Thanos (long-term metrics) . External Secrets Operator (Key Vault) .
   CloudNativePG (PostgreSQL) . Headlamp (web UI)
```

The cluster is **AKS** in **Sweden Central**: a single `Standard_D4as_v5` node
(4 vCPU / 16 GB, manual scaling), Kubernetes 1.33, **Cilium** eBPF dataplane +
NetworkPolicy, Workload Identity + OIDC, and the Key Vault CSI add-on. See
[`infra/aks.bicep`](infra/aks.bicep).

Storage is in-cluster and portable: **MinIO** for S3-compatible object storage
(backs Loki, Thanos, and backups) and **CloudNativePG** for PostgreSQL — no Azure
data PaaS. Persistent volumes use a cheap StandardSSD StorageClass by default,
with a Premium class available opt-in.

### Common services

| Service | What it does | Chart |
|---|---|---|
| **cluster-infra** | StorageClasses + cert-manager ClusterIssuers | raw manifests |
| **cert-manager** | TLS certificates (Let's Encrypt) | `cert-manager` v1.20.2 |
| **Traefik** | Ingress controller (default class) + LoadBalancer | `traefik` 41.0.2 |
| **MinIO** | S3-compatible object storage | `minio` 5.4.0 |
| **CloudNativePG** | PostgreSQL operator (clusters created per project) | `cloudnative-pg` 0.29.0 |
| **External Secrets** | Sync secrets from Azure Key Vault (Workload Identity) | `external-secrets` 2.7.0 |
| **monitoring** | Prometheus + Grafana + Alertmanager + Loki + Alloy | `kube-prometheus-stack` 87.15.1 |
| **Thanos** | Long-term / HA metrics (MinIO-backed) | `thanos` 1.23.1 |
| **Headlamp** | Kubernetes web UI (ServiceAccount-token login) | `headlamp` 0.41.0 |
| **governance** | Per-namespace dashboard + soft-threshold alerts | raw manifests |

Charts come from their upstream repositories; only the **values** live here (the
ArgoCD multi-source pattern), so upgrades are a version bump.

---

## Repository layout

```
infra/                     Bicep — the only Azure-specific layer
  aks.bicep                the cluster
  keyvault.bicep           durable Key Vault (separate, long-lived RG)
  main.bicep               orchestrator
  env/webservices.bicepparam  cluster params (no secrets — committed)

k8s/
  argocd/
    projects/              AppProjects: infra, apps-dev, apps-prod (blast-radius tiers)
    infra-root-app.yaml    app-of-apps root (recurses infra-apps/)
    infra-apps/            one ArgoCD Application per common service (by sync-wave)
  infra-manifest/          Helm values + raw manifests for the common services
  projects/_template/      copy this to onboard a project (namespaces, RBAC, Helm-per-env chart)

docs/                      build + onboarding runbooks (start here to build the cluster)
```

Onboarding a new common service is one file: drop an `Application` into
`k8s/argocd/infra-apps/` and commit — the app-of-apps root picks it up.

---

## Building the cluster

Follow the runbooks in order — they capture every step and every gotcha:

1. **[docs/01 — Provision the cluster](docs/01-provision-cluster.md)** — vCPU
   quota, Bicep deploy, kubeconfig.
2. **[docs/02 — Key Vault + identity](docs/02-keyvault-and-identity.md)** — the
   durable secrets vault and Workload Identity federation.
3. **[docs/03 — Bootstrap services](docs/03-bootstrap-services.md)** — seed the
   bootstrap prerequisites, then install ArgoCD and apply the app-of-apps root;
   ArgoCD brings up every common service from Git.

The common services are installed and managed **only** by ArgoCD — no manual
`helm install`. `k8s/argocd/infra-root-app.yaml` manages everything from `main`.

> **Secrets & IDs are never committed.** This is a public repo. Kubeconfigs and
> secret material are gitignored; the cluster's subscription is selected out of
> band (`az account set`), not stored here. The Bicep param file holds only
> cluster shape (no identifiers), so it is committed.

---

## Using the platform (projects)

Projects are onboarded via [docs/onboarding.md](docs/onboarding.md). In short:

- A project gets one or more **namespaces** (e.g. `myapp-dev`, `myapp-prod`).
- Developers get a **namespace-scoped ServiceAccount token**, pasted into
  Headlamp or used with `kubectl` — full control inside the namespace, nothing
  outside it.
- **Optional ArgoCD registration** uses **Helm-per-environment**: one chart plus
  a complete `values-dev.yaml` / `values-prod.yaml`. Each environment is stated
  in full (not a Kustomize overlay), so configuration cannot leak from dev to
  prod by omission.
- Projects needing centralized secrets declare an `ExternalSecret` referencing
  the shared Key Vault — a native Kubernetes Secret appears, no CSI mount dance.

### Governance by observation

No quotas are imposed by default. The infra group watches a per-namespace
resource dashboard and soft-threshold alerts (a namespace requesting a large
share of the cluster, or a PVC filling up). If a namespace starves others, a
reactive `LimitRange` / `ResourceQuota` is applied to *that* namespace only, as
a temporary corrective — see
[`k8s/infra-manifest/cluster-infra/monitor-limits/`](k8s/infra-manifest/cluster-infra/monitor-limits/).

---

## Portability

Almost everything is standard Kubernetes and moves unchanged. The Azure-specific
touchpoints are few and isolated:

| Touchpoint | Where | On another cloud/distro |
|---|---|---|
| AKS control plane | `infra/aks.bicep` | Replace the Bicep layer; all of `k8s/` moves as-is |
| `disk.csi.azure.com` StorageClass | `cluster-infra/storageclass/` | Change the provisioner; keep the class names |
| LoadBalancer annotations | `traefik/values.yaml` | Provider's LB annotations, or MetalLB |
| Secrets backend (Key Vault) | External Secrets `ClusterSecretStore` | Swap the store (Vault/AWS/GCP); `ExternalSecret`s unchanged |

In-cluster MinIO + CloudNativePG mean **no Azure data PaaS**. The residual Azure
surface is one Bicep template, one StorageClass string, a couple of LB
annotations, and one secret-store object.

---

## Status

The cluster and every common service have been built and validated end-to-end,
including a full **teardown + rebuild from the docs** and a full **ArgoCD
bring-up from Git**. Backups (Velero → MinIO, plus CloudNativePG's own backups)
are the next planned addition.
