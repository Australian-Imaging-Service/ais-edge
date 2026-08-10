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
seaweedfs.aisedge.local   →  TLS terminate  →  svc/seaweedfs:8333  (HTTP, in-cluster)
k0s.aisedge.local         →  ssl-passthrough →  kmc-edge-dev-nodeport:30443 (mTLS to k0s API)
konnect.aisedge.local     →  ssl-passthrough →  kmc-edge-dev-nodeport:30132 (gRPC tunnel)
grafana.aisedge.local     →  TLS terminate  →  svc/...-grafana:80
loki.aisedge.local        →  TLS terminate  →  svc/loki:3100
```

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
- Namespace: `ingress-nginx`
- Workload: Deployment `ingress-nginx-controller` (single replica;
  hostNetwork pods can't be load-balanced via Service)
- Image: from helm chart default (current `ingress-nginx-controller`)
- Metrics: `:10254/metrics`

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/nginx-ingress-values.yaml.tpl` | helm values — hostNetwork, ssl-passthrough enabled, body size limits |
| `scripts/02c-install-nginx-ingress.sh` | helm install |
| Various `*-ingress.yaml.tpl` files | per-service Ingress definitions with the right TLS / passthrough annotations |

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

```bash
# Pod state
kubectl get pods -n ingress-nginx

# Live config (full nginx.conf)
POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o name | head -1)
kubectl exec -n ingress-nginx $POD -- cat /etc/nginx/nginx.conf | head -60

# Reach the host port
sudo ss -tln | grep :443

# Test a route from outside
curl -kv --resolve grafana.aisedge.local:443:$(MGMT_IP) \
  https://grafana.aisedge.local/api/health

# Look at access logs (per-request lines)
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20
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
| Misconfigured ssl-passthrough | TLS terminate at nginx breaks mTLS-only backends | Only the k0s + konnect Ingresses use passthrough; verified via curl + s_client |
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
