# Cloud topology — implementation plan

Working document for the `cloud-topology` branch. Delete or fold into
`docs/clouds/` before the final merge; until then it is the record of what is
done, what is not, and why each decision was made.

Branch: `cloud-topology`, based on `main-config-consolidation` (which carries the
k0s version-skew fix — essential for any real edge join test).

---

## The decision this is built on

**A single L4 load balancer in front of the existing ssl-passthrough + SNI
ingress.** Not Gateway API, not per-edge load balancers, not a cloud L7 ingress.

The k0s API and konnectivity are **mTLS end to end**. Mutual TLS lives inside one
TLS session: the worker proves itself with an X.509 client certificate during the
handshake, and nothing survives being decrypted and re-encrypted. An L7 balancer
exists in order to read HTTP, which it cannot do without terminating — so ALB,
Application Gateway and GCP HTTPS LB all break the worker's join, and break it
asymmetrically: the ingress and API report healthy and only the edge fails, as an
x509 error in a journal on a machine in a hospital.

`charts/mgmt/templates/edge-clusters.yaml:67` already refuses to render a
terminating configuration. This work makes the *cloud* shape follow the same
rule rather than depending on an operator hand-copying a comment.

L4 balancers that work: AWS NLB, Azure Standard LB, GCP External TCP LB,
OpenStack Octavia with a TCP listener.

## What the recon established

`topology: cloud` is already a real switch with 7 branch points, not a stub. It
currently means *"resolve by real DNS instead of hosts files"*:

| Branch point | Cloud behaviour |
|---|---|
| `install.sh:422` | skips the management `/etc/hosts` write |
| `scripts/05-setup-edge-cluster.sh:92` | skips the management hosts edit |
| `scripts/06c-post-join.sh:62` | leaves child-cluster CoreDNS at chart defaults |
| `scripts/files/edge-join.sh:100` | skips the edge `/etc/hosts` write |
| `charts/edge/templates/_helpers.tpl:124,170` | no `hostAliases` |
| `charts/mgmt/templates/observability.yaml:170,197` | no IP SANs on certificates |
| `charts/mgmt/templates/seaweedfs.yaml:541` | onprem-only block skipped |

The ACME / DNS-01 `ClusterIssuer` is **fully implemented** in
`cert-issuers.yaml:265-291` with guards, and CI covers it (`mgmt-letsencrypt`).

## Known-false things to delete, not preserve

* `CLOUD_PROVIDER` — appears in cloud docs, referenced **nowhere** in code.
* `scripts/01b-install-cloud-controller.sh` — documented, never existed.
* `scripts/00a-provision-cloud.sh` — documented, never existed.
* `docs/clouds/openstack-nectar.md:1-3` claims this path is "end-to-end tested".
  Treat as unverified until we have done it ourselves.

---

## Tasks

Status: `[ ]` todo · `[~]` in progress · `[x]` done · `[-]` dropped, with reason.

### 1 — Ingress shape follows topology  ·  DONE, full CI green

- [x] **1.1** `charts/mgmt/values.yaml`: keep the on-prem defaults
      (`hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`,
      `service.type: ClusterIP`) as the shipped values.
- [x] **1.2** Add a documented cloud block to a new
      `sites/example-cloud/values.yaml` overriding the subchart:
      `hostNetwork: false`, `dnsPolicy: ClusterFirst`,
      `service: {type: LoadBalancer}`.
      Helm cannot template subchart values from a parent, so this MUST be
      written in the site file — a parent key that looks like it forwards would
      be read, trusted and silently ignored.
- [x] **1.3** Render guard: `topology: cloud` **and**
      `ingress-nginx.controller.hostNetwork: true` → fail. On-prem's default
      binds the host's `:443` and never asks for a load balancer; left in place
      on cloud the controller reports `1/1 Running` and nothing answers.
- [x] **1.4** Render guard: `topology: cloud` **and**
      `ingress-nginx.controller.service.type: ClusterIP` → fail, same reason.
- [x] **1.5** Negative CI cases for 1.3 and 1.4; update the guard census.

