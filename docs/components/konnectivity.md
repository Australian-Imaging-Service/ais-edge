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
- Listens on port `:30132` (Service NodePort — also reachable through
  nginx-ingress at `konnect.aisedge.local:443`)
- Receives long-lived TLS+gRPC connections from agents
- Makes RPC calls to the connected agent on behalf of the API server
- Authenticates agents via mTLS using the cluster's internal CA

### Agent side (on each worker)
- Pod in the child cluster's `kube-system` namespace
- Outbound TLS+gRPC to `https://konnect.aisedge.local:443` (single
  long-lived stream per worker)
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
| `manifests/01-management/edge-cluster.yaml.tpl` | sets `spec.ingress.konnectivityHost: konnect.aisedge.local` and adds the SAN to the API server cert |
| `scripts/06-join-edge-worker.sh` | patches CoreDNS in the child cluster with a `hosts` plugin entry so the konnectivity-agent pod can resolve `konnect.aisedge.local` (the agent uses cluster DNS, not the host's /etc/hosts) |

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

See also the **"Konnectivity and Middleboxes"** section in the main
[`README.md`](../../README.md). Summary:

| Risk | Impact | Mitigation |
|---|---|---|
| TLS-intercepting proxy in the path | Agent rejects the proxy's cert; tunnel never establishes | Site IT must bypass interception for the management IP |
| Aggressive HTTP/2 idle timeout on a firewall | Stream drops periodically; brief `kubectl exec` stalls | Keep idle timeout ≥ 60 min on outbound 443 to mgmt |
| gRPC blocked / HTTP/1.1 forced | Tunnel breaks completely | Allow plain HTTPS/HTTP-2 to mgmt |
| `konnect.aisedge.local` not resolvable in pod | Agent CrashLoop with "no such host" | CoreDNS hosts plugin patched at install (script 06) |
| API server down | Agents remain connected to whichever k0smotron pod replaces it; brief gap | Auto-recovery |

**Crucially**: konnectivity is for **central-admin visibility** only. The
DICOM data path (mc → SeaweedFS) does NOT go through konnectivity; it
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
- Tighter telemetry on tunnel state — Vector forwards the agent's
  stdout to Loki today, but a dedicated metric `konnectivity_tunnel_up`
  would let alerts fire faster than the existing 1h flapping rule
