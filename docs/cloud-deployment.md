# Cloud deployment (managed-K8s topology)

This document describes the **cloud topology** — the deployment shape used
when the management cluster runs on managed Kubernetes (EKS / GKE / AKS /
OpenStack Magnum / Nectar k0s with Octavia). It is the equivalent of the
on-prem topology described in the main `README.md`, with two specific
substitutions:

| | On-prem | Cloud |
|---|---|---|
| Inbound TLS | `nginx-ingress` on `hostNetwork: true` :443 | `nginx-ingress` Service `type: LoadBalancer`, cloud LB takes over :443 |
| Hostname resolution | `hostAliases:` in every pod + `/etc/hosts` on every edge VM | Real public DNS (a domain you own, or `nip.io` for dev) |

Nothing else changes — same application stack (xnat-ingest, Orthanc, Loki,
Vector, Prometheus, Grafana, k0smotron, SeaweedFS), same memory-leak fix,
same dashboards, same alerts.

## One key picks the topology

`sites/<site>/values.yaml` is a **Helm values file**, not a shell script.
install.sh reads the handful of fields it needs with a `yaml.safe_load` helper
(`cfg`, install.sh:95-113) and hands the *same* file to both Helm releases with
`-f` — the management chart at install.sh:364-367, each edge chart at
install.sh:512-516. Nothing sources it, so there is nothing to `export`; an
`export` line here is not merely inert, it breaks the YAML parse for every key
after it. That is the whole point of the file: one fact, written once, visible
to the installer and to the charts.

```yaml
# sites/<site>/values.yaml
topology: cloud            # onprem | cloud   (default onprem — charts/mgmt/values.yaml:32)
installMode: existing      # fresh | existing — managed K8s is always `existing`;
                           # it makes step 1/7 verify the cluster it is pointed at
                           # instead of installing k0s (scripts/01-install-k0s.sh:8)
domain:
  internal: dev-nectar-test.203-101-227-222.nip.io   # or your real zone
  mgmtNodeIP: "203.101.227.222"   # the address every edge dials — in cloud mode
                                  # that is the pre-allocated LB address, not a
                                  # node's own IP
certManager:
  issuer: ais-edge-ca      # ais-edge-ca | letsencrypt-prod | letsencrypt-staging
                           # nip.io can satisfy neither ACME challenge, so dev
                           # stays on the internal CA (charts/mgmt/values.yaml:365-370)
```

`certManager.issuer` is literally the *name* of the ClusterIssuer the chart
renders, and every Certificate in the chart sets `issuerRef.name` to it — so it
is a value picked from that list, not a free-form label. A dangling name does
not error: the Certificates stay `Pending` forever and the Ingress quietly
serves nginx's default self-signed cert. (Clusters adopted from the old shell
installer run a ClusterIssuer named `ais-edge-ca-issuer` and set this key to
match — that is why both names exist in the wild. `ais-edge-ca` is the chart
default and the name of the CA *Certificate* in every mode.)

## Cloud credentials — your shell, not the installer

**What changed.** An earlier design had install.sh source a
`CLOUD_CREDENTIALS_FILE`, run a `provider_guard_<name>` function per provider,
and install a cloud-controller-manager from
`scripts/01b-install-cloud-controller.sh`. None of that was ever written, and
the Helm charts replaced the imperative installer before it could be:
`grep -n 'provider_guard\|CLOUD_' install.sh` returns nothing, there is no
`scripts/01b-*`, and install.sh's only prerequisite check is for `kubectl`,
`helm` and `python3` (install.sh:87-89) plus the SOPS-encrypted site Secrets.
**The installer does no credential handling at all.**

**What to do instead.** Authenticate to your cloud the ordinary way, in your own
shell, before running `./install.sh -y <site>` — and make sure a
cloud-controller-manager is already running in the cluster, because nothing in
this repo installs one (see "How the LB gets its IP"). The table below still
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
`cloudConfigSecretRef` — charts/mgmt/values.yaml:634-641), but it is **parked**,
and says so itself: "Kept as a values key so templates stay ready, not wired up —
pre-creating an Octavia LB is Terraform work, not Helm work." Setting it today
does nothing. `docs/TOUR.md` records the same status under known gaps: the
cloud/OpenStack path is not ported to the charts and the `loadBalancerIP`
handling is unfinished. Treat this page as the design plus the parts that do
work, not as a path that has been run end to end.