### 2 — The dead `loadBalancerIP` key  ·  DONE (both keys removed, 5 docs corrected)

- [x] **2.1** `charts/mgmt/values.yaml:555` declares
      `ingressNginx.loadBalancerIP: ""` and **no template consumes it**. It is
      exactly the key an operator reaches for to pin a pre-allocated floating
      IP, and it does nothing. Either wire it or delete it — do not leave a key
      that reads as configured and is not.
      Decision: **delete it**, and document the subchart path
      (`ingress-nginx.controller.service.loadBalancerIP`) in its place, because
      the parent cannot forward into the subchart.
- [x] **2.2** Same audit for `ingressNginx.proxyBodySize` — flagged as possibly
      dead by the earlier values-consumers work. Confirm and resolve.

### 3 — Load balancer address

The chicken-and-egg: `domain.internal` must contain the address before the
install creates the load balancer, and a `nip.io` name *embeds* it.

- [ ] **3.1** Document the pre-allocated floating IP as the supported answer on
      OpenStack, with the exact `openstack floating ip create` command.
- [ ] **3.2** `domain.mgmtNodeIP` is currently a static IP used for cert SANs and
      edge `hostAliases`. On cloud the LB address may be a **hostname** (AWS
      NLB), not an IP. Decide whether `mgmtNodeIP` stays IP-only on cloud, or
      gains a hostname sibling. Do not silently accept a hostname into a field
      that renders into an IP SAN.
- [ ] **3.3** `verify-live.sh`: check that the LB Service actually got an
      external address, and fail with the pending-address case named — a
      `LoadBalancer` Service with no cloud controller sits `<pending>` forever
      and everything downstream times out with no explanation.

### 3b — Octavia teardown ordering (OpenStack)

Deleting a load balancer is **not** a single call: Octavia refuses while a
listener or pool is still attached. The order is pool → listener → load
balancer. A `kubectl delete svc` normally has the cloud controller do this for
you, but two cases leave orphans that keep consuming quota and hold the floating
IP:

* the cluster is torn down (`k0s reset`) before the Service is deleted, so no
  controller ever runs the cleanup;
* the controller is removed or loses credentials mid-teardown.

- [ ] **3b.1** `scripts/uninstall.sh`: on `topology: cloud`, delete the ingress
      Service and WAIT for the cloud controller to release the load balancer
      before touching k0s. Deleting the cluster first strands it.
- [ ] **3b.2** Print the manual recovery in the right order when the Service is
      already gone or the wait times out:
      `openstack loadbalancer pool delete` → `listener delete` → `delete`,
      then release the floating IP if it was allocated for this install.
- [ ] **3b.3** Say in the docs that a stranded LB holds a floating IP, because
      the next install will ask for one and the quota will already be spent.

### 4 — Per-edge exposure on cloud

- [ ] **4.1** Today `edges[].exposure` is `nodePort | sni`. Behind one cloud LB,
      `sni` maps cleanly; `nodePort` means exposing a node port of the
      *management* cluster, which needs security-group rules per edge.
      Proposal: refuse `nodePort` when `topology: cloud` unless a site
      explicitly opts in. **Confirm with the user before implementing.**
- [ ] **4.2** If refused, render guard + negative case.

### 5 — Certificates

- [x] **5.1** `sites/example-cloud/values.yaml` ships `certManager.issuer:
      ais-edge-ca` with a comment that `nip.io` cannot satisfy DNS-01.
- [ ] **5.2** Document the four DNS-01 solver shapes (route53, azuredns,
      clouddns, designate) as commented blocks, verified against
      `certManager.acme.dns01Solver`'s actual schema.
- [ ] **5.3** State plainly in the docs that ACME issuance is **render-tested
      only** until a real zone is pointed at it. Do not imply nip.io covers it.

### 6 — Docs

- [ ] **6.1** Rewrite `docs/clouds/README.md` against what the chart does.
- [ ] **6.2** Per-provider: aws, azure, gcp, openstack-nectar,
      openstack-private-subnet. Delete the `CLOUD_PROVIDER` fiction and the two
      never-existed scripts. Each gets the L4-vs-L7 constraint stated up front.
