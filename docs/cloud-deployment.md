# Cloud deployment (managed-K8s topology)

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

This document describes the **cloud topology** — the deployment shape used
when the management cluster runs on managed Kubernetes (EKS / GKE / AKS /
OpenStack Magnum / Nectar k0s with Octavia). It is the equivalent of the
on-prem topology described in the main `README.md`, with two specific
substitutions:

| | On-prem | Cloud |
|---|---|---|
| Inbound TLS | `nginx-ingress` on `hostNetwork: true` :443 | Explicit NodePort or LoadBalancer Service behind a provider TCP balancer on :443 |
| Hostname resolution | `hostAliases:` in every pod + `/etc/hosts` on every edge VM | Real public DNS (a domain you own, or `nip.io` for dev) |

The application components, dashboards and alert rules are shared. Cloud
networking, storage classes, identity and access controls still need site
configuration. Memory behavior must be validated for the pinned accessionflow
image; the old fork's memory fix is not a performance guarantee for 0.20.0.

## One key picks the topology

`sites/<site>/values.yaml` is a **Helm values file**, not a shell script.
install.sh reads the handful of fields it needs with a `yaml.safe_load` helper
(`cfg`, install.sh (`cfg()`)) and hands the *same* file to both Helm releases with
`-f`: the management chart at install.sh (`MGMT_RELEASE`, `step 4/7`), each edge chart at
install.sh (`EDGE_KC`, `step 7/7`). Nothing sources it, so there is nothing to `export`; an
`export` line here is not merely inert, it breaks the YAML parse for every key
after it. That is the whole point of the file: one fact, written once, visible
to the installer and to the charts.

```yaml
# sites/<site>/values.yaml
topology: cloud            # onprem | cloud   (default onprem; see charts/mgmt/values.yaml (`topology`))
installMode: existing      # fresh | existing — managed K8s is always `existing`;
                           # it makes step 1/7 verify the cluster it is pointed at
                           # instead of installing k0s (scripts/01-install-k0s.sh (`INSTALL_MODE`))
domain:
  internal: dev-nectar-test.203-101-227-222.nip.io   # or your real zone
  mgmtNodeIP: "<management node IP>"  # distinct from the public LB address
                                      # cloud clients use DNS service hostnames
certManager:
  issuer: ais-edge-ca      # ais-edge-ca | letsencrypt-prod | letsencrypt-staging
                           # the chart uses DNS-01, and we do not control nip.io TXT records;
                           # use the internal CA for that development example
```

`certManager.issuer` selects the rendered server-certificate issuer. A name
with `letsencrypt-` selects ACME and requires the configured email and DNS-01
solver. Other names select the internal CA issuer. This is not a fixed
three-value enumeration. Client certificates use the fleet CA even when the
server uses a public issuer. Render all issuer references and cert-sync source
names before changing the name; a failed Certificate is diagnosed from its
conditions and cert-manager logs, not only from a browser warning.

## Cloud credentials — your shell, not the installer

**What changed.** An earlier design had install.sh source a
`CLOUD_CREDENTIALS_FILE`, run a `provider_guard_<name>` function per provider,
and install a cloud-controller-manager from
`scripts/01b-install-cloud-controller.sh`. None of that was ever written, and
the Helm charts replaced the imperative installer before it could be:
no provider-credential guard is implemented; `SKIP_CLOUD_PREFLIGHT` is a
separate existing environment override, there is no
`scripts/01b-*`, and install.sh's only prerequisite check is for `kubectl`,
`helm` and `python3` (install.sh (`for t in kubectl helm python3`)) plus the SOPS-encrypted site Secrets.
**It does not provision cloud infrastructure or configure cloud controllers.**
It does handle site Secrets, kubeconfigs and join credentials, so this is not
a claim that the installer has no access to sensitive material.

**What to do instead.** Authenticate to your cloud the ordinary way, in your own
shell, before running `./install.sh -y <site>` — and make sure a
supported load-balancer integration is already configured for a LoadBalancer
Service, or supply a manual TCP balancer for NodePort. Nothing in this repo
installs a cloud-controller manager (see "How the LB gets its IP"). The table below still
holds; only its consumer changed. It is now your shell and the CCM's own config,
not a guard inside install.sh.

