# cert-manager

## Overview

[cert-manager](https://cert-manager.io/) is the standard Kubernetes
certificate-issuance and -rotation controller. It watches `Issuer` /
`ClusterIssuer` and `Certificate` CRDs and creates / renews TLS
Secrets automatically.

## Role in this stack

The full TLS lifecycle: bootstraps our root CA (`ais-edge-ca`, or issues
from an offline-signed intermediate — see "CA modes"), issues every
server certificate signed by it (Loki, Grafana, SeaweedFS) **and** the
per-edge client certificates for the Loki push path. Each `Certificate`
resource is auto-renewed 30 days before expiry — no manual rotation.

## Issuer chain

```
mgmt-selfsigned-bootstrap (ClusterIssuer)   # <release>-selfsigned-bootstrap
        │ signs                             # selfSigned mode only
        ▼
ais-edge-ca (Certificate, isCA=true, RSA 4096, 10y)
   in namespace certManager.clusterResourceNamespace (default cert-manager)
   stored in Secret cert-manager/ais-edge-ca-secret
        │ becomes the CA for
        ▼
ais-edge-ca (ClusterIssuer)  ─── signs ───►
        ├── seaweedfs-tls             (1y, auto-renew at -30d)
        ├── grafana-tls               (1y, auto-renew at -30d)
        ├── loki-tls                  (1y, auto-renew at -30d)
        ├── mgmt-loki-client-ca       (1y, auto-renew at -30d) — anchor only
        └── <edge>-loki-client        (90d, renewBefore 30d)   — one per edge
```

**Names, because they moved.** The CA ClusterIssuer is `ais-edge-ca`, not
`ais-edge-ca-issuer` — it takes its name from `certManager.issuer` via the
`mgmt.caIssuerName` helper, so it deliberately shares the name with the CA
`Certificate` above it. (When `certManager.issuer` selects a
`letsencrypt-*` ACME issuer, the CA path still renders, falling back to the
fixed name `ais-edge-ca`, because the edge trust anchor is distributed from
it regardless.) The bootstrap issuer is **release-prefixed** by default —
`mgmt-selfsigned-bootstrap` for the release `install.sh` creates. A
brownfield cluster that already has a bare `selfsigned-bootstrap` must pin
`certManager.ca.bootstrapIssuerName` to it: that name is part of the CA
Certificate's `issuerRef`, and a mismatch on adoption makes cert-manager
**re-issue the root**, invalidating every ca-bundle already distributed to
every edge. The same trap applies to `certManager.ca.commonName`, which
cert-manager treats as desired state; changing it needs
`allowCommonNameChange: true` and a fleet-wide redistribution.

The last two leaves are the Loki push mTLS pair, both issued from this same
CA on purpose — two copies of the issuer-selection logic is exactly how the
client certs would end up signed by a CA the push Ingress does not verify
against:

- **`mgmt-loki-client-ca`** is a trust *anchor*, not a credential. Nothing
  ever presents it; its `commonName` is `loki-push-client-ca-anchor`
  specifically so it cannot collide with an edge name and be accepted as a
  site. Only its `ca.crt` matters — that is what the Loki push Ingress
  verifies client certificates against. Rendered only when
  `observability.loki.push.requireAuth`.
- **`<edge>-loki-client`** is one Certificate per `edges[]` entry, client
  auth only, `rotationPolicy: Always`. 90 days rather than a year on
  purpose: this is the one certificate whose renewal is exercised
  end-to-end by cert-sync, and a yearly cadence means the distribution path
  is proven once a year — which is the same as not proven. `CertSyncStale`
  covers the gap.

## CA modes

`certManager.ca.mode` selects between two shapes:

| Mode | What the cluster holds | What renders |
|---|---|---|
| `selfSigned` (default) | the root itself, generated in-cluster, key in a Secret on the management node | the bootstrap ClusterIssuer, the `ais-edge-ca` Certificate, and the CA ClusterIssuer. Right for dev and single-site tier-1 |
| `intermediate` | only an offline-signed intermediate, supplied as an existing Secret named by `certManager.ca.intermediate.secretRef` (keys `tls.crt`, `tls.key`, and `ca.crt` = the **root**, which is what edges pin) | **no** bootstrap Issuer and **no** CA Certificate — only the `ais-edge-ca` ClusterIssuer. Recommended for a multi-site fleet |

That absence in `intermediate` mode is the point: the root's private key is
offline, so nothing in this cluster *can* sign a CA certificate, and a
template that tried would either produce a second unrelated root or fail.
The Secret is created by hand from the ceremony in
[`../ca-ceremony.md`](../ca-ceremony.md), is not Helm-owned, is never in
git, and `helm uninstall` cannot remove it.

**What the split does and does not buy**, stated narrowly. If the
management node is compromised, the attacker already holds the staged
imaging, the XNAT credentials and every child cluster kubeconfig — the CA
is not the crown jewel, and moving the root offline protects none of that.
What it buys is **recoverability**: edges trust the *root*, so replacing a
compromised or expiring intermediate is an in-cluster operation they never
observe, instead of hand-carrying a new trust anchor to every site.

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
- Installed with **Helm**, by `install.sh` step 2/7, from the tarball
  vendored at `charts/mgmt/charts/cert-manager-v1.20.3.tgz` — pinned, and
  no network needed:
  `helm upgrade --install cert-manager … --namespace cert-manager
  --create-namespace --set crds.enabled=true --wait`
- Installed **out of band, before the management release**, even though
  cert-manager is a pinned dependency in `charts/mgmt/Chart.yaml` — which
  is why `certManager.enabled` defaults to **false**. The dependency is
  circular otherwise, and the loop is not obvious: the management chart
  renders `Cluster` objects → the k0smotron CRDs declare a conversion
  webhook for that version → the webhook is served by the k0smotron
  operator → the operator will not start until cert-manager issues its
  serving certificate → and cert-manager would be installed by the
  management chart. Installing with `certManager.enabled=true` fails on
  the first `Cluster` object with `dial tcp …:443: connect: connection
  refused`, which reads as a networking problem rather than an ordering
  one
- The step also **adopts** any pre-existing cert-manager CRDs into the
  Helm release (stamping `app.kubernetes.io/managed-by` +
  `meta.helm.sh/release-*`), because Helm refuses to take ownership of
  objects that lack that metadata — which is the state of any cluster
  where cert-manager was previously installed with `kubectl apply`,
  including a re-run of this installer after a partial failure. Deleting
  the CRDs instead would take every Certificate, Issuer and
  CertificateRequest with them, including the CA that signs the fleet
- Metrics: `:9402/metrics` on each pod — but see the Configuration table:
  the metrics Service and ServiceMonitor that make it *scrapeable* are
  created by this chart, not by cert-manager

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/templates/cert-issuers.yaml` | bootstrap Issuer + CA Certificate + CA ClusterIssuer, in both CA modes. This is what used to be `scripts/02b-bootstrap-ca.sh`, absorbed into Helm step 4 |
| `charts/mgmt/templates/seaweedfs.yaml` | seaweedfs-tls Certificate |
| `charts/mgmt/templates/observability.yaml` | grafana-tls, loki-tls, the `<release>-loki-client-ca` anchor and the per-edge `<edge>-loki-client` Certificates |
| `charts/mgmt/templates/cert-manager-monitoring.yaml` | the metrics Service (`:9402`) + ServiceMonitor. Without it `certmanager_certificate_*_timestamp_seconds` has **no series** and `CARotationDue` / `CertificateExpiringSoon` / `CertificateRenewed` cannot fire at all. Gated on `observability.enabled` **and** `certManager.monitoring.enabled` |
| `charts/mgmt/templates/cert-sync.yaml` | distributes the CA **public** half — one CronJob per edge copying `ca.crt` out of `cert-manager/ais-edge-ca-secret` into the edge's `ca-bundle` Secret, plus that edge's `<edge>-loki-client` cert and key. The destination namespace is per-site (`certSync.secrets[].destination`), not fixed |
| `scripts/rotate-ca.sh` | bundled-CA rotation (Phase 1 + Phase 2 transition) |

`certSync.secrets[].source.namespace` **must** equal
`certManager.clusterResourceNamespace`: cert-manager writes the CA Secret
into the namespace it runs in, and pointing this one namespace away makes
cert-sync log `sync_failed` forever while the edge pods that mount
`ca-bundle` never start. Both charts refuse to render on a mismatch rather
than let that happen.

## Operations

```bash
# All certs in the cluster
kubectl get certificates -A

# Specific cert details. The leaf certs live in the management release
# namespace, ais-mgmt — NOT in a per-component namespace.
kubectl describe certificate -n ais-mgmt seaweedfs-tls

# Force a renewal (cert-manager re-issues immediately)
kubectl delete secret -n ais-mgmt seaweedfs-tls

# The operator's local copy of the CA public cert — what the openssl check
# below verifies against. scripts/rotate-ca.sh writes this file too, but
# only during a rotation, so extract it once up front.
kubectl -n cert-manager get secret ais-edge-ca-secret \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ais-edge-ca.crt

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

- mTLS on the **S3 / SeaweedFS** path. The per-edge client certificates
  described above authenticate only the Loki *push*; the edge uploader
  still reaches SeaweedFS with an access key over one-way TLS, so a
  leaked key is usable from anywhere. (Edge → mgmt client certs
  themselves are no longer future work: `<edge>-loki-client` is rendered
  by `charts/mgmt/templates/observability.yaml` and delivered by the
  cert-sync CronJob, which is exactly the "per-edge Certificate + a way
  to deliver the private key" this bullet used to ask for.)
- Cert-manager Approvers via Kyverno — automatically reject Certificates
  that don't match an allow-listed Issuer
- ACME http-01 / dns-01 issuer for public hostnames once we have any
