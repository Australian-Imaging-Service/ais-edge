# cert-manager

## Overview

[cert-manager](https://cert-manager.io/) is the standard Kubernetes
certificate-issuance and -rotation controller. It watches `Issuer` /
`ClusterIssuer` and `Certificate` CRDs and creates / renews TLS
Secrets automatically.

## Role in this stack

Certificate issuance and scheduled leaf renewal: bootstraps our root CA (`ais-edge-ca`, or issues
from an offline-signed intermediate — see "CA modes"), issues every
server certificate signed by it (Loki, Grafana, SeaweedFS) **and** the
per-edge client certificates for the Loki push path. Each `Certificate`
for a server or client leaf requests renewal 30 days before expiry. Root
renewal uses a different interval, and an externally supplied intermediate
has no chart-managed Certificate. CA replacement, trust distribution and
consumer reloads still need a plan; renewal is not guaranteed during outages.

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
        ├── <edge>-loki-client        (90d, renewBefore 30d)   — one per edge
        ├── mgmt-s3-client-ca         (1y, auto-renew at -30d) — anchor only
        └── <edge>-s3-client          (90d, renewBefore 30d)   — one per edge
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

The last four leaves are two mTLS pairs — one for the Loki push path, one
for the SeaweedFS upload path — all issued from this same CA on purpose — two copies of the issuer-selection logic is exactly how the
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
- **`mgmt-s3-client-ca`** is the same kind of anchor for the SeaweedFS S3
  endpoint, `commonName` `s3-upload-client-ca-anchor`. Rendered only when
  `seaweedfs.ingress.clientCerts.issue`.
- **`<edge>-s3-client`** is one Certificate per `edges[]` entry, client auth
  only, `rotationPolicy: Always`, same 90-day cadence and same reasoning.
  cert-sync delivers it as `s3-client-tls`; the edge presents it when
  `upload.s3.requireClientCert` is set.

**Why two anchor Secrets and not one.** The separate Secrets let the two
Ingresses refer to their trust material independently. They do **not** create
independent issuing CAs: both anchor leaf certificates and both sets of client
certificates use the same CA issuer. Nginx reads each anchor Secret's `ca.crt`,
not its leaf certificate. Reissuing an anchor leaf under that same CA therefore
does not revoke already issued client certificates or isolate S3 from Loki.

Current access also depends on the Ingress CN allow-list and S3 credentials.
A per-site or per-service revocation procedure must account for those checks
and the shared issuer. Separate trust roots, verified revocation checking or
other explicit access controls would need a separate implementation. The old
independent-revocation claim was incorrect; this source review corrected it
on 2026-11-10.

**The two S3 switches are separate on purpose.**
`seaweedfs.ingress.clientCerts.issue` mints and distributes;
`clientCerts.require` puts `auth-tls-verify-client: on` across the Ingress.
Turning verification on before the certificates have landed breaks every
upload with an indirect error. In the historical observation (run date not
recorded; not verified 2026-11-10), nginx answered `400 No required SSL
certificate was sent` with HTML and rclone reported an S3 XML parse failure.
That is an application response from that configuration, not a TLS 1.3 rule
that prevents a server from rejecting client authentication;
so the uploader logs `endpoint_failed` and it reads as an endpoint that is not
listening. The rollout is therefore: `issue`
→ wait for cert-sync → confirm `s3-client-tls` exists on every edge →
`upload.s3.requireClientCert` on each edge → `require`. The chart refuses
`require` without `issue`, and refuses `issue` without a `certSync` entry
carrying the certificate, but no template can see whether a Secret actually
landed — that step is the operator's.

## CA modes

`certManager.ca.mode` selects between two shapes:

| Mode | What the cluster holds | What renders |
|---|---|---|
| `selfSigned` (default) | the root itself, generated in-cluster, key in a Secret on the management node | the bootstrap ClusterIssuer, the `ais-edge-ca` Certificate, and the CA ClusterIssuer. Default management-cluster bootstrap mode. Tier-1 does not deploy this management chart |
| `intermediate` | only an offline-signed intermediate, supplied as an existing Secret named by `certManager.ca.intermediate.secretRef` (keys `tls.crt`, `tls.key`, and `ca.crt` = the **root**, which is what edges pin) | **no** bootstrap Issuer and **no** CA Certificate — only the `ais-edge-ca` ClusterIssuer. Recommended for a multi-site fleet |

That absence in `intermediate` mode is the point: the root's private key is
offline. The chart does not create or renew the issuing intermediate. Its
key still signs certificates in the cluster, so key protection and the
intermediate's constraints remain important. Keeping the root offline does
not make the online intermediate harmless if compromised.
The Secret is created by hand from the ceremony in
[`../ca-ceremony.md`](../ca-ceremony.md), is not Helm-owned and must not be stored unencrypted in git. Helm does not
delete that manually created Secret as a release resource; deleting its
namespace, resetting the cluster or running broader teardown can still remove it.

**What the split does and does not buy**, stated narrowly. If the
management node is compromised, the attacker already holds the staged
imaging, the XNAT credentials and every child cluster kubeconfig — the CA
is not the crown jewel, and moving the root offline protects none of that.
What it buys is **recoverability**: edges trust the *root*, so replacing a
compromised or expiring intermediate is an in-cluster operation they never
need not change their root trust anchor for, provided the new chain is valid
and distributed correctly. It does not revoke an old compromised intermediate
while clients still trust it through that root. Reissue affected leaves and
verify rejection of the compromised credentials as part of incident recovery.

The k0smotron-managed k0s API + konnectivity have a **separate** CA
chain managed by k0smotron itself (Secret `<cluster>-ca`). Two
independent trust roots; cert-manager handles ours, k0smotron handles
its own.

## What cert-manager has access to

- **Cluster API** (its ServiceAccount has the permissions in the
  upstream RBAC bundle): create/update Secrets, read Issuers, watch
  Certificates
- In self-signed mode, the **CA private key** lives in the configured root
  Secret, default `cert-manager/ais-edge-ca-secret`. Intermediate mode uses
  the separately named issuing Secret and keeps the root key offline. These
  signing keys require protection alongside XNAT and child-cluster credentials.
- The CA issuer signs locally, but ACME needs outbound issuer and DNS-provider
  access. The chart does not enforce a blanket no-egress policy.

## Where it runs

- Cluster: management cluster only
- Namespace: `cert-manager`
- Workloads: 3 Deployments (`cert-manager`, `cert-manager-cainjector`,
  `cert-manager-webhook`)
- Installed with **Helm**, by `install.sh` step 2/7, from the tarball
  vendored at `charts/mgmt/charts/cert-manager-v1.20.3.tgz`. The chart archive
  is local, but container image pulls and external issuer operations can still
  require network access:
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
| `charts/mgmt/templates/seaweedfs.yaml` | seaweedfs-tls Certificate, plus the `<release>-s3-client-ca` anchor and the per-edge `<edge>-s3-client` Certificates when `seaweedfs.ingress.clientCerts.issue` is set |
| `charts/mgmt/templates/observability.yaml` | grafana-tls, loki-tls, the `<release>-loki-client-ca` anchor and the per-edge `<edge>-loki-client` Certificates |
| `charts/mgmt/templates/cert-manager-monitoring.yaml` | the metrics Service (`:9402`) + ServiceMonitor. Without it `certmanager_certificate_*_timestamp_seconds` has **no series** and `CARotationDue` / `CertificateExpiringSoon` / `CertificateRenewed` cannot fire at all. Gated on `observability.enabled` **and** `certManager.monitoring.enabled` |
| `charts/mgmt/templates/cert-sync.yaml` | distributes the CA **public** half — one CronJob per edge copying `ca.crt` out of `cert-manager/ais-edge-ca-secret` into the edge's `ca-bundle` Secret, plus that edge's `<edge>-loki-client` cert and key, and — when S3 mTLS is enabled — its `<edge>-s3-client` cert and key. The destination namespace is per-site (`certSync.secrets[].destination`), not fixed |
| `scripts/rotate-ca.sh` | historical bundled-CA procedure. Its hardcoded issuer and workload names do not match all current defaults; see the known gaps in [ca-ceremony.md](../ca-ceremony.md) before use |

The **CA source entry** in `certSync.secrets` must use
`certManager.clusterResourceNamespace`, where the CA ClusterIssuer resolves
its Secret. Client leaf certificates live in the management release namespace
and use different source entries. The current cert-sync guard is narrower: it checks only
`certManager.ca.secretName` and derives its expected namespace from
`certManager.enabled`. It does not validate all intermediate-mode wiring or
all `clusterResourceNamespace` overrides. Check those entries explicitly. This is not a rule that every copied Secret must share one
namespace, nor that cert-manager always uses its own Pod namespace.

## Operations

For manual renewal, follow the [cert-manager Certificate guide](https://cert-manager.io/docs/usage/certificate/).
The [CA issuer guide](https://cert-manager.io/docs/configuration/ca/) explains
issuer expiry, leaf reissuance and external revocation responsibilities.

```bash
# All certs in the cluster
kubectl get certificates -A

# Specific cert details. The leaf certs live in the management release
# namespace, ais-mgmt — NOT in a per-component namespace.
kubectl describe certificate -n ais-mgmt seaweedfs-tls

# Request leaf renewal with cmctl; wait for issuance and check the served cert.
# Do not delete the serving Secret as a routine renewal procedure.
cmctl renew -n ais-mgmt seaweedfs-tls

# The operator's local copy of the CA public cert — what the openssl check
# below verifies against. scripts/rotate-ca.sh writes this file too, but
# only during a rotation, so extract it once up front.
kubectl -n cert-manager get secret ais-edge-ca-secret \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ais-edge-ca.crt

# Inspect the served cert from outside (verify SANs, expiry)
echo | openssl s_client -servername seaweedfs.aisedge.local \
  -connect "${MGMT_IP}:443" -CAfile ais-edge-ca.crt \
  -verify_return_error -verify_hostname seaweedfs.aisedge.local \
  | openssl x509 -noout -subject -dates -ext subjectAltName

# Issuer health
kubectl get clusterissuer
```

## Benefits

- **Scheduled renewal** reduces manual leaf issuance. Issuer failures,
  expired CA chains, distribution delays and consumers that do not reload
  can still cause outages; keep renewal and cert-sync alerts enabled.
- **Standard CRDs** — every Kubernetes engineer knows them
- **Multi-issuer** — drop in a Let's Encrypt ACME issuer later if we
  ever want public CA chain on the management ingress
- **Widely deployed** — used by every major K8s distro

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| ais-edge-ca-secret deletion | All edges lose trust on next renewal cycle | Back up the Secret to offline storage; document the recovery procedure |
| Webhook down during apply | Certificate and Issuer API operations can fail | Check webhook readiness, Service endpoints, network reachability and serving certificates. Restarting a Pod alone is not a guaranteed repair |
| CA expiry | A leaf can become unverifiable when its issuer expires even if the leaf has time left | `CARotationDue` selects the CA Certificate within 365 days of expiry; it needs that metric to exist. An external intermediate has no chart-created Certificate metric. Track every issuer expiry and use the reviewed rotation procedure before the chain expires |
| Renewal failure | Server cert expires; clients reject | `CertificateExpiringSoon` fires a day after a certificate's renewal time passes without a renewal, or within 14 days of expiry. It no longer fires at 60 days: that overlapped the 30-day auto-renew window, so healthy 90-day certificates alerted daily for a month each cycle |
| Compromised issuing key | An attacker can mint credentials under a trusted CA | Contain the compromise, restore a trusted signing environment and follow a reviewed replacement/revocation plan. Planned overlap rotation alone still trusts the old CA during overlap and does not prove attacker credentials are rejected |

## Replacements / future

- **Let's Encrypt / public ACME issuer** — for the operator-facing
  Grafana ingress when it's reachable on a public hostname. The data
  plane stays on ais-edge-ca because edges aren't on a public domain
- **Cloud KMS-backed CA** (AWS PCA, GCP CAS) — if compliance requires
  the CA private key in HSM. cert-manager has issuers for both
- **HashiCorp Vault PKI** — if the org already runs Vault for secrets
  management. Same workflow, different issuer

## Future enhancements

- **S3 mTLS is implemented**, reviewed 2026-11-10. The chart can issue
  per-edge S3 client certificates, distribute them with cert-sync and require
  them at the SeaweedFS Ingress. It is optional; an access key over server TLS
  remains the path where the client-certificate switches are off. Follow the
  issue, distribute, present, require sequence above and verify every edge
  before enforcement. The old future-work item is retained here as resolved.
- Cert-manager Approvers via Kyverno — automatically reject Certificates
  that don't match an allow-listed Issuer
- **ACME DNS-01 support is implemented** by `cert-issuers.yaml` when
  `certManager.issuer` selects `letsencrypt-*` and a solver is configured.
  HTTP-01 is not wired by this chart. Validate provider credentials, DNS and
  the selected issuer before relying on public certificate renewal.