## What `topology: cloud` actually changes

install.sh is a seven-step installer: `1/7` k0s on the management node
(install.sh:222), `2/7` cert-manager CRDs + the pinned k0smotron operator (:239),
`3/7` the site Secrets decrypted from SOPS straight into the cluster (:352),
`4/7` the management chart (:363), `5/7` each edge's child kubeconfig + join
token (:447), `6/7` the join itself (:469/:480), `7/7` the edge chart (:488).
Its own header notes that steps 4 and 7 "replace what used to be scripts
02b/02c/02d/03/04/07/07b/07c" — so the per-concern step numbers this page used
to cite (01b, 02c, 02d, 07c) no longer name anything.

Against that installer, `topology: cloud` changes exactly three things:

* **skips the `/etc/hosts` writes** — on the management node (install.sh:388)
  and on every edge VM (scripts/05-setup-edge-cluster.sh:92,
  scripts/06c-post-join.sh:62, scripts/files/edge-join.sh:48). The child
  cluster's CoreDNS Corefile patch — the `hosts { … }` block that made
  konnectivity-agent able to resolve the management hostnames *from inside a
  pod* — is skipped by the same branch (scripts/06c-post-join.sh:62-97), leaving
  CoreDNS at chart defaults so resolution goes CoreDNS `forward` → the kubelet's
  `/etc/resolv.conf` → public DNS.
* **strips the `hostAliases:` block from every edge pod**
  (charts/edge/templates/_helpers.tpl:124,170). The `{{#ONPREM_ONLY}}` /
  `{{#CLOUD_ONLY}}` markers in scripts/00-common.sh:86-103 do the equivalent for
  the files the join writes on the edge VM.
* **drops the IP SAN from every server certificate** — Loki and Grafana
  (charts/mgmt/templates/observability.yaml:170,197) and SeaweedFS
  (charts/mgmt/templates/seaweedfs.yaml:541). In cloud mode the address a client
  connects to is the LB's, not the serving node's, so an IP SAN would be both
  wrong and unnecessary: cloud certs are pure DNS-named.

Everything else runs unchanged — the same management chart, the same edge chart,
the same observability stack, the same join sequence. Note what is **not** in
that list: nothing in `topology` touches the ingress Service type. The chart
pins `hostNetwork: true` + `service.type: ClusterIP` in both topologies
(charts/mgmt/values.yaml:526,535-536); getting a real cloud LoadBalancer is a
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

For our dev work on Nectar, we use nip.io and the internal CA
(`certManager.issuer: ais-edge-ca`) because Let's Encrypt rejects nip.io
domains (anti-abuse) and a wildcard resolver cannot be validated at all.
Promotion to production is a few keys in `sites/<site>/values.yaml` — see
"Production swap" below.

## Production swap (when you own a real domain)

`sites/<site>/values.yaml` — the same file, three more keys:

```yaml
# 1. domain.internal — the one string everything else derives from
domain:
  internal: aisedge.uq.edu.au

# 2. certManager.issuer — self-signed CA -> Let's Encrypt prod. Any
#    letsencrypt-* value switches cert-issuers.yaml to the ACME branch and
#    re-points every leaf Certificate's issuerRef at it.
certManager:
  issuer: letsencrypt-prod
  acme:
    # Required whenever issuer is letsencrypt-prod — the chart refuses to
    # render without it (charts/mgmt/templates/_helpers.tpl:248-250).
    email: ops@uq.edu.au
    server: https://acme-v02.api.letsencrypt.org/directory
    # 3. The DNS-01 solver, passed through verbatim into solvers[0].dns01.
    #    DNS-01 only: the ingress runs ssl-passthrough for the k0s API and
    #    konnectivity, so an HTTP-01 challenge has no controller to terminate
    #    at. An empty solver is also a render-time failure
    #    (charts/mgmt/templates/cert-issuers.yaml:265-266).
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
(install.sh:80). All other code stays the same.

The certificate templates emit DNS-only SANs in cloud mode, which is
exactly what Let's Encrypt requires. The edge CA-bundle distribution can
be removed (every edge already trusts Let's Encrypt roots through OS
truststores) — that's a separate cleanup, not a blocker for the swap.

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
managed control plane already runs one; on self-managed k0s (Nectar included)
you install the OCCM and its `cloud.conf` Secret out of band, before the install,
as noted above.

**The knob is the subchart block, and `loadBalancerIP` alone is not enough.**
The chart's on-prem defaults are `hostNetwork: true` (charts/mgmt/values.yaml:526)
and `service.type: ClusterIP` (:536), and `loadBalancerIP` is inert on a
ClusterIP Service. Override the whole block in the site file, exactly as the
CAUTION at charts/mgmt/values.yaml:511-522 prescribes:

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
and konnectivity are mTLS end to end and must not be terminated at nginx.

> CAUTION — decoy key. The parent chart's top-level
> `ingressNginx.loadBalancerIP` (charts/mgmt/values.yaml:555) is read by **no**
> template; only `ingressNginx.enabled` and `ingressNginx.sslPassthrough` are
> consumed. Setting the top-level one fails silently, which looks exactly like
> a cloud that would not allocate you an address.

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

On AWS the same values produce an NLB and the FIP becomes an Elastic IP. On GCP
it's a Network LB with a pre-allocated regional IP. On Azure, a Standard LB with
a pre-allocated public IP. In every case the address you put in
`loadBalancerIP` must already exist and be free — the CCM associates a
pre-allocated address, it does not reserve one for you.

## End-to-end trace of one edge request in cloud mode

```
   xnat-ingest-group pod (edge cluster)
         │
         │ HTTP push to  loki.dev-nectar-test.203-101-227-222.nip.io:443
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
charts/mgmt/values.yaml:595), and the push is authenticated there by
client-certificate mTLS. Loki itself runs `auth_enabled: false` and trusts
anything that reaches it, so that Ingress is the *only* authentication point —
which is why the client-cert annotations above are not optional hardening. The
edge side presents the cert cert-sync delivers as `loki-push-client-tls`
(charts/edge/values.yaml:646).

Note the scope of ssl-passthrough. `ingressNginx.sslPassthrough: true` enables
the controller *feature*, but the passthrough annotation is set only on each
edge's k0s API and konnectivity Ingresses
(charts/mgmt/templates/edge-clusters.yaml:257), whose traffic is mTLS end to end
and must not be terminated. The Loki, Grafana and SeaweedFS hostnames all
terminate TLS at the ingress — charts/mgmt/templates/seaweedfs.yaml:466 spells
out that this coexistence is deliberate, not an oversight.

## Test matrix (what to run after deployment)

| What | How |
|---|---|
| LB came up with the right IP | `kubectl -n ais-mgmt get svc mgmt-ingress-nginx-controller -o yaml` — `status.loadBalancer.ingress[0].ip` should equal the `loadBalancerIP` you set. The names are `mgmt-*` in `ais-mgmt` because ingress-nginx is a subchart of the `mgmt` release; there is no `ingress-nginx` namespace. |
| TLS termination | `curl -kv https://loki.dev-nectar-test.<lb-ip-dashes>.nip.io/` — expect TLS handshake + 404 default backend |
| Loki push mTLS | `curl --cert tls.crt --key tls.key --resolve loki.dev-nectar-test.<lb-ip-dashes>.nip.io:443:<lb-ip> https://loki.dev-nectar-test.<lb-ip-dashes>.nip.io/ready` — expect Loki's `ready` response. The cert/key are the `tls.crt` / `tls.key` of the edge's `loki-push-client-tls` Secret; **without them the request is rejected at the handshake**, because the Ingress sets `auth-tls-verify-client: on`. That rejection is the test passing. |
| Edge resolves via real DNS | `kubectl --kubeconfig kubeconfig-edge-dev exec -n xnat-ingest deploy/edge-s3-uploader -- nslookup seaweedfs.dev-nectar-test.<lb-ip-dashes>.nip.io` — should resolve via the worker's standard resolver. (`edge-` is the Helm release name install.sh:512 uses; a site that sets `fullnameOverride` changes the prefix.) |
| Full pipeline | drop a DICOM into Orthanc (via `dcmsend`, `storescu`, or the Orthanc REST upload), wait for group-orthanc + assign to stage it, watch `upload_completed` event land in Loki + dashboards |
| Memory leak fix | sample `kubectl top pod -n xnat-upload` over 2 hours — should stay flat ±20 MiB |

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
install.sh derives from that key at install.sh:133 and hands to
scripts/00-common.sh at :155; setting it in your shell is overwritten and has
no effect.) The one caveat is the LB: on-prem is exercised continuously, while
the cloud path's `loadBalancerIP` handling is still listed as unfinished in
`docs/TOUR.md`.
