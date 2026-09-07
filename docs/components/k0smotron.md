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
- Workload: Deployment `k0smotron-controller-manager-control-plane`
- Installed by `install.sh` step 2/7, from a **pinned** release asset:
  `kubectl apply --server-side --force-conflicts -f https://github.com/k0sproject/k0smotron/releases/download/v2.0.3/control-plane-components.yaml`
  (`K0SMOTRON_VERSION` in `install.sh`). Only the **control-plane**
  provider is installed. The unpinned `docs.k0smotron.io/stable/install.yaml`
  bundle the previous installer used is deliberately not used: it is
  whatever upstream published that morning, and it also ships the two CAPI
  machine-provisioning providers — bootstrap (`K0sWorkerConfig`) and
  infrastructure (`RemoteMachine`) — that nothing here creates. Workers are
  joined with a token instead, by `scripts/06-join-edge-worker.sh` over SSH
  or by `scripts/06b-make-bootstrap.sh` + `scripts/06c-post-join.sh` as a
  carry-over bundle, because an edge is a physical box in a hospital that
  CAPI cannot provision

For each edge in the `edges:` list in `sites/<site>/values.yaml`:
- A namespace named after the cluster
- A StatefulSet `kmc-<cluster>-0` (the k0s API + konnectivity)
- A StatefulSet `kmc-<cluster>-etcd-0` (etcd, with PVC)
- A Service per edge, from that site's `exposure` (fleet default
  `k0smotron.exposure.default: nodePort`; both shipped sites use `sni` —
  see `docs/TOUR.md` §2.2):
  - `exposure: nodePort` → NodePort Service `kmc-<cluster>-nodeport` on the
    site's **own explicit** `apiNodePort` / `konnectivityNodePort`. Both are
    required and the chart refuses to render without them; the port is never
    derived from the entry's position in `edges`
    (`charts/mgmt/templates/edge-clusters.yaml`, which also rejects
    duplicates and out-of-range ports — a derived port silently moved to
    another site's number when the list was reordered)
  - `exposure: sni` → ClusterIP Service `kmc-<cluster>`, reachable only
    through the ssl-passthrough Ingress. No cluster-wide port is allocated;
    `apiPort`/`konnectivityPort` stay at the CRD defaults (30443/30132) as
    *Service* ports, so two sites cannot collide
- An Ingress per edge with two ssl-passthrough SNI rules, named per site:
  - `<apiPrefix>-<edge>.<domain>` → API
  - `<konnectivityPrefix>-<edge>.<domain>` → konnectivity

  Prefixes default to `k0s` / `konnectivity`
  (`k0smotron.hostnames.apiPrefix` / `.konnectivityPrefix` in
  `charts/mgmt/values.yaml`) over `k0smotron.hostnames.domain`, which falls
  back to `domain.internal` — so `edge-dev` renders
  `k0s-edge-dev.aisedge.local` and `konnectivity-edge-dev.aisedge.local`. A
  site whose workers have already joined pins the names they were given via
  `apiHost` / `konnectivityHost` on its own `edges[]` entry. The fleet-wide
  `hostnames.k0sApi` / `hostnames.konnectivity` these names used to come
  from were removed and now fail the render, because one pair of names
  shared by every edge meant the second site's Ingress claimed a hostname
  the first already owned
- A DaemonSet `k0smotron-haproxy` pushed to the worker for in-cluster
  API access (see `haproxy.md`)

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/templates/edge-clusters.yaml` | renders one `Cluster` CR per `edges[]` entry — version, externalAddress, service/exposure (NodePort or ClusterIP), ingress, persistence (pvc), etcd sizing, k0sConfig SANs. `replicas` is pinned to 1 and is deliberately not a values key: >1 needs `spec.kineDataSourceURL` |
| `sites/<site>/values.yaml` (`edges[]`, `k0smotron.*`) | per-site hostnames (`apiHost`/`konnectivityHost`, else `hostnames.apiPrefix`/`konnectivityPrefix` + domain), node ports (`apiNodePort`/`konnectivityNodePort`), exposure mode (`exposure: nodePort\|sni`), `extraSans` |
| `charts/mgmt/values.yaml` (`k0smotron.*`) | fleet-wide defaults — `k0sVersion` (must match the worker k0s), `exposure.default`, `exposure.nodePortRange`, `hostnames.*`, `persistence`, `etcdPersistence`, `resourcePolicyKeep` |
| `install.sh` (step 2) | installs cert-manager + the k0smotron operator as prerequisites |
| `scripts/05-setup-edge-cluster.sh` | waits for the control plane, extracts the child kubeconfig with `server:` rewritten to the ingress, writes the mgmt-node `/etc/hosts` entries (onprem only), and mints the JoinTokenRequest with the rewritten URL. It no longer applies the Cluster CR |
| `scripts/06-join-edge-worker.sh` | `join: ssh` (the default) — SSH-installs the k0s worker, stages the haproxy cert + k0s CA + join token, then calls `06c-post-join.sh` |
| `scripts/06b-make-bootstrap.sh` | `join: bundle` — builds `<edge>-join.sh`, a single self-extracting carry-over script, for an edge with no inbound path (whitelisted IPs, VPN, GlobalProtect) |
| `scripts/06c-post-join.sh` | shared by both paths: waits for the node to go Ready, patches the child cluster's CoreDNS with the mgmt-side hostnames (onprem topology only), restarts coredns + konnectivity-agent |

`manifests/01-management/edge-cluster.yaml.tpl` is the legacy pre-Helm
renderer of the `Cluster` CR. `install.sh` exports
`CLUSTER_CR_MANAGED_BY_HELM=1` for every edge and `scripts/05` then skips it,
so it is not applied on any supported path — it hardcodes apiPort 30443 /
konnectivityPort 30132 and `persistence: emptyDir`, which the chart refuses,
and so it cannot express a second site.

Key knobs in the Cluster CR:
- `spec.k0sConfig.spec.api.sans` — adds aisedge.local hostnames to the
  API server cert (so workers verifying via the SNI hostname accept it)
- `spec.ingress` — k0smotron's built-in helper that auto-generates the
  Ingress + ssl-passthrough annotations
- `spec.service.type` — `NodePort` under `exposure: nodePort`, which is why
  that mode exists: the child's in-cluster `kubernetes` Service
  (10.96.0.1:443) routes via the NodePort port number, and kube-router,
  kube-proxy and metrics-server on the worker use that path. `exposure: sni`
  renders `ClusterIP` instead and reaches the API only through the
  ssl-passthrough Ingress; it is the newer, less-measured path — see
  `k0smotron.exposure` in `charts/mgmt/values.yaml` and `docs/TOUR.md` §2.2
  for what has and has not been verified before migrating a fleet

## Operations

```bash
# All hosted clusters
kubectl get clusters.k0smotron.io -A

# Specific cluster status
kubectl describe cluster -n edge-dev edge-dev

# Change the CR: edit edges[] in sites/<site>/values.yaml, then re-render it
# through Helm — charts/mgmt owns the Cluster object now
helm upgrade --install mgmt charts/mgmt -n ais-mgmt -f sites/<site>/values.yaml

# Re-issue the child kubeconfig + join token (step 5 no longer touches the CR).
# scripts/05 is a STEP of the installer, not a standalone command: 00-common.sh
# exits unless AIS_CONFIG_FROM_SITE=1, and 05 then needs CLUSTER_NAME, NODE_IP,
# SSH_USER, SSH_KEY, MGMT_NODE_IP, INGRESS_PORT, SEAWEEDFS_HOSTNAME,
# K0S_API_HOSTNAME, KONNECTIVITY_HOSTNAME and CLUSTER_CR_MANAGED_BY_HELM=1 —
# all exported by install.sh. Its positional argument is the bare edge name.
./install.sh <site>

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
| etcd PVC corruption | Hosted cluster loses state; child cluster needs re-init | Control plane and etcd both use PVCs with `autoDeletePVCs: false` — `k0smotron.persistence` (type `pvc`, 10Gi, claim `<edge>-k0s-state`) and `k0smotron.etcdPersistence` (1Gi); `persistence.type=emptyDir` is rejected at render time. Note the etcd `volumeClaimTemplate` is immutable — resizing an existing site needs the StatefulSet deleted with `--cascade=orphan`, not a values edit |
| Cluster CR misconfiguration | Hosted cluster fails to start | `k0smotron-controller-manager-control-plane` logs the reason loudly |
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

- HA for hosted control planes. PVC storage is already the default
  (`k0smotron.persistence.type: pvc`, with a separate `etcdPersistence`),
  so what is left is the replica count: `spec.replicas` is pinned to 1 and
  is deliberately not a values key, because >1 needs an external kine
  datastore (`spec.kineDataSourceURL`) and raising it alone yields a
  control plane that will not start
- API audit logs from the hosted control plane → Vector → Loki
- mTLS to konnectivity (currently the konnectivity tunnel uses k0s's
  internal CA mTLS; we don't yet auth the agent's identity beyond that)
