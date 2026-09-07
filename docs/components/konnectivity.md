# Konnectivity

## Overview

[Konnectivity](https://kubernetes.io/docs/tasks/extend-kubernetes/setup-konnectivity/)
is a Kubernetes-native reverse-tunnel mechanism that lets the API
server reach back into worker components when network policy / NAT /
firewall would otherwise block direct access. The agent (on workers)
opens an outbound connection to the server (next to the API server)
and keeps a persistent stream open; whenever the API server needs to
talk to a kubelet, it sends RPCs over that stream.

## Role in this stack

The reverse tunnel that makes `kubectl exec`, `kubectl logs`,
`kubectl port-forward`, and metrics-server scraping work even though
edge workers have **zero inbound ports**. Without it, the management
API server has no way to call back into a kubelet running behind a
NAT/firewall.

## What konnectivity has access to

### Server side (in the kmc pod on mgmt)
- Reached by agents at `<konnectivityPrefix>-<edge>.<domain>:443` through
  the ssl-passthrough nginx-ingress. The default prefix is `konnectivity`
  (`k0smotron.hostnames.konnectivityPrefix` in `charts/mgmt/values.yaml`),
  so `sites/example-mgmt` renders `konnectivity-edge-dev.aisedge.local`; a
  site whose workers already joined pins its real name with
  `edges[].konnectivityHost`
- The node port is per-edge, not a fleet-wide constant. Under
  `exposure: nodePort` the kmc Service is a NodePort and that site's own
  `edges[].konnectivityNodePort` is required — the chart refuses to render
  without it. Under `exposure: sni`, which is what both shipped sites use,
  the Service is ClusterIP, 30132 is only the CRD-default *Service* port,
  and no node port is allocated at all
- Receives long-lived TLS+gRPC connections from agents
- Makes RPC calls to the connected agent on behalf of the API server
- Authenticates agents via mTLS using the cluster's internal CA

### Agent side (on each worker)
- Pod in the child cluster's `kube-system` namespace
- Outbound TLS+gRPC to
  `https://<konnectivityPrefix>-<edge>.<domain>:443` — e.g.
  `https://konnectivity-edge-dev.aisedge.local:443` (single long-lived
  stream per worker)
- Forwards incoming RPCs to local kubelet (`localhost:10250`)
- Authenticates via the cluster's internal CA + a serviceaccount token

## Where it runs

- **Server:** part of the kmc pod (`kmc-<cluster>-0` on mgmt cluster)
- **Agent:** DaemonSet `konnectivity-agent` in the child cluster's
  `kube-system` namespace (auto-pushed by k0smotron)

## Configuration

We don't configure konnectivity directly — k0smotron does, derived
from `spec.ingress.konnectivityHost` on the Cluster CR. The relevant
knobs live in:

| File | Purpose |
|---|---|
| `charts/mgmt/templates/edge-clusters.yaml` | sets `spec.ingress.konnectivityHost` to `<konnectivityPrefix>-<edge>.<domain>` (pin a real name per site with `edges[].konnectivityHost`) and repeats it in `spec.k0sConfig.spec.api.sans` so the API server cert carries it. Driven by `edges[]` in `sites/<site>/values.yaml`. `manifests/01-management/edge-cluster.yaml.tpl` is the legacy pre-Helm renderer, skipped on every supported path because `install.sh` exports `CLUSTER_CR_MANAGED_BY_HELM=1` |
| `scripts/06c-post-join.sh` | patches CoreDNS in the child cluster with a `hosts` plugin entry so the konnectivity-agent pod can resolve that hostname (the agent uses cluster DNS, not the host's /etc/hosts). Runs after either delivery path — invoked by `scripts/06-join-edge-worker.sh` for `join: ssh`, and directly by `install.sh` for `join: bundle`, which is why it is a separate script. Skipped under `INSTALL_TOPOLOGY=cloud`, where real public DNS resolves the names and a `hosts` entry would shadow it |

## Operations

```bash
# Server-side health
kubectl logs -n edge-dev kmc-edge-dev-0 -c controller \
  | grep -i konnectivity

# Agent-side health
KUBECONFIG=kubeconfig-edge-dev kubectl get pods -n kube-system \
  -l k8s-app=konnectivity-agent
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n kube-system \
  -l k8s-app=konnectivity-agent --tail=20

# "No agent available" in API server logs ⇒ tunnel down
# Agent in CrashLoopBackOff ⇒ DNS, TLS, or network issue
```

## Benefits

- **Zero inbound on edge** — the entire firewall ask is "outbound 443"
- **Built into k0s** — k0smotron wires it for us
- **mTLS-authenticated** — both ends verify the other against the
  cluster CA; no shared secrets
- **Multiplexed** — one TCP connection carries many concurrent RPC
  streams; reconnect-and-resume on transient drops

## Risks and failure modes

This table is the canonical treatment. The root
[`README.md`](../../README.md) used to carry a "Konnectivity and
Middleboxes" section that this page summarised; it was removed in the
README rewrite and nothing there replaced it — neither `## Security model`
nor `## Troubleshooting` discusses TLS interception, HTTP/2 idle timeouts
or blocked gRPC. So the rows below are the only record of those failure
modes; keep them here rather than pointing elsewhere.

| Risk | Impact | Mitigation |
|---|---|---|
| TLS-intercepting proxy in the path | Agent rejects the proxy's cert; tunnel never establishes | Site IT must bypass interception for the management IP |
| Aggressive HTTP/2 idle timeout on a firewall | Stream drops periodically; brief `kubectl exec` stalls | Keep idle timeout ≥ 60 min on outbound 443 to mgmt |
| gRPC blocked / HTTP/1.1 forced | Tunnel breaks completely | Allow plain HTTPS/HTTP-2 to mgmt |
| `konnectivity-<edge>.<domain>` not resolvable in pod | Agent CrashLoop with "no such host" | CoreDNS hosts plugin patched at install (`scripts/06c-post-join.sh`, onprem topology only) |
| API server down | Agents remain connected to whichever k0smotron pod replaces it; brief gap | Auto-recovery |

**Crucially**: konnectivity is for **central-admin visibility** only. The
DICOM data path (the edge `s3-uploader` → SeaweedFS) does NOT go through
konnectivity; it
uses ordinary HTTPS over the same nginx-ingress on 443. So a
konnectivity outage means `kubectl logs` stops working but data
keeps flowing.

## Replacements / future

- **wireguard / tailscale** — site-to-site VPN approach. Works but
  adds a new control plane, more moving parts. Konnectivity is built
  into k0s, so it wins by default
- **Direct-attached worker** — if every edge VM had a public IP and
  open inbound ports, kubelet → API would work without konnectivity.
  Not realistic for the medical-imaging deployment
- **mTLS-only API** with no log/exec needs — possible if you only
  ever inspect logs through Vector→Loki (which we now do!), but
  you'd lose `kubectl exec` for debugging

## Future enhancements

- Per-edge agent client certificates with short rotation cycles (today
  they live as long as the cluster CA)
- Konnectivity-server HA (multi-replica) once the management cluster
  becomes HA
- Tighter telemetry on tunnel state. There is **no tunnel alert today**.
  `KonnectivityTunnelFlapping` selected
  `kube_pod_container_status_restarts_total{namespace="kube-system",
  pod=~"konnectivity-agent-.*"}` — but the agent runs in the EDGE cluster's
  `kube-system`, so mgmt Prometheus had zero series for it and the rule was
  deleted (`docs/TOUR.md` §9, `docs/alerting-architecture.md`). Restart
  count was the wrong signal regardless: the agent reconnects in-process, so
  a live tunnel observed cycling every ~10s ("no servers connected",
  "authentication handshake failed: EOF") never incremented it. Vector
  already forwards the agent's stdout to Loki with a correct `cluster`
  label, and that path *does* cross the tunnel — so the cheap next step is a
  Loki ruler rule over those lines, not a metric. A `konnectivity_tunnel_up`
  gauge would still be the nicer signal, but it needs a path to mgmt that
  does not exist yet; if we want it as a metric, Loki `recording_rules` can
  derive one from the same log stream