| Provider | What must be in your environment / the CCM's config |
|---|---|
| `openstack` | Whatever the Keystone openrc.sh from your dashboard already exports (OS_AUTH_URL, OS_REGION_NAME, plus application-credential OR username/password vars). The OCCM you install reads the same facts from its own `cloud.conf` Secret. |
| `aws` | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` + `AWS_REGION`, or leave them unset and let the SDK chain use `~/.aws/credentials`. On EKS the in-tree CCM uses the node IAM role, not these. |
| `gcp` | `GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa.json`, or run `gcloud auth application-default login` and leave the file unset. On GKE the CCM uses the node service account. |
| `azure` | Usually unnecessary — `az login` keeps state in `~/.azure`. For non-interactive: `AZURE_CLIENT_ID/AZURE_TENANT_ID/AZURE_CLIENT_SECRET`. On AKS the CCM uses the cluster's managed identity. |
| `none` | No credentials — you're running with a BYO LB controller (e.g. MetalLB) you installed separately. |

The chart does still carry a `cloud:` values block (`enabled`, `provider`,
`cloudConfigSecretRef`; see charts/mgmt/values.yaml (`cloud`)), but it is **parked**,
and says so itself: "Kept as a values key so templates stay ready, not wired up —
pre-creating an Octavia LB is Terraform work, not Helm work." Setting it today
does not configure a provider. That is separate from `topology: cloud`, which
is implemented with ingress validation, DNS behavior and certificate SAN
selection. The provider examples retain historical provisioning recipes;
current provider end-to-end replay is not verified (2026-11-10).

The installer preflight is limited: it runs after prerequisites. NodePort
checks the first resolved domain address against `mgmtNodeIP`; LoadBalancer
instead searches pod names for `cloud-controller-manager` and checks a node
taint. It can miss managed or differently named controllers, and does not
verify readiness or all DNS records. `verify-live.sh` also currently expects a
LoadBalancer Service even for a supported manual NodePort path, and compares
a resolved IP directly with a status hostname. Treat those as known script
limitations; inspect the actual provider path before interpreting their result.

## What `topology: cloud` actually changes

install.sh is a seven-step installer: `1/7` k0s on the management node
(install.sh (`1/7  k0s management cluster`)), `2/7` cert-manager CRDs + the pinned k0smotron operator (install.sh (`2/7  prerequisites`)),
`3/7` the site Secrets decrypted from SOPS straight into the cluster (install.sh (`3/7  site Secrets`)),
`4/7` the management chart (install.sh (`4/7  helm: management chart`)), `5/7` each edge's child kubeconfig + join
token (install.sh (`5/7`, `JOIN_TOKEN_TTL`)), `6/7` the join itself (install.sh (`6/7`, `bootstrap bundle`) and install.sh (`6/7`, `join the k0s worker over SSH`)), `7/7` the edge chart (install.sh (`7/7`, `helm: edge chart`)).
Its own header notes that steps 4 and 7 "replace what used to be scripts
02b/02c/02d/03/04/07/07b/07c" — so the per-concern step numbers this page used
to cite (01b, 02c, 02d, 07c) no longer name anything.

The principal topology differences are listed below. The current code also
validates the cloud ingress shape, rejects per-edge `exposure: nodePort`, and
runs the limited cloud preflight and lifecycle checks:

* **skips the `/etc/hosts` writes** on the management node (install.sh (`OBS_MARKER`, `INSTALL_TOPOLOGY`))
  and on every edge VM (scripts/05-setup-edge-cluster.sh (`HOSTS_MARKER`, `INSTALL_TOPOLOGY`),
  scripts/06c-post-join.sh (`INSTALL_TOPOLOGY`, `CoreDNS`), scripts/files/edge-join.sh (`TOPOLOGY`)). The child
  cluster's CoreDNS Corefile patch — the `hosts { … }` block that made
  konnectivity-agent able to resolve the management hostnames *from inside a
  pod* ; is skipped by the same branch (scripts/06c-post-join.sh-97), leaving
  CoreDNS at chart defaults so resolution goes CoreDNS `forward` → the kubelet's
  `/etc/resolv.conf` → public DNS.
* **strips the `hostAliases:` block from every edge pod**
  (charts/edge/templates/_helpers.tpl (`edge.validate`, `dataPolicy.originals.fileDrop.reclaim`)). The `{{#ONPREM_ONLY}}` /
  `{{#CLOUD_ONLY}}` markers in scripts/00-common.sh (`render_with_topology()`) do the equivalent for
  the files the join writes on the edge VM.
* **drops the IP SAN from every server certificate** — Loki and Grafana
  (charts/mgmt/templates/observability.yaml (`topology`, `ipAddresses`)) and SeaweedFS
  (charts/mgmt/templates/seaweedfs.yaml (`topology`, `ipAddresses`)). In cloud mode the address a client
  connects to is the LB's, not the serving node's, so an IP SAN would be both
  wrong and unnecessary: cloud certs are pure DNS-named.

Everything else runs unchanged — the same management chart, the same edge chart,
the same observability stack, the same join sequence. Note what is **not** in
that list: nothing in `topology` touches the ingress Service type. The inherited values are `hostNetwork: true` + `service.type: ClusterIP`,
but cloud validation rejects that pair until the site supplies its override
(charts/mgmt/values.yaml (`ingress-nginx.controller.hostNetwork`, `service.type`)); getting a real cloud LoadBalancer is a
separate site-file override, covered below.

## Dev DNS via nip.io (zero registration)

`nip.io` is a free wildcard DNS service. Any hostname like
`<anything>.<ip-with-dashes>.nip.io` resolves to the embedded IP — no
DNS records to register, no domain to buy. Example:

```
loki.dev-nectar-test.203-101-227-222.nip.io   → 203.101.227.222
seaweedfs.dev-nectar-test.203-101-227-222.nip.io → 203.101.227.222
...
```

The historical Nectar test used nip.io and the internal CA. The current
chart's ACME implementation uses DNS-01; an operator who cannot modify nip.io
challenge records cannot use that solver for these names. This does not
establish a universal ACME prohibition for all wildcard-resolver hostnames.
Promotion to production is a few keys in `sites/<site>/values.yaml` — see
"Production swap" below.

## Production swap (when you own a real domain)

`sites/<site>/values.yaml` — the same file, three more keys:

```yaml
# 1. domain.internal — the one string everything else derives from
domain:
  internal: aisedge.example.com

# 2. certManager.issuer — self-signed CA -> Let's Encrypt prod. Any
#    letsencrypt-* value switches cert-issuers.yaml to the ACME branch and
#    selects ACME for server leaves; fleet client certificates retain the CA.
certManager:
  issuer: letsencrypt-prod
  acme:
    # Required whenever issuer is letsencrypt-prod — the chart refuses to
    # render without it (charts/mgmt/templates/_helpers.tpl (`mgmt.validate`, `certManager.acme.email`)).
    email: ops@example.com
    server: https://acme-v02.api.letsencrypt.org/directory
    # 3. The DNS-01 solver, passed through verbatim into solvers[0].dns01.
    #    DNS-01 only: the ingress runs ssl-passthrough for the k0s API and
    #    konnectivity. The chart implements DNS-01; it does not configure
    #    an HTTP-01 solver. An empty solver is also a render-time failure
    #    (charts/mgmt/templates/cert-issuers.yaml (`certManager.acme.dns01Solver`)).
    dns01Solver:
      route53:
        region: ap-southeast-2
        accessKeyIDSecretRef: {name: route53-credentials, key: access-key-id}
        secretAccessKeySecretRef: {name: route53-credentials, key: secret-access-key}
```

The solver block is whatever your provider's cert-manager stanza is —
`route53`, `cloudflare`, `azureDNS`, `cloudDNS`, `rfc2136`, … — copied in as-is;
see cert-manager's DNS-01 documentation for the exact shape. It is spliced in
with `toYaml`, so the nesting you write is the nesting cert-manager sees. (The
old shell installer pasted the stub in with a fixed ten-space `sed` indent,
which silently produced malformed YAML for any stub whose own nesting did not
happen to match — hence the passthrough.)

The Secret the solver names (`route53-credentials` above) is created **by hand,
before the install**, in `certManager.clusterResourceNamespace` (default
`cert-manager`): cert-manager resolves a ClusterIssuer's secret refs only from
that one namespace, not from the release namespace. Getting this wrong does not
error — the Certificates simply stay `Pending`.

If you want to rehearse the plumbing first, set `issuer: letsencrypt-staging`
**and** point `acme.server` at the staging directory; the chart fails the render
if you leave the production URL in place, because staging exists to test without
spending the real rate limit.

Re-run `./install.sh -y <site>` — the site name is a required argument
(install.sh (`SITE_DIR`)). All other code stays the same.

Cloud server certificates use DNS SANs. Keep the client-CA resources and
cert-sync: Loki and optional S3 mTLS still authenticate clients through the
fleet CA. A public server certificate does not remove the explicit CA-file
configuration from Vector or the HTTPS S3 chart guard. Supply the correct
server trust roots, then verify both trust directions and renewal on each
edge before treating the issuer transition as complete.

## How the LB gets its IP

There is no dedicated install step for this — no 01b, no 02c, and no
`nginx-ingress-values-cloud.yaml.tpl` (`manifests/` holds exactly one file,
`manifests/01-management/edge-cluster.yaml.tpl`). ingress-nginx is a **pinned
vendored subchart** of the management chart (charts/mgmt/Chart.yaml,
`charts/mgmt/charts/ingress-nginx-4.15.1.tgz`, condition `ingressNginx.enabled`),
so it goes up inside the single release that step 4/7 installs:

```
helm upgrade --install mgmt charts/mgmt \
    --namespace ais-mgmt --create-namespace \
    -f sites/<site>/values.yaml --timeout 15m
```

Nothing in this repo installs a cloud-controller-manager. On EKS/GKE/AKS the
provider supplies some integration, but the exact controller depends on the
cluster mode and may not be visible as a pod. On self-managed k0s (Nectar included)
you install the OCCM and its `cloud.conf` Secret out of band, before the install,
as noted above.

**The knob is the subchart block, and `loadBalancerIP` alone is not enough.**
The chart's on-prem defaults are `hostNetwork: true` (charts/mgmt/values.yaml (`ingress-nginx.controller.hostNetwork`))
and `service.type: ClusterIP` (charts/mgmt/values.yaml (`ingress-nginx.controller.service.type`)), and `loadBalancerIP` is inert on a
ClusterIP Service. Override the whole block in the site file, exactly as the
CAUTION at charts/mgmt/values.yaml (`ingress-nginx.controller`) prescribes:

```yaml
# sites/<site>/values.yaml
ingress-nginx:            # the subchart's own values, by chart name
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst      # not ClusterFirstWithHostNet — no host netns now
    service:
      type: LoadBalancer
      loadBalancerIP: "203.101.227.222"
```

Keep `extraArgs.enable-ssl-passthrough: "true"` (the chart default): the k0s API
and konnectivity retain TLS to their intended endpoints. Their route must
not be converted into the terminated HTTP path used for Loki and S3.

> CAUTION — decoy key. The parent chart's top-level
> `ingressNginx` now carries only `enabled` and `sslPassthrough` — the two keys
> this chart actually reads. A `loadBalancerIP` alongside them was read by no
> template and has been removed: on cloud it would have been set to a floating
> IP, ignored, and the load balancer would have come up on a different address
> than `domain.internal` names, with nothing to say so. Set it on the subchart
> under `ingress-nginx.controller.service`, using the address field or
> provider annotation supported by the selected controller.

```
Operator runs:
  $ openstack floating ip create qld    # → 203.101.227.222
                          ↓
  sites/<site>/values.yaml:
    ingress-nginx.controller.hostNetwork: false
    ingress-nginx.controller.service.type: LoadBalancer
    ingress-nginx.controller.service.loadBalancerIP: 203.101.227.222
                          ↓
  ./install.sh -y <site>  →  step 4/7
    helm upgrade --install mgmt charts/mgmt -f sites/<site>/values.yaml
    (ingress-nginx 4.15.1 subchart → Service mgmt-ingress-nginx-controller,
     type=LoadBalancer, in namespace ais-mgmt)
                          ↓
  Cloud CCM watches the Service
    (managed on EKS/GKE/AKS; OCCM installed out of band on k0s)
              ↓
          Octavia API → create LB + listener + pool + members
                      → associate floating IP 203.101.227.222
                          ↓
  Service status:
    loadBalancer:
      ingress:
        - ip: 203.101.227.222    # the pre-allocated FIP, now attached
```

The diagram is an OpenStack example, not a portable provider recipe. AWS NLB
EIPs use allocation-ID annotations, Azure recommends a public-IP resource-name
annotation, and GKE supports its documented static-address interfaces. Consult
the corrected [provider guides](clouds/README.md). Confirm address ownership,
subnets and controller events rather than assuming one `loadBalancerIP` field
reserves or attaches the same resource on every cloud.

## End-to-end trace of one edge request in cloud mode

```
   edge-group-orthanc pod (accessionflow collate orthanc)
         │ stdout / stderr
         ▼
   kubelet container log files on the edge worker
         │ read by the Vector DaemonSet
         ▼
   edge-vector pod (edge cluster)
         │
         │ HTTPS push to loki.dev-nectar-test.203-101-227-222.nip.io:443
         ▼
   edge worker DNS resolver (kubelet's /etc/resolv.conf chain)
         │
         │ → public DNS resolves nip.io → 203.101.227.222
         ▼
   TCP connect → 203.101.227.222:443
         │
         ▼
   Cloud L4 load balancer (Octavia / NLB / Azure LB / GCP LB)
         │
         │ → routes :443 to nginx-ingress controller Service backends
         ▼
   nginx-ingress controller pod (mgmt cluster)
         │
         │ → TERMINATES TLS with the `loki-tls` server certificate
         │ → verifies the edge's CLIENT certificate (mTLS):
         │     auth-tls-secret        ais-mgmt/mgmt-loki-client-ca
         │     auth-tls-verify-client on
         │     auth-tls-verify-depth  2
         │     auth-tls-match-cn      CN=(<every name in `edges`>)
         ▼
   Service mgmt-loki.ais-mgmt.svc.cluster.local:3100
         │
         ▼
   Loki ingester
```

Identical to the on-prem path except for one hop (LB instead of direct
node binding) and one resolution mechanism (DNS instead of /etc/hosts).

TLS is terminated **at the ingress controller**, using the `loki-tls` server
certificate (`observability.loki.ingress.tlsSecretName`,
charts/mgmt/values.yaml (`observability.loki.ingress`)), and the push is authenticated there by
client-certificate mTLS. Loki itself runs `auth_enabled: false` and trusts
anything that reaches it. The ingress authenticates external clients, while
direct access to the ClusterIP bypasses that check; cluster networking must
also be controlled. Client CN admission does not constrain submitted cluster
labels or queries within the shared tenant. This is
which is why the client-cert annotations above are not optional hardening. The
edge side presents the cert cert-sync delivers as `loki-push-client-tls`
(charts/edge/values.yaml (`observability.loki.clientCertSecret`)).

**The S3 upload path can carry the same mTLS, and on cloud for the same
reason.** The load balancer above is **layer 4** — it forwards TCP and does not
terminate TLS — so nginx still sees the edge's own ClientHello and can still
request a client certificate. Nothing about `auth-tls-*` behaves differently
here from on-prem. Turning it on is `seaweedfs.ingress.clientCerts` plus the
matching `certSync` entry (see `docs/components/seaweedfs.md` for the four-step
rollout, which must not be short-cut). One cloud-specific nuance: the SeaweedFS
**server** certificate may come from a public CA here. The current chart still
requires `upload.s3.caBundleSecret` for every HTTPS S3 endpoint, including a
public one (`charts/edge/templates/_helpers.tpl`, `edge.validate`, `upload.s3.caBundleSecret`). Supply the required
trust roots through that Secret. The edge's **client** certificate still
comes from the fleet CA via cert-sync. Server trust (`RCLONE_CA_CERT`) and
client identity (`RCLONE_CLIENT_CERT` / `RCLONE_CLIENT_KEY`) are separate
settings. A public server certificate does not remove the client-certificate
requirement when `seaweedfs.ingress.clientCerts.require` is enabled.

Note the scope of ssl-passthrough. `ingressNginx.sslPassthrough: true` enables
the controller *feature*, but the passthrough annotation is set only on each
edge's k0s API and konnectivity Ingresses
(charts/mgmt/templates/edge-clusters.yaml (`ssl-passthrough`)), whose TLS is passed to the API or tunnel endpoint and must not be
terminated as an HTTP ingress. The tunnel client-auth mode is not verified
here (2026-11-10). The Loki, Grafana and SeaweedFS hostnames all
terminate TLS at the ingress. The comment at `charts/mgmt/templates/seaweedfs.yaml` (`This Ingress TERMINATES TLS`) spells
out that this coexistence is deliberate, not an oversight.

## Test matrix (what to run after deployment)

| What | How |
|---|---|
| LB came up with the right IP | `kubectl -n ais-mgmt get svc mgmt-ingress-nginx-controller -o yaml` ; inspect every returned IP or hostname and resolve it against the expected addresses. On manual NodePort, inspect the externally managed balancer because Service status will not supply its address. The names are `mgmt-*` in `ais-mgmt` because ingress-nginx is a subchart of the `mgmt` release; there is no `ingress-nginx` namespace. |
| TLS termination | Use `curl --cacert <server-ca.crt>` plus the admitted Loki client certificate against `/ready`. Verify the server name and response; a request without client credentials is not expected to return a successful readiness result |
| Loki push mTLS | `curl --cacert <server-ca.crt> --cert tls.crt --key tls.key --resolve loki.dev-nectar-test.<lb-ip-dashes>.nip.io:443:<lb-ip> https://loki.dev-nectar-test.<lb-ip-dashes>.nip.io/ready` ; expect Loki's `ready` response. The cert/key are the `tls.crt` / `tls.key` of the edge's `loki-push-client-tls` Secret; **without them the request must be rejected; nginx may return an HTTP certificate error rather than fail the TLS handshake**, because the Ingress sets `auth-tls-verify-client: on`. That rejection is the test passing. |
| S3 upload mTLS (only if `seaweedfs.ingress.clientCerts.require` is on) | `curl --cacert <server-ca.crt> --cert tls.crt --key tls.key --resolve seaweedfs.dev-nectar-test.<lb-ip-dashes>.nip.io:443:<lb-ip> https://seaweedfs.dev-nectar-test.<lb-ip-dashes>.nip.io/` ; expect an S3 error document (no credentials), **not** a TLS failure. Re-run without `--cert/--key`: the request must be rejected (an HTTP certificate error is possible), and that rejection is the negative test. The cert/key are those of the edge's `s3-client-tls` Secret. First check certificate delivery before flipping `require`; test rejection on a controlled endpoint enforcing mTLS, then repeat after rollout. Historical measurement, date not recorded; not replayed on 2026-11-10: a missing client certificate gives HTTP 400 with an HTML body that rclone reports as an S3 XML parse failure, so if you discover it from the uploader's logs instead it looks like an unreachable endpoint. |
| Edge resolves via real DNS | `kubectl --kubeconfig kubeconfig-edge-dev exec -n xnat-ingest deploy/edge-s3-uploader -- nslookup seaweedfs.dev-nectar-test.<lb-ip-dashes>.nip.io`. The name should resolve through the pod resolver. If the uploader image has no nslookup, use an approved diagnostic container; tool availability is not verified here (2026-11-10). (`edge` is the Helm release name set by `install.sh` (`EDGE_KC`, `step 7/7`); a site that sets `fullnameOverride` changes the prefix.) |
| Full pipeline | Send a synthetic DICOM to Orthanc. Follow group-orthanc, assign and deidentify. An `upload_completed` event from the S3 uploader proves that hop only. Check the management uploader's `Successfully uploaded all files in` message and the files on XNAT to establish final delivery. |
| Uploader memory | Sample `kubectl top pod -n xnat-upload` during a representative two-hour workload. Record the peak, resource sizes, worker concurrency and restart count. The 0.20.0 image defaults to `tgz_file` (`stores/xnat/cli/store_cli.py`, `--method`; `stores/xnat/arg_types.py`, `UploadMethod`). Its xnat 0.8.1 client builds each archive in a `SpooledTemporaryFile` with a 256 MiB memory threshold, then spills larger archives to disk. Up to 10 workers can hold archives at once (`charts/mgmt/values.yaml`, `xnatUpload.resources`). These thresholds do not bound total process memory. The old fork's flat-memory claim is not a verified limit for this image. |

## When to use on-prem vs cloud

| Use **on-prem** if... | Use **cloud** if... |
|---|---|
| The mgmt VM is a bare-metal or single-VM node you fully control | The mgmt cluster is managed K8s (EKS / GKE / AKS / Magnum) |
| Operating in an air-gapped environment without DNS | You have a real DNS zone you can publish records into |
| Edges are inside the same LAN as the mgmt VM and can reach it by IP | Edges are remote and reach mgmt over the public internet |
| You want zero cloud provider dependencies | You want LB / auto-renew / scaling provided by the cloud |
| Simplicity over scale | Multiple ingress replicas for horizontal scale |

Both topologies are first-class in the codebase. There's no implicit
preference — the `topology` key in `sites/<site>/values.yaml` is the single
switch. (`INSTALL_TOPOLOGY` still exists, but only as an internal export
install.sh derives from that key at install.sh (`INSTALL_TOPOLOGY`) and hands to
scripts/00-common.sh at install.sh (`export MGMT_NODE_IP`); setting it in your shell is overwritten and has
no effect.) The one caveat is the LB: on-prem is exercised continuously, while
provider-specific address provisioning and fresh cloud acceptance are not
verified by a Helm render. Cloud support exists; the remaining script and
provider limits above must be checked for the chosen environment.
