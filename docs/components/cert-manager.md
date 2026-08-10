# cert-manager

## Overview

[cert-manager](https://cert-manager.io/) is the standard Kubernetes
certificate-issuance and -rotation controller. It watches `Issuer` /
`ClusterIssuer` and `Certificate` CRDs and creates / renews TLS
Secrets automatically.

## Role in this stack

The full TLS lifecycle: bootstraps our self-signed root CA
(`ais-edge-ca`) and issues every server certificate (Loki, Grafana,
SeaweedFS) signed by it. Each `Certificate` resource is auto-renewed
30 days before expiry — no manual rotation.

## Issuer chain

```
selfsigned-bootstrap (ClusterIssuer)
        │ signs
        ▼
ais-edge-ca (Certificate, isCA=true, RSA 4096, 10y)
   stored in Secret cert-manager/ais-edge-ca-secret
        │ becomes the CA for
        ▼
ais-edge-ca-issuer (ClusterIssuer)  ─── signs ───►
        ├── seaweedfs-tls            (1y, auto-renew at -30d)
        ├── grafana-tls              (1y, auto-renew at -30d)
        └── loki-tls                 (1y, auto-renew at -30d)
```

The k0smotron-managed k0s API + konnectivity have a **separate** CA
chain managed by k0smotron itself (Secret `<cluster>-ca`). Two
independent trust roots; cert-manager handles ours, k0smotron handles
its own.

## What cert-manager has access to

- **Cluster API** (its ServiceAccount has the permissions in the
  upstream RBAC bundle): create/update Secrets, read Issuers, watch
  Certificates
- The **CA private key** lives in Secret `cert-manager/ais-edge-ca-secret`
  — this is the most sensitive material in the whole stack
- **No outbound network** — runs purely against the cluster API

## Where it runs

- Cluster: management cluster only
- Namespace: `cert-manager`
- Workloads: 3 Deployments (`cert-manager`, `cert-manager-cainjector`,
  `cert-manager-webhook`)
- Installed via `kubectl apply -f cert-manager.yaml` (NOT helm) —
  k0smotron requires it for its own webhooks
- Metrics: `:9402/metrics` on each pod

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/templates/cert-issuers.yaml` | bootstrap + CA + CA Issuer |
| `charts/mgmt/templates/seaweedfs.yaml` | seaweedfs-tls Certificate |
| `charts/mgmt/templates/observability.yaml` | grafana-tls + loki-tls Certificates |
| `scripts/02b-bootstrap-ca.sh` | applies the Issuers + CA, exports the public cert |
| `scripts/rotate-ca.sh` | bundled-CA rotation (Phase 1 + Phase 2 transition) |

## Operations

```bash
# All certs in the cluster
kubectl get certificates -A

# Specific cert details
kubectl describe certificate -n seaweedfs seaweedfs-tls

# Force a renewal (cert-manager re-issues immediately)
kubectl delete secret -n seaweedfs seaweedfs-tls

# Inspect the served cert from outside (verify SANs, expiry)
echo | openssl s_client -servername seaweedfs.aisedge.local \
  -connect 203.101.224.240:443 -CAfile ais-edge-ca.crt 2>/dev/null \
  | openssl x509 -noout -subject -dates -ext subjectAltName

# Issuer health
kubectl get clusterissuer
```

## Benefits

- **Auto-renewal** — set-and-forget; no PagerDuty pages at 03:00 about
  expired certs
- **Standard CRDs** — every Kubernetes engineer knows them
- **Multi-issuer** — drop in a Let's Encrypt ACME issuer later if we
  ever want public CA chain on the management ingress
- **Widely deployed** — used by every major K8s distro

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| ais-edge-ca-secret deletion | All edges lose trust on next renewal cycle | Back up the Secret to offline storage; document the recovery procedure |
| Webhook down during apply | New Certificates / Issuers can't be created | The webhook is part of cert-manager itself; pod restart fixes it |
| 10-year CA expiry | Any new cert issued after expiry would chain to a expired CA | `CARotationDue` alert fires at year 9; `scripts/rotate-ca.sh` orchestrates the bundled transition |
| Renewal failure | Server cert expires; clients reject | `CertificateExpiringSoon` alert fires 60 days before (overlapping the 30-day auto-renew window) |
| Compromised CA private key | Attacker can mint impostor server certs | Run `rotate-ca.sh` immediately; documented procedure |

## Replacements / future

- **Let's Encrypt / public ACME issuer** — for the operator-facing
  Grafana ingress when it's reachable on a public hostname. The data
  plane stays on ais-edge-ca because edges aren't on a public domain
- **Cloud KMS-backed CA** (AWS PCA, GCP CAS) — if compliance requires
  the CA private key in HSM. cert-manager has issuers for both
- **HashiCorp Vault PKI** — if the org already runs Vault for secrets
  management. Same workflow, different issuer

## Future enhancements

- mTLS for edge → mgmt: cert-manager could also issue *client* certs
  to edges. Requires a per-edge Certificate + a way to deliver the
  private key to edge pods (a Secret pushed by the cert-sync CronJob)
- Cert-manager Approvers via Kyverno — automatically reject Certificates
  that don't match an allow-listed Issuer
- ACME http-01 / dns-01 issuer for public hostnames once we have any
