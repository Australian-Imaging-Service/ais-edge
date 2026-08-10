# k0smotron

## Overview

[k0smotron](https://docs.k0smotron.io/) is an operator that runs **k0s
control planes as pods** inside a host Kubernetes cluster. Each
declared `Cluster` resource produces a hosted k0s control plane (API
server + etcd + konnectivity-server + manifest reconciler) that
external workers can join.

## Role in this stack

The "central brain". One k0smotron deployment on the management
cluster manages a hosted k0s control plane for every edge site. The
edge VMs run only the k0s worker (kubelet); their control plane
(API server + etcd + konnectivity-server) lives as pods on the
management node.

## What k0smotron has access to

- **Management cluster API** (its operator runs there)
- Creates Pods, StatefulSets, Services, ConfigMaps, Secrets, Ingresses
  in the per-edge namespace
- Generates the **cluster CA keypair** at install time, stored as
  `Secret <cluster>-ca` in the cluster namespace. This is a separate
  CA from `ais-edge-ca` (which we manage via cert-manager); k0smotron
  manages this one for the k0s API + konnectivity certs

## Where it runs

- Cluster: management cluster only
- Namespace: `k0smotron`
- Workload: Deployment `k0smotron-controller-manager`
- Installed via `kubectl apply --server-side -f https://docs.k0smotron.io/stable/install.yaml`

For each edge declared in `config/edge-nodes.env`:
- A namespace named after the cluster
- A StatefulSet `kmc-<cluster>-0` (the k0s API + konnectivity)
- A StatefulSet `kmc-<cluster>-etcd-0` (etcd, with PVC)
- A NodePort Service `kmc-<cluster>-nodeport` (API:30443, konnect:30132)
- An Ingress `kmc-<cluster>` with two SNI rules:
  - `k0s.aisedge.local` → API
  - `konnect.aisedge.local` → konnectivity
- A DaemonSet `k0smotron-haproxy` pushed to the worker for in-cluster
  API access (see `haproxy.md`)

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/edge-cluster.yaml.tpl` | the `Cluster` CR — replicas, version, externalAddress, service, ingress, k0sConfig SANs |
| `install.sh` (step 2) | installs cert-manager + the k0smotron operator as prerequisites |
| `scripts/05-setup-edge-cluster.sh` | applies the Cluster CR, extracts kubeconfig, generates JoinTokenRequest with rewritten URL |
| `scripts/06-join-edge-worker.sh` | SSH-installs k0s worker, stages haproxy certs, patches CoreDNS |

Key knobs in the Cluster CR:
- `spec.k0sConfig.spec.api.sans` — adds aisedge.local hostnames to the
  API server cert (so workers verifying via the SNI hostname accept it)
- `spec.ingress` — k0smotron's built-in helper that auto-generates the
  Ingress + ssl-passthrough annotations
- `spec.service.type=NodePort` — needed because the in-cluster
  `kubernetes` Service routes via the NodePort port number; with
  ClusterIP-only, kube-router on the worker can't reach the API

## Operations

```bash
# All hosted clusters
kubectl get clusters.k0smotron.io -A

# Specific cluster status
kubectl describe cluster -n edge-dev edge-dev

# Re-render the CR (e.g. after editing the .tpl)
bash scripts/05-setup-edge-cluster.sh "<edge-entry>"

# Generate a new join token (rotates the bootstrap secret)
kubectl delete jointokenrequest -n edge-dev edge-dev-token --ignore-not-found
kubectl apply -f - <<EOF
apiVersion: k0smotron.io/v1beta1
kind: JoinTokenRequest
metadata: { name: edge-dev-token, namespace: edge-dev }
spec:
  clusterRef: { name: edge-dev, namespace: edge-dev }
EOF
```

## Benefits

- **Hosted control plane** — edges only run kubelet; no etcd, no API
  server to operate per site
- **Centralised access** — one kubeconfig per child cluster on the
  mgmt node; all `kubectl` traffic routes through the central API
- **Built-in Ingress support** (`spec.ingress`) — handles the SNI +
  ssl-passthrough wiring for us, no manual Ingress YAML
- **Built-in haproxy DaemonSet** — gives in-cluster components a local
  API endpoint (essential for kube-router, kube-proxy)
- **Easy multi-tenancy** — each edge in its own namespace with
  RBAC-isolated resources

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Mgmt node down | All hosted control planes unreachable; edges keep running but lose ability to schedule new pods | k0s on mgmt is HA-able with multiple controllers (out of scope for current MVP) |
| etcd PVC corruption | Hosted cluster loses state; child cluster needs re-init | Currently uses `emptyDir` persistence for dev; switch to `local-path` or external storage in production |
| Cluster CR misconfiguration | Hosted cluster fails to start | k0smotron-controller-manager logs the reason loudly |
| API cert SANs missing | Worker rejects connection ("certificate is valid for X, not Y") | `spec.k0sConfig.spec.api.sans` enumerates them; verified at install via `openssl s_client` |
| Operator pod crash | Existing clusters keep running; new ones can't be created | Operator auto-restarts |

## Replacements / future

- **kamaji** — alternative hosted-control-plane operator (similar
  concept, different implementation). k0smotron's tighter coupling with
  k0s itself is the reason we picked it
- **Cluster API** (`cluster-api-controller`) — the upstream standard
  for managing K8s clusters declaratively. Heavier than k0smotron;
  worth considering if we grow beyond the k0s ecosystem
- **vCluster** — tenant-isolated virtual clusters. Different use case
  (multi-tenant within one host cluster, vs hub-and-spoke across sites)

## Future enhancements

- HA for hosted control planes (`spec.replicas: 3` with proper PVC
  storage)
- API audit logs from the hosted control plane → Vector → Loki
- mTLS to konnectivity (currently the konnectivity tunnel uses k0s's
  internal CA mTLS; we don't yet auth the agent's identity beyond that)
