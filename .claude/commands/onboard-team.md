# Onboard a new team to the webservices-v2 cluster

Onboard a new team or developer to the Scouterna webservices-v2 AKS cluster so they can manage their own namespace(s) via Headlamp or kubectl.

## Cluster context

- Cluster: `webservices-v2` (Azure AKS, swedencentral)
- Kubernetes UI: https://headlamp.wsinfra.scouterna.net
- Ingress controller: Traefik (class: `traefik`) — LoadBalancer IP is assigned at deploy time
- TLS: cert-manager with `letsencrypt-prod` ClusterIssuer
- DNS: `*.wsinfra.scouterna.net` → the Traefik LoadBalancer IP (managed externally)

## What to ask the user before starting

1. **Team/developer name** — used as the ServiceAccount name (e.g. GitHub username or team name)
2. **Namespace(s)** — which namespaces should they have access to? Do the namespaces already exist or do they need to be created?
3. **Access level** — `admin` (full control within namespace) or `view` (read-only)?
4. **Token duration** — default 8760h (1 year), ask if they want something different

## Steps

### 1. Create namespace(s) if they don't exist

```bash
kubectl create namespace <namespace>
```

### 2. Create the ServiceAccount in the primary namespace

```bash
kubectl create serviceaccount <name> -n <primary-namespace>
```

### 3. Create RoleBindings for each namespace

```bash
kubectl create rolebinding <name>-admin \
  --clusterrole=admin \
  --serviceaccount=<primary-namespace>:<name> \
  -n <namespace>
```

Repeat for each namespace. Always use `--serviceaccount=<primary-namespace>:<name>` (where the ServiceAccount lives), not the target namespace.

Use `--clusterrole=view` instead of `admin` for read-only access.

### 4. Generate the token

```bash
kubectl create token <name> -n <primary-namespace> --duration=8760h
```

Send the token to the developer. They paste it into the Headlamp login screen at https://headlamp.wsinfra.scouterna.net.

### 5. Verify

```bash
kubectl get rolebindings -n <namespace> | grep <name>
```

## Revoking access

Delete the ServiceAccount — all RoleBindings referencing it become ineffective immediately:

```bash
kubectl delete serviceaccount <name> -n <primary-namespace>
```

Also delete the RoleBindings to keep things clean:

```bash
kubectl delete rolebinding <name>-admin -n <namespace>
```

## Notes

- The ServiceAccount lives in one namespace but can be bound to multiple namespaces via RoleBindings
- Tokens generated with `kubectl create token` expire (even with --duration). For a non-expiring token, create a `kubernetes.io/service-account-token` Secret instead.
- This cluster uses a local admin kubeconfig for infra bootstrap and namespace-scoped ServiceAccount tokens for developers (no managed Azure AD / Entra RBAC dependency — chosen for portability). Token-based login via Headlamp is the supported developer flow.
