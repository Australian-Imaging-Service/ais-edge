# OpenStack / Nectar Research Cloud install

This is the path that has been **end-to-end tested**. The mgmt cluster is
a single Nectar VM running k0s; the cloud LB is Octavia (amphora driver).
DNS is a `nip.io` wildcard for dev, switchable to your own zone for prod.


## Before you install: the cloud controller (yours to do, once)

`install.sh` will stop with an error if this is missing — deliberately, because
without it a `LoadBalancer` Service sits at `<pending>` forever and nothing says
so. See docs/clouds/README.md for why this is the operator's job.

There is no script for this in the repo on purpose: it is OpenStack-specific,
it needs credentials the installer should not hold, and every site's project,
network and credential policy differ.

**1. An application credential scoped to this project.** Horizon → Identity →
Application Credentials. Give it only what the controller needs; it will create
and delete load balancers in your project.

**2. A `cloud.conf` Secret on the management cluster.**

```bash
cat > /tmp/cloud.conf <<EOF
[Global]
auth-url=https://identity.rc.nectar.org.au/v3/
application-credential-id=<id>
application-credential-secret=<secret>
region=Melbourne

[LoadBalancer]
# Octavia gives a TCP listener by default, which is what this deployment needs:
# the k0s API and konnectivity are mTLS end to end and must NOT be terminated.
# Do not set a TERMINATED_HTTPS listener here.
use-octavia=true
EOF

kubectl -n kube-system create secret generic openstack-cloud-config \
    --from-file=cloud.conf=/tmp/cloud.conf
shred -u /tmp/cloud.conf
```

**3. The controller itself**, pinned like everything else here:

```bash
helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack
helm install openstack-ccm cpo/openstack-cloud-controller-manager \
    --namespace kube-system --version <pin-a-version> \
    --set secret.create=false --set secret.name=openstack-cloud-config
```

**4. Confirm it adopted the nodes** — this is what the installer's pre-flight
checks, and it is worth checking yourself before spending an install:

```bash
kubectl -n kube-system get pods | grep cloud-controller-manager
# and no node should still carry the uninitialized taint:
kubectl get nodes -o json | grep -c 'node.cloudprovider.kubernetes.io/uninitialized'
```

A node still carrying that taint means the controller is running but has not
adopted it — almost always wrong credentials for the project, or a `region` that
does not match where the nodes actually are.

### Reusing an address you already hold

Allocating a floating IP per install wastes quota, and on a `nip.io` name the
address is embedded in the hostname — so it has to exist before `domain.internal`
can name it. Reuse one:

```bash
openstack floating ip list          # look for one with no Port and no Fixed IP
```

