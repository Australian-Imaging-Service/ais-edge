# haproxy (k0smotron-haproxy DaemonSet on edges)

## Overview

[HAProxy](https://www.haproxy.org/) is a high-performance Layer-4/7
TCP/HTTP proxy. In this stack we don't deploy it as our own component
— **k0smotron does**, automatically, on every worker node of every
hosted child cluster, when `spec.ingress` is set on the `Cluster` CR.

## Role in this stack

A local TLS endpoint on each edge worker that proxies in-cluster API
traffic to the management nginx-ingress. Without it, the in-cluster
`kubernetes` Service (`10.96.0.1:443`) has nowhere to NAT to — k0s's
hosted control plane lives on the management cluster, not in the
child cluster's pod network.

```
worker pod    ──►  10.96.0.1:443         (kubernetes Service ClusterIP)
                   │
                   │  kube-proxy iptables NAT
                   ▼
worker host   ──►  <edge-IP>:7443        (k0smotron-haproxy, hostNetwork)
                   │
                   │  haproxy: TLS terminate + open NEW outbound TLS conn
                   ▼  with explicit SNI=k0s.aisedge.local
mgmt host     ──►  203.x.x.x:443         (nginx-ingress, ssl-passthrough)
                   │
                   ▼
                   kmc-edge-dev-0        (k0s API)
```

## What haproxy has access to

- **Host network namespace** (binds `7443` on each worker)
- **hostPath /etc/haproxy/certs**:
  - `server.pem` — frontend cert + key, **signed by the cluster's
    internal k0s CA** (so workload pods trust it via their projected
    serviceaccount `ca.crt`). Pre-staged by `06-join-edge-worker.sh`.
  - `ca.crt` — same cluster CA cert; haproxy uses it to verify the
    upstream nginx → k0s API chain
- **No outbound network beyond mgmt:443** — strictly proxies TCP

## Where it runs

- Cluster: each edge child cluster
- Namespace: `default` (k0smotron-managed)
- Workload: DaemonSet `k0smotron-haproxy` (one pod per worker,
  `hostNetwork: true`)
- Image: `haproxy:2.8`
- Created automatically by k0smotron when `spec.ingress` is set on
  the `Cluster` CR; not in our repo

## Configuration

We don't write its YAML — k0smotron does. But we DO control:

| File | Purpose |
|---|---|
| `manifests/01-management/edge-cluster.yaml.tpl` | when `spec.ingress.deploy: true` is set, k0smotron generates the haproxy DS |
| `scripts/06-join-edge-worker.sh` | extracts the cluster CA from Secret `<cluster>-ca`, mints a server cert with the right SANs (kubernetes / 10.96.0.1 / <node-ip> / localhost), pushes both to `/etc/haproxy/certs/` on the worker |

The auto-generated config:
```
frontend kubeapi_front
    bind [::]:7443 v4v6 ssl crt /etc/haproxy/certs/server.pem
    mode tcp
backend kubeapi_back
    mode tcp
    server kube_api k0s.aisedge.local:443 ssl verify required \
                    ca-file /etc/haproxy/certs/ca.crt \
                    sni str(k0s.aisedge.local)
```

## Operations

```bash
# DS state
KUBECONFIG=kubeconfig-edge-dev kubectl get ds -n default k0smotron-haproxy

# Pod logs (look for cert/upstream errors)
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n default \
  -l app=k0smotron-haproxy --tail=30

# Test that the local endpoint is alive on the worker
ssh edge "curl -kv https://127.0.0.1:7443/version 2>&1 | head -10"
```

## Benefits

- **In-cluster API works without network changes** — kube-router,
  kube-proxy, metrics-server, etc. talk to `10.96.0.1` like they would
  in any cluster; the haproxy hop is invisible to them
- **TLS-terminate-then-reencrypt** — gives us a place to inject the
  correct SNI on the upstream connection (otherwise the client's SNI
  would be `kubernetes` or `10.96.0.1`, which nginx-ingress wouldn't
  recognise)
- **k0smotron-managed** — we don't have to write or maintain the
  manifest

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `server.pem` permissions wrong | Pod CrashLoops with "cannot open file" | We `install -m 0644` explicitly in 06; haproxy container runs as non-root |
| `server.pem` SANs missing critical names | Pods get "x509: cert valid for X, not Y" | We enumerate kubernetes / kubernetes.default[.svc[.cluster.local]] / 10.96.0.1 / 127.0.0.1 / `<node-ip>` |
| `server.pem` signed by the wrong CA | Pods get "unknown authority" | We sign with the **cluster's** internal CA (extracted from Secret `<cluster>-ca`), not ais-edge-ca |
| haproxy down | Every in-cluster API call fails; whole cluster degrades | Pod auto-restarts; on a single-worker edge there's no HA |
| Upstream (mgmt nginx) down | haproxy returns connection errors | Worker components retry; alerts fire |
| Certs expire | TLS handshake fails | We issue with 10y duration; tied to the cluster-CA lifetime |

## Replacements / future

- Patching k0smotron to consume an existing cert/Secret instead of
  the hostPath dance — would be cleaner but k0smotron doesn't expose
  that knob today
- Replacing haproxy with envoy or a custom proxy — possible but
  k0smotron does this for us; rolling our own loses upstream support
- mTLS on the haproxy upstream (currently only the upstream-side
  TLS is mutual; the frontend-side trust is one-way)

## Future enhancements

- Automate cert renewal (currently 10-year durations; tied to the
  cluster CA's expiry)
- Verify behaviour on multi-worker edges (the DS would put one haproxy
  per node, and EndpointSlice would round-robin between them)
- Track haproxy's own metrics — it can expose Prometheus on a stats
  port; not currently scraped because of complexity inside k0smotron's
  generated manifest
