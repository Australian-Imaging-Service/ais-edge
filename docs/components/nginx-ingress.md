# nginx-ingress

## Overview

[ingress-nginx](https://github.com/kubernetes/ingress-nginx) is the
official Kubernetes ingress controller built on nginx. It watches
`Ingress` resources and reconfigures nginx to route traffic according
to the host + path rules in those resources.

## Role in this stack

The single TLS terminator + SNI router on the management host. Every
edge → mgmt connection lands on `*:443` of the management node, which
nginx-ingress owns directly via `hostNetwork: true`. nginx reads the
SNI from the TLS ClientHello and forwards to the right backend:

```
seaweedfs.aisedge.local              →  TLS terminate   →  svc/mgmt-seaweedfs:8333 (HTTP, in-cluster)
grafana.aisedge.local                →  TLS terminate   →  svc/mgmt-grafana:80
loki.aisedge.local                   →  TLS terminate   →  svc/mgmt-loki:3100
k0s-edge-dev.aisedge.local           →  ssl-passthrough →  kmc-edge-dev-nodeport:30443 (mTLS to k0s API)
konnectivity-edge-dev.aisedge.local  →  ssl-passthrough →  kmc-edge-dev-nodeport:30132 (gRPC tunnel)
```

Note the shape of the last two: the k0s API and konnectivity hostnames are
**per-edge**, `<apiPrefix>-<name>.<domain>` and
`<konnectivityPrefix>-<name>.<domain>`, with the prefixes defaulting to `k0s`
and `konnectivity` (`charts/mgmt/values.yaml:222-227`,
`charts/mgmt/templates/edge-clusters.yaml:19-35`). A site can pin its own
names per edge via `edges[].apiHost` / `edges[].konnectivityHost`. Fleet-wide
`hostnames.k0sApi` / `hostnames.konnectivity` keys are gone and their return
is a render-time failure (`edge-clusters.yaml:85-87`): they gave every edge
the same two hostnames, so the second site's Ingress claimed a hostname the
first one already owned and its workers were silently routed to the wrong
API server. `charts/mgmt/values.yaml:48-51` carries the same warning next to
the surviving fleet-wide `hostnames:` block, which holds only the three
management names above.

The three management backends are release-prefixed subchart Services —
`<release>-seaweedfs`, `<release>-grafana`, `<release>-loki`, i.e. `mgmt-*`
with the release name `install.sh:122` sets. `charts/mgmt/templates/observability.yaml:43-44`
derives the Grafana and Loki names from `.Release.Name` rather than from
`mgmt.fullname` precisely so a `fullnameOverride` cannot point these Ingresses
at a Service that does not exist.

ssl-passthrough vs TLS terminate:
- **TLS terminate** — nginx decrypts, makes routing/auth decisions,
  forwards plain HTTP to backend. Used for HTTP services where we
  control the in-cluster path (seaweedfs, grafana, loki)
- **ssl-passthrough** — nginx is a TCP proxy: reads SNI from the
  ClientHello, picks a backend, pipes the encrypted bytes through
  unchanged. Used for services that do their own mTLS (k0s API,
  konnectivity) where intercepting the TLS would break authentication

## What nginx-ingress has access to

- **Host network namespace** (binds `*:443` directly on the mgmt host)
- **Cluster API** via its ServiceAccount — watches Ingresses,
  Services, Endpoints, Secrets across all namespaces
- **TLS Secrets** referenced by Ingress `spec.tls.secretName`
- **No outbound to the internet** — purely a reverse proxy

## Where it runs

- Cluster: management cluster only
- Namespace: `ais-mgmt` — the management release's namespace
  (`install.sh:121`). The subchart leaves `namespaceOverride: ""` and
  `charts/mgmt` does not set it, so there is no separate `ingress-nginx`
  namespace to look in
- Workload: Deployment `mgmt-ingress-nginx-controller` (single replica;
  hostNetwork pods can't be load-balanced via Service). The name is
  `<release>-ingress-nginx-controller` — substitute your release name if it
  is not the `mgmt` that `install.sh:122` sets
- Image: from the pinned subchart's default — `ingress-nginx/controller`
  `v1.15.1`, from `charts/mgmt/charts/ingress-nginx-4.15.1.tgz`
- Metrics: `:10254/metrics`

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/charts/ingress-nginx-4.15.1.tgz` | the pinned upstream subchart — the controller itself is vendored, not fetched at install time |
| `charts/mgmt/values.yaml:523-550` (`ingress-nginx:` key) | subchart values — hostNetwork, ssl-passthrough enabled, body size limits. Overridable per site in `sites/<site>/values.yaml`, which is layered on with `-f` |
| `charts/mgmt/values.yaml:552-556` (`ingressNginx:` key) | this chart's own view of the ingress: `enabled`, `sslPassthrough`, `proxyBodySize`. Read by `charts/mgmt` templates, not by the subchart |
| `charts/mgmt/templates/seaweedfs.yaml` (S3) and `charts/mgmt/templates/observability.yaml` (Grafana, Loki) | the management Ingress definitions, with the right TLS / body-size / mTLS annotations |
| `charts/mgmt/templates/edge-clusters.yaml` (`spec.ingress`) | the per-edge k0s API + konnectivity Ingresses are not written here — k0smotron creates them itself from this block, with `ssl-passthrough: "true"` and `backend-protocol: "HTTPS"` |

Installed as part of the management release by `install.sh:364-365` (step 4/7),
not by a script of its own — `install.sh:35` records that the old
`scripts/02c-install-nginx-ingress.sh` and the `*-ingress.yaml.tpl` templates
were replaced by the two Helm releases.

Critical settings (in values):
- `controller.hostNetwork: true` — direct binding of host port 443
- `controller.dnsPolicy: ClusterFirstWithHostNet` — pods on hostNetwork
  still resolve in-cluster DNS
- `controller.extraArgs.enable-ssl-passthrough: "true"` — required for
  the k0s API + konnectivity routes
- `controller.config.proxy-body-size: 50g` — DICOM uploads can be huge
- `controller.config.proxy-read-timeout: 3600` — long-lived watches /
  big multipart uploads

## Operations

Everything below runs in `ais-mgmt`, the management release's namespace —
`kubectl -n ingress-nginx` returns NotFound.

```bash
# Pod state
kubectl get pods -n ais-mgmt -l app.kubernetes.io/name=ingress-nginx

# Live config (full nginx.conf)
POD=$(kubectl get pods -n ais-mgmt -l app.kubernetes.io/component=controller -o name | head -1)
kubectl exec -n ais-mgmt $POD -- cat /etc/nginx/nginx.conf | head -60

# Every SNI route currently served, management and per-edge
kubectl get ingress -A

# Reach the host port
sudo ss -tln | grep :443

# Test a route from outside
curl -kv --resolve grafana.aisedge.local:443:$(MGMT_IP) \
  https://grafana.aisedge.local/api/health

# Look at access logs (per-request lines)
kubectl logs -n ais-mgmt -l app.kubernetes.io/component=controller --tail=20
```

## Benefits

- **Standard** — every K8s engineer knows it, debugging knowledge is portable
- **hostNetwork: true** is the simplest way to bind the host's :443
  without a cloud LoadBalancer
- **ssl-passthrough** for backends that do their own mTLS — exactly
  what k0smotron expects
- **Native annotation-driven config** — body size, timeouts, rate
  limits all per-Ingress
- **Built-in Prometheus metrics** with rich per-host labels (request
  rate, latency, status codes)

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Single replica on hostNetwork | Pod restart = brief 443 outage | Acceptable for the staging buffer (edges retry); HA needs dropping hostNetwork + a real LB |
| Misconfigured ssl-passthrough | TLS terminate at nginx breaks mTLS-only backends | Only each edge's `k0s-<name>` + `konnectivity-<name>` Ingresses use passthrough; verified via curl + s_client, and `charts/mgmt/templates/edge-clusters.yaml:72-73` refuses to render at all with `ingressNginx.sslPassthrough: false` |
| Body-size limit too low | Multipart uploads truncated | `proxy-body-size: 50g` set globally + per-Ingress |
| Self-signed cert mistrusted by browsers | Cert warnings | Distribute `ais-edge-ca.crt` to operators or use a public ACME issuer for browser-facing routes |
| Controller pod stuck in Pending | No external access | Single-node mgmt with hostNetwork → can't be scheduled if the node is taint-fenced; the install script waits for Ready |

## Replacements / future

- **HAProxy ingress controller** — same idea, different proxy. We use
  haproxy on the worker side already; could unify, but nginx-ingress
  is more popular for ingress in particular
- **Traefik** — alternative ingress with a more modern UI; less
  mature ssl-passthrough story (though improving)
- **Envoy / Istio gateway** — overkill for our needs, but if we ever
  do mesh-wide observability, Envoy is a logical next step
- **Real cloud LoadBalancer** — drop hostNetwork, use a service of
  type LoadBalancer (requires cloud-controller-manager); allows multiple
  ingress replicas for HA

## Future enhancements

- 2+ replicas behind a kube-vip (or similar) VIP — removes the
  single-replica restriction without a cloud LB
- Rate-limiting per source IP on the public-facing routes
- WAF (ModSecurity) on the Grafana route to harden against direct
  internet exposure

**Done since:** Ingress-level mTLS on the Loki push route. `charts/mgmt`
renders `auth-tls-secret` / `auth-tls-verify-client: on` /
`auth-tls-verify-depth: 2` / `auth-tls-match-cn` on the `loki.<domain>`
Ingress, and each edge presents a cert-manager certificate with its own name
as the CN. `ssl_verify_client` is a server-block directive, so it applies to
that hostname alone — Grafana and the S3 route are untouched. The S3 route
still authenticates with an access key.