Then pin the balancer to it in your site file, under the SUBCHART (a parent
chart cannot set a subchart's values):

```yaml
ingress-nginx:
  controller:
    service:
      loadBalancerIP: "203.0.113.50"
```


## Prerequisites

1. A Nectar project with available quota for:
   - 1 VM for the mgmt cluster (4 vCPU / 8 GB / 40 GB is plenty)
   - 1 VM per edge site (2 vCPU / 4 GB / 40 GB)
   - 1 LBaaS unit (Octavia amphora)
   - 1 floating IP (only if you want a fixed public IP — see "Topology quirks" below)
2. An **application credential** from your dashboard
   (Identity → Application Credentials → Create → Download openrc.sh).
3. Python, `openstack` CLI, `kubectl`, `helm` available on the mgmt VM. The
   install scripts handle the rest.

## Minimum config

Edit `sites/<site>/values.yaml`. This file is **YAML**, read by
`yaml.safe_load` in `install.sh` and passed straight to Helm — it is never
sourced, so shell `export` lines in it are inert. Everything the installer
needs is a chart key:

```yaml
topology: cloud          # onprem | cloud (charts/mgmt/values.yaml)
installMode: fresh       # fresh | existing — `existing` skips the k0s install

domain:
  internal: dev-nectar-test.<lb-ip-with-dashes>.nip.io
  mgmtNodeIP: "<mgmt VM IP>"

certManager:
  issuer: ais-edge-ca    # the default; nip.io cannot satisfy Let's Encrypt

# Cloud override of the on-prem ingress default. NOT optional here: the
# default binds the mgmt host's :443 with hostNetwork and never asks for an
# LB (see the CAUTION on `ingress-nginx` in charts/mgmt/values.yaml).
ingress-nginx:
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst
    service:
      type: LoadBalancer
```

`certManager.issuer: ais-edge-ca` is already the default, and
`ais-edge-ca-issuer` is **not** a valid value — the ClusterIssuer is named
FROM this key, so a wrong name leaves every Certificate Pending.

Run `./install.sh -y <site>`; the site argument is mandatory. Nothing in the
install reads OpenStack credentials, so sourcing the openrc is only needed
for the `openstack` CLI commands below.

**This repo does not install or configure a cloud controller manager.**
Install `cloud-provider-openstack` (OCCM) yourself, before `install.sh`.
Subnet, availability zone and floating-IP behaviour are settings in *that*
CCM's own `cloud.conf` Secret, not keys in `sites/<site>/values.yaml` — the
chart's `cloud:` block is parked and deliberately not wired up. Read the
"Topology quirks" below as things to configure in your CCM and your
OpenStack project, not as variables this repo consumes.

## Discovering the right values

```bash
source /path/to/openrc.sh

# Mgmt VM's AZ
openstack server show <mgmt-vm-name> -f value -c OS-EXT-AZ:availability_zone

# Subnet where the mgmt VM lives
openstack server show <mgmt-vm-name> -f value -c addresses
openstack network show <network-name> -f value -c subnets

# Available LBaaS AZs (must include the AZ you set above)
openstack loadbalancer availabilityzone list
```

## Nectar-specific topology quirks

The Nectar tenant networking has two oddities that bit us during commissioning
and the codebase now handles them:

### 1. Octavia defaults to `melbourne-qh2` for new LBs

If your OCCM's `cloud.conf` does not pin an availability zone under
`[LoadBalancer]`, Octavia spawns the amphora in Melbourne regardless of
where your VMs are. The LB then hangs in `PENDING_CREATE` forever because
the amphora can't reach the backend ports (cross-region). **Always set the
LB availability zone to match your mgmt VM's AZ**, in the `cloud.conf`
Secret you hand OCCM — this repo has no key for it.

### 2. The qld network is BOTH external and where your VMs live

On most OpenStack deployments you'd allocate a floating IP and pin it on
the Service as `loadBalancerIP`. On Nectar QLD that doesn't work — Neutron
rejects FIP association with `ExternalGatewayForFloatingIPNotFound` because
there's no router between qld and itself.

The fix is to **pin no address at all** — leave `loadBalancerIP` unset
under `ingress-nginx.controller.service` — and let Octavia auto-assign a
VIP from the qld pool. That VIP is already a public IP. After install,
discover it with:

```bash
kubectl -n ais-mgmt get svc mgmt-ingress-nginx-controller
openstack loadbalancer list -c name -c vip_address          # authoritative
```

The ingress controller is a subchart of the `mgmt` release in the
`ais-mgmt` namespace, which is why the Service is `mgmt-ingress-nginx-controller`
and not `ingress-nginx-controller`. It is `ClusterIP` by default and shows
an `EXTERNAL-IP` only if the site file overrides
`ingress-nginx.controller.service.type` to `LoadBalancer` as shown above —
otherwise there is no external address to be pending.

Then update `domain.internal` (or DNS) to point at the discovered VIP.

### 3. The project's default security group blocks NodePort

By default Nectar's `default` SG only allows `:22` and intra-SG traffic.
The LB's amphora is in a separate Octavia-managed SG, so it can't reach
the K8s NodePort (`30000-32767`) on the mgmt VM. You must open them:

```bash
source /path/to/openrc.sh
openstack security group rule create --ingress --protocol tcp \
    --dst-port 443        --remote-ip 0.0.0.0/0 default
openstack security group rule create --ingress --protocol tcp \
    --dst-port 80         --remote-ip 0.0.0.0/0 default
openstack security group rule create --ingress --protocol tcp \
    --dst-port 30000:32767 --remote-ip 0.0.0.0/0 default
```

Or via the dashboard: Network → Security Groups → default → Add Rule.

### 4. OCCM can't auto-detect the LB subnet on self-managed k0s

The upstream OCCM normally reads each node's `providerID` to figure out
which subnet to put the LB on. k0s nodes have an empty `providerID`
(we don't run kubelet with `--cloud-provider=external`). This repo does not
install or configure OCCM, so it cannot fix that for you: set `subnet-id`
explicitly under `[LoadBalancer]` in the `cloud.conf` Secret you hand your
own cloud-provider-openstack deployment, before running `install.sh`. It is
required — there is no auto-detection to fall back on.

### 5. Stuck LBs can't be force-deleted by app-credential users

If the LB ever ends up in `PENDING_CREATE` due to an AZ mismatch or
config problem, the API rejects deletes with HTTP 409 until Octavia's
internal timeout. App-credential users have no admin scope to force
deletion. Workaround: redeploy OCCM with a different `--cluster-name` (the
`cluster.name` Helm value of cloud-provider-openstack — a CLI flag on
`openstack-cloud-controller-manager`, not a `cloud.conf` key). OCCM names
LBs `kube_service_<cluster-name>_<namespace>_<service>`, so a new value
creates a fresh LB and ignores the orphaned one until a Nectar admin
cleans it up or the amphora-build timeout fires.

## What the install does

The install is **seven steps**, not thirteen. The old numbered scripts
`01b`, `02b`, `02c`, `02d`, `03`, `04`, `07`, `07b` and `07c` no longer
exist: steps 4 and 7 below are two Helm releases that replace all of them,
so the cloud-specific notes that used to hang off each script now hang off
those two. There is no OCCM step at all — see "Topology quirks" above.

| Step | What | Cloud-specific notes |
|---|---|---|
| —   | `cloud-provider-openstack` (OCCM) | **Not installed by this repo.** Provision it, and its `cloud.conf` Secret, yourself before `install.sh`. The chart's `cloud:` key is parked and unused |
| 1/7 | k0s + kubectl/helm/local-path-provisioner on the mgmt VM (`scripts/01-install-k0s.sh`) | Skipped entirely under `installMode: existing`, which only verifies `kubectl get nodes` and warns if there is no default StorageClass |
| 2/7 | cert-manager v1.20.3 (vendored tarball) + the k0smotron control-plane provider v2.0.3 | Same as onprem |
| 3/7 | Site Secrets, SOPS-decrypted straight into the cluster (`scripts/site-secrets.sh`) | Only runs if the site has a `secrets.enc.yaml` |
| 4/7 | `helm upgrade --install mgmt charts/mgmt -n ais-mgmt` — SeaweedFS, the S3→XNAT uploader, observability (Prometheus/Loki/Grafana/Alertmanager/Vector), the internal CA + issuers, cert-sync, ingress-nginx, and one k0smotron `Cluster` per edge | This is where the LB happens: override `ingress-nginx.controller` in the site file to `hostNetwork: false`, `dnsPolicy: ClusterFirst`, `service.type: LoadBalancer` so OCCM provisions an Octavia LB. Cert SANs are DNS-only in cloud mode (no IP SANs). Grafana/Loki/SeaweedFS Ingress hostnames come from `hostnames.*` over `domain.internal` |
| 5/7 | Per edge: child kubeconfig + JoinTokenRequest (`scripts/05-setup-edge-cluster.sh`) | The `Cluster` object itself belongs to the chart now (`install.sh` sets `CLUSTER_CR_MANAGED_BY_HELM=1`). k0s API + konnectivity are SNI-passthrough Ingresses on :443. Step 5 skips the mgmt-side `/etc/hosts` writes when topology is not onprem |
| 6/7 | Per edge: join the k0s worker — `join: ssh` (`scripts/06-join-edge-worker.sh`) or `join: bundle` (`scripts/06b-make-bootstrap.sh` + `scripts/06c-post-join.sh`) | Both paths behave identically under cloud: `scripts/files/edge-join.sh` skips the edge `/etc/hosts` writes, and `06c` skips the child-cluster CoreDNS patch, because real public DNS resolves the names |
| 7/7 | Per edge: `helm upgrade --install edge charts/edge` into the child cluster — Orthanc + de-identification Lua hook, the ingest pipeline, s3-uploader, Vector — then a one-shot cert-sync run | Endpoints are the public LB hostnames, so no `hostAliases` block is needed. Vector's push endpoint is the public Loki hostname |

## Verification checklist

After install, from a host that's NOT the mgmt VM (e.g. the edge VM):

```bash
# DNS resolves to the LB VIP
getent hosts seaweedfs.dev-nectar-test.<lb-ip-dashes>.nip.io
# Should be 203.101.x.y (the LB VIP)

# TLS handshake completes + 403 from SeaweedFS S3 (which requires auth)
curl -kv https://seaweedfs.dev-nectar-test.<lb-ip-dashes>.nip.io/
# Expect HTTP 403

# Loki readiness
curl -kv https://loki.dev-nectar-test.<lb-ip-dashes>.nip.io/ready
# Expect HTTP 200

# Drop test: POST a DICOM to Orthanc REST, watch the upload_completed event
# (full procedure in the parent docs/cloud-deployment.md)
```

## Dev → Prod swap

The dev test uses nip.io because Let's Encrypt rejects nip.io (anti-abuse).
For production with your own domain:

```yaml
# sites/<site>/values.yaml
domain:
  internal: aisedge.example.com          # YOUR delegated zone

certManager:
  issuer: letsencrypt-prod               # any letsencrypt-* name selects ACME
  acme:
    email: ops@example.org               # REQUIRED for letsencrypt-prod —
                                         # the chart fails the render without it
    # server: defaults to the production ACME directory; set it only for
    # letsencrypt-staging, which the chart refuses against the prod URL
    dns01Solver:                         # passed through to the ClusterIssuer
      cloudflare:                        # verbatim — the provider is just the
        apiTokenSecretRef:               # key name here
          name: cloudflare-api-token
          key: api-token
```

There is no `DNS_PROVIDER` variable: the DNS-01 provider *is* the key under
`dns01Solver`. An empty `dns01Solver` with a `letsencrypt-*` issuer fails the
render on purpose — a ClusterIssuer with no solver never solves a challenge,
so every Certificate stays Pending while the Ingress quietly serves nginx's
default self-signed cert, which reads as a browser warning rather than a
misconfiguration. HTTP-01 is not an option here: the edge hostnames are
ssl-passthrough, so DNS-01 only. A working example, using route53 against
the staging directory, is in `scripts/ci/values.sh`.

Then create the token Secret, and re-run the installer:

```bash
kubectl -n cert-manager create secret generic cloudflare-api-token \
    --from-literal=api-token=<token>
./install.sh -y <site>
```

The Secret must live in `certManager.clusterResourceNamespace`
(`cert-manager` by default), because that is the only namespace a
ClusterIssuer resolves `secretRef`s from. Note the internal CA is still
rendered alongside Let's Encrypt — switching the issuer repoints the
Certificates, it does not remove the CA path. Everything else is unchanged.

## Tested cluster topology (commissioning, 2026-05-25)

- Mgmt: 203.101.224.240 (`stream-2_AB_dev`, QRIScloud AZ)
- LB:   203.101.228.227 (Octavia amphora, QRIScloud AZ, qld subnet)
- Edge: 203.101.230.171 (`k0s-edge-worker-dev`, QRIScloud AZ)
- DNS:  `*.dev-nectar-test.203-101-228-227.nip.io`
- Pipeline: DICOM REST POST → Orthanc → group-orthanc REST-pull → assign → s3-uploader → SeaweedFS S3 → `upload_completed` event with `bytes=13427, dicoms=1, files=3`
