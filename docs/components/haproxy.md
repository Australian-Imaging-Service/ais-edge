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
                   ▼  with explicit SNI=k0s-edge-dev.aisedge.local
mgmt host     ──►  203.x.x.x:443         (nginx-ingress, ssl-passthrough)
                   │
                   ▼
                   kmc-edge-dev-0        (k0s API)
```

The upstream name is **per edge**, not fleet-wide. `charts/mgmt` derives it as
`<apiPrefix>-<edge>.<domain.internal>` — `k0s-edge-dev.aisedge.local` for the
site above (`charts/mgmt/templates/edge-clusters.yaml`, matching
`install.sh`). It used to be a single `k0s.<domain>` for the whole fleet,
which meant the second site's Ingress claimed a hostname the first already
owned; the chart now refuses to render if the old fleet-wide
`hostnames.k0sApi` is still set (`charts/mgmt/templates/edge-clusters.yaml`). Pin a different name
per site with `apiHost` on that edge's `edges[]` entry if you need one.

## What haproxy has access to

- **Host network namespace** (binds `7443` on each worker)
- **hostPath /etc/haproxy/certs**:
  - `server.pem` — frontend cert + key, **signed by the cluster's
    internal k0s CA** (so workload pods trust it via their projected
    serviceaccount `ca.crt`). Minted on the management node by
    `stage_edge_join_payload()` in `scripts/00-common.sh`, then placed
    here by `scripts/files/edge-join.sh` when the worker joins.
  - `ca.crt` — same cluster CA cert; haproxy uses it to verify the
    upstream nginx → k0s API chain
- **Configured upstream is the management API on port 443.** This is a
  routing intention, not an egress restriction. Host-network access can reach
  other destinations permitted by the node firewall.

## Where it runs

- Cluster: each edge child cluster
- Namespace: `default` (k0smotron-managed)
- Workload: DaemonSet `k0smotron-haproxy` (one pod per worker,
  `hostNetwork: true`)
- Historical image record: `haproxy:2.8` (record date unknown). The generated
  DaemonSet image is not pinned by this chart and is not verified (2026-11-10).
  Read the child-cluster DaemonSet after installing the selected k0smotron.
- Created automatically by k0smotron when `spec.ingress` is set on
  the `Cluster` CR; not in our repo

## Configuration

We don't write its YAML — k0smotron does. But we DO control:

| File | Purpose |
|---|---|
| `sites/<site>/values.yaml` (`edges[]`) → `charts/mgmt/templates/edge-clusters.yaml` | the `Cluster` CR. `spec.ingress.deploy: true` (`charts/mgmt/templates/edge-clusters.yaml`) is what makes k0smotron generate the haproxy DS at all; `apiHost` / `konnectivityHost` on the same block are the names haproxy dials upstream |
| `manifests/01-management/edge-cluster.yaml.tpl` | **legacy, no longer applied.** `install.sh` exports `CLUSTER_CR_MANAGED_BY_HELM=1` and `scripts/05-setup-edge-cluster.sh` then skips rendering it. It hardcoded one fleet-wide NodePort pair (30443 / 30132), so a second site was impossible, and `persistence: emptyDir`, which the chart refuses. Edit the chart values, not this file |
| `scripts/00-common.sh` → `stage_edge_join_payload()` | extracts the cluster CA from Secret `<cluster>-ca` in namespace `<cluster>`, mints the server cert with the right SANs (localhost / kubernetes[.default[.svc[.cluster.local]]] / 10.96.0.1 / `<node-ip>`, `-days 3650`), then attempts to shred its temporary CA-key copy, with an unlink fallback. The original CA key remains in the management Secret; the worker payload contains only the CA certificate and the generated server key |
| `scripts/06-join-edge-worker.sh` (`join: ssh`) and `scripts/06b-make-bootstrap.sh` (`join: bundle`) | delivery only. 06 scps `k0s-ca.crt` + `haproxy-server.pem` + `join-token` to the edge; 06b tars the same three files into the carry-over bundle. Both call the one function above, so both paths use the same SAN/signing procedure. Each invocation generates a fresh key and certificate; the resulting bytes need not match |
| `scripts/files/edge-join.sh` (step 5 of 6, runs **on** the edge) | `install -m 0644` puts them in place as `/etc/haproxy/certs/ca.crt` and `/etc/haproxy/certs/server.pem` |

Historical generated-config example (`edge-dev`; capture date not recorded).
The current generated file is not verified (2026-11-10); inspect the child
DaemonSet before relying on its exact syntax. The chart still configures a
per-edge API host and the join script supplies the certificates shown here:
```
frontend kubeapi_front
    bind [::]:7443 v4v6 ssl crt /etc/haproxy/certs/server.pem
    mode tcp
backend kubeapi_back
    mode tcp
    server kube_api k0s-edge-dev.aisedge.local:443 ssl verify required \
                    ca-file /etc/haproxy/certs/ca.crt \
                    sni str(k0s-edge-dev.aisedge.local)
```

## Operations

```bash
# DS state
KUBECONFIG=kubeconfig-edge-dev kubectl get ds -n default k0smotron-haproxy

# Pod logs (look for cert/upstream errors)
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n default \
  -l app=k0smotron-haproxy --tail=30

# Test that the local endpoint is alive on the worker
# A TLS-verified response (including 401/403 without credentials) checks reachability.
ssh edge "curl -v --cacert /etc/haproxy/certs/ca.crt https://127.0.0.1:7443/version 2>&1 | head -10"
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
| `server.pem` permissions wrong | Pod CrashLoops with "cannot open file" | `scripts/files/edge-join.sh` step 5 does `install -m 0644` explicitly (and `chmod 0755` on the directory) — 0644 rather than 0600 because the haproxy container runs as non-root and must read them |
| `server.pem` SANs missing critical names | Pods get "x509: cert valid for X, not Y" | We enumerate kubernetes / kubernetes.default[.svc[.cluster.local]] / 10.96.0.1 / 127.0.0.1 / `<node-ip>` |
| `server.pem` signed by the wrong CA | Pods get "unknown authority" | We sign with the **cluster's** internal CA (extracted from Secret `<cluster>-ca`), not ais-edge-ca |
| haproxy down | Every in-cluster API call fails; whole cluster degrades | Pod auto-restarts; on a single-worker edge there's no HA |
| Upstream (mgmt nginx) down | haproxy returns connection errors | Worker components retry; alerts fire |
| Certs expire | TLS handshake fails | The helper requests 3650 days for the server certificate, but does not clamp that request to the issuer expiry. Check both certificates. Trust cannot outlive a valid chain, and this hostPath certificate has no automated renewal here |

## Replacements / future

- Patching k0smotron to consume an existing cert/Secret instead of
  the hostPath dance — would be cleaner but k0smotron doesn't expose
  that knob today
- Replacing haproxy with envoy or a custom proxy — possible but
  k0smotron does this for us; rolling our own loses upstream support
- Review TLS client-authentication requirements before adding mTLS to this
  proxy. The example HAProxy backend has `verify required` for the server
  certificate but no client `crt` argument. That example therefore does not
  establish HAProxy client-certificate authentication. The generated current
  configuration is not verified (2026-11-10).

## Future enhancements

- Automate hostPath server-certificate renewal and check issuer expiry.
  The current helper requests 3650 days, independently of remaining CA life;
  it is not a certificate rotation controller.
- Verify behaviour on multi-worker edges (the DS would put one haproxy
  per node, and EndpointSlice would round-robin between them)
- Track haproxy's own metrics — it can expose Prometheus on a stats
  port; not currently scraped because of complexity inside k0smotron's
  generated manifest