- [ ] **6.3** `docs/cloud-deployment.md` — same treatment.
- [ ] **6.4** README + TOUR: a cloud section that does not contradict them.
- [ ] **6.5** Remove the "end-to-end tested" claim from openstack-nectar.md
      until it is true again, then restore it with the date and what was tested.

### 7 — CI

- [x] **7.1** Positive render cases: `mgmt-cloud`, `mgmt-cloud-letsencrypt`.
- [ ] **7.2** Negative cases for every guard added above.
- [ ] **7.3** Check the cloud site example renders both charts, as the
      README block check does.

## The test deployment — names and machines

Fixed here so nothing drifts as this is built.

| | |
|---|---|
| Site directory | `sites/cloud-test/` |
| Management `clusterLabel` | `cloud-test` |
| Management node | **203.101.224.240** — currently runs the tier-1 deployment |
| Edge name (`edges[].name`) | `cloud-edge` |
| Edge node | **203.101.230.171** |
| DNS | `nip.io` wildcard off the load balancer's floating IP |
| Issuer | `ais-edge-ca` — nip.io cannot satisfy DNS-01 |

The edge name becomes a namespace, two hostnames and a bucket name, so it is
short and cannot collide with the management `clusterLabel` (the chart refuses
that collision).

## Let's Encrypt later — what it will and will not touch

Confirmed against the chart, because the assumption is worth writing down:
**cert-manager never touches the k0s join path.** It issues the *terminated*
endpoints only — SeaweedFS, Grafana and Loki ingress TLS, the Loki client CA,
and the per-edge Loki client certificates. The k0s API and konnectivity
certificates come from k0smotron's own cluster CA, which is exactly the mTLS
that passes through nginx untouched. Switching issuers therefore cannot break a
join, and moving from `ais-edge-ca` to Let's Encrypt later is `certManager.issuer`
plus `acme.email` and a `dns01Solver`.

- [ ] **5.4** ONE KNOWN WRINKLE, not zero work: `charts/edge/templates/_helpers.tpl:63`
      refuses an `https` S3 endpoint with an empty `upload.s3.caBundleSecret`,
      because an empty `AWS_CA_BUNDLE` *disables* verification rather than
      falling back to the system trust store. With a publicly-trusted
      certificate the right answer is system trust, so that guard needs an
      explicit "use the system store" value rather than treating empty as a
      mistake. Same question for `observability.loki.caBundleSecret`.

### 8 — Live test on OpenStack (Nectar)

Blocked on the user's key. **`203.101.224.240` currently runs the verified
tier-1 deployment — tearing it down loses the only end-to-end evidence we have.
Copy `/data/facility-backup` first if anything there matters.**

- [ ] **8.1** Tier-2 cloud needs **two** machines: `.240` becomes the management
      node, and at least one more instance is the edge. Plus a floating IP for
      the LB.
- [ ] **8.2** Tear down tier-1 on `.240`.
- [ ] **8.3** Pre-allocate the floating IP; build `domain.internal` from it.
- [ ] **8.4** Install the management cluster with `topology: cloud`.
- [ ] **8.5** Confirm Octavia gave the Service an external address.
- [ ] **8.6** Join the edge — this exercises the version-skew fix on a real
      cloud join, which has never been done.
- [ ] **8.7** Synthetic DICOM through the full path: Orthanc → group → assign →
      s3-uploader → SeaweedFS → mgmt `xnat-upload` → XNAT. Confirm the session
      lands in XNAT, as on tier-1.
- [ ] **8.8** `verify-live.sh` green.
- [ ] **8.9** Restore the "end-to-end tested" claim with the date.

---

## Open questions for the user

1. **`nodePort` on cloud** (4.1) — refuse it, or keep it for a site that needs it?
2. **A real DNS zone** — if one exists, DNS-01 becomes testable and the cloud
   deployment gets real certificates instead of the internal CA.
3. **The tier-1 deployment on `.240`** — anything in `/data/facility-backup`
   worth copying before teardown?
