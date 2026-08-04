# Production hardening — findings, recommendations, and a critique of how we got here

Status: **the charts render and validate, but are NOT safe to install on the
existing management cluster yet.** This document is the decision list that has
to be settled first. Each item states the finding, what I recommend, and what
that recommendation costs.

Everything marked *(measured)* was verified against the live SeaweedFS 3.99 /
cert-manager v1.20.3 / k0smotron v2.0.3 on stream-2-ab-dev, not reasoned from
documentation.

---

## 0. Bucket per edge site — yes, and it is enforced *(measured)*

The question was whether per-bucket S3 identities give real isolation in
SeaweedFS. They do. Using the live `edge-dev` key, which is scoped
`Read:ingest-bucket / List:ingest-bucket / Write:ingest-bucket/* /
Tagging:ingest-bucket`:

```
aws s3 ls s3://ingest-bucket/   ->  PRE staged/          ALLOWED
aws s3 ls s3://logs-bucket/     ->  AccessDenied         DENIED
```

So the enforcement boundary is the **bucket**, and only the bucket. Because
every site currently shares `ingest-bucket`, and `Write:ingest-bucket/*`
covers every key in it, **any edge key can today read, list and delete any
other site's staged imaging.** Prefix-scoped actions are not a thing here.

### Recommendation: one bucket per edge site — `ingest-<edge-name>`

This is the only change that makes the isolation claim true.

**What it changes on the management side.** `xnat-ingest upload` takes one
`s3://bucket/prefix` argument, so one uploader cannot serve N buckets. The
uploader becomes **one Deployment per edge**, ranged from the `edges` list,
and likewise the reclaimer CronJob.

That reads like a cost, but it is mostly a benefit and I would argue for it
even without the security case:

* Today one uploader is a **fleet-wide single point of failure**. One site's
  malformed session, one stuck multipart, one bad credential, and every site
  stops being delivered.
* Per-site uploaders give per-site failure isolation, per-site alerting
  granularity (the `cluster` label already exists), and let one site be
  paused for maintenance without touching the others.
* Blast radius of the reclaimer drops from "the whole fleet's staging" to
  "one site's staging".

**What it costs.** N Deployments plus N CronJobs on the management node
instead of one of each. At 5–15 sites this is noise (each uploader is
~256Mi). Past ~50 sites the whole single-management-node design needs
revisiting anyway, so it is not the binding constraint.

**What it still does not buy.** An edge key can delete *its own* staged data,
because SeaweedFS folds object DELETE into the `Write` action and the edge
needs `Write` to upload at all. That is acceptable — the edge already holds
the originals in its facility backup — but it should be stated rather than
implied away. The mitigation that matters is that the edge uploader never
issues a delete: it uses a content-fingerprint state file instead.

**Migration.** Existing `ingest-bucket` keeps working; add per-site buckets,
move sites one at a time, retire the shared bucket last. No flag day.

---

## 1. Loki push authentication 🔴

Today: the token is minted, shipped and sent but **never validated** — the
push endpoint accepts unauthenticated writes from anything that can route to
it. The chart's attempted fix renders basic auth against a Secret nothing
creates, and the edge sends bearer, so a default install is dead instead.

### Do it properly: mTLS with per-edge client certificates

I originally proposed basic auth on the grounds that mTLS "needs a new
distribution path". **That was wrong.** `scripts/07b` already runs
`kubectl create secret ... loki-push-credentials` and
`kubectl create secret ... ca-bundle` against the edge cluster. Distributing a
client certificate is the same mechanism with one more Secret. The objection
that made basic auth look pragmatic does not exist.

Design:

* cert-manager issues `edge-<name>-client-tls` from the `ais-edge-ca` issuer,
  `commonName: <edge-name>`. One `Certificate` per entry in `edges`, so adding
  a site provisions its identity automatically.
* The secret-distribution bootstrap step copies it to the edge alongside the
  CA bundle it already copies.
* Vector's Loki sink uses `tls.crt_file` / `tls.key_file`.
* The Loki Ingress gets `auth-tls-secret` (the CA), `auth-tls-verify-client: on`,
  and `auth-tls-match-cn` built from the `edges` list.

What this buys over a shared token: **no shared secret material anywhere**,
automatic rotation by cert-manager (a token rotates when someone remembers
to), an identity that is cryptographically bound to the site rather than a
string anyone holding it can replay, and revocation by removing the site from
the list and upgrading — the CN no longer matches. It is also the same trust
root the S3 path already uses, so there is one PKI to reason about instead of
one PKI plus a bag of tokens.

**Deliberate non-goal: log READ isolation between sites.** Loki multi-tenancy
(`auth_enabled: true`) would give it, and it is the obvious "do it properly"
reflex — but it is the wrong call here and it is worth writing down why.
Tenanted rules are evaluated per tenant, so every fleet-wide alert we have
(`sum by (cluster) (...)` across sites) becomes impossible, and Grafana needs
per-tenant datasources to see anything. We would trade working cross-site
alerting for an isolation property nobody needs, since operations are
fleet-wide by design and Grafana is already admin-authenticated. The push path
is the boundary that matters, and mTLS is the right control for it.

---

## 2. Per-edge hostnames, and no computed ports 🔴

Every edge renders the same `apiHost`/`konnectivityHost`, so two sites produce
two Ingresses claiming one hostname. Separately, NodePorts are derived from an
edge's **position in the list** (`add 30443 $i`), so reordering or deleting an
entry silently moves a running site's port — while `resource-policy: keep`
guarantees the old Service still holds it.

### Do it properly: SNI routing, and delete NodePorts from the design

* Per-edge hostnames `k0s-<edge>.<domain>` / `konnectivity-<edge>.<domain>`.
* k0smotron `Cluster` uses `spec.service.type: ClusterIP`, published through
  the existing ssl-passthrough ingress on :443 by SNI — exactly what the
  management plane already does for SeaweedFS, Grafana and Loki. One mechanism
  for everything that faces the network.
* **No NodePorts at all.** Not "explicit instead of computed" — gone. A
  cluster-wide port allocation that has to be tracked per site is state
  outside the chart, and state outside the chart is what produced this bug.
  Sites that genuinely cannot do SNI are a separate, documented topology, not
  a field.
* Render-time guard: no two edges may resolve to the same hostname.

**Production DNS.** nip.io works and is fine for dev, but a production fleet
should have a real wildcard record (`*.edge.<org-domain>`). nip.io is a
third-party dependency in the control path of every child cluster's API
server, and it cannot be used with Let's Encrypt. Treat moving off it as part
of going to production, not as an optional tidy-up.

---

## 3. PKI 🔴

The immediate bug is that `certManager.enabled` ("install the subchart") is
used to decide where cert-manager reads cluster-scoped resources from. On this
cluster cert-manager was installed with `kubectl apply` and runs
`--cluster-resource-namespace=cert-manager`, so the CA Certificate lands
somewhere it will never be read.

But fixing only that leaves a bigger problem in place, and this is the moment
to deal with it.

### Do it properly: a two-tier CA, with the root key held offline

Today there is **one self-signed root CA whose private key lives in a
Kubernetes Secret on the management node, and it signs everything**. If that
node is compromised, or the Secret leaks, the attacker can mint a certificate
for any hostname in the fleet, and the only remedy is to re-issue and
redistribute trust to every edge site by hand. `rotate-ca.sh` exists precisely
because that is painful — a two-phase rotation run weeks apart.

The standard answer, and it costs very little here:

* **Root CA**: generated once, long-lived, its key exported and stored
  offline (password manager / HSM / sealed envelope), and **removed from the
  cluster**. It signs exactly one thing: the intermediate.
* **Intermediate CA**: lives in the cluster, is what cert-manager's
  `ClusterIssuer` actually uses, and is rotatable on a normal schedule
  *without touching any edge*, because edges trust the root.
* Edges keep trusting the root, so intermediate rotation is invisible to them.
  This is the whole point: it turns a fleet-wide redistribution event into a
  routine in-cluster operation.

Also settle, rather than defer:

* **Adopt the existing cert-manager into the release or explicitly do not.**
  Leaving it ambiguous is how the namespace bug happened. Recommendation:
  `certManager.enabled: false` by default and reference the existing install,
  with `clusterResourceNamespace` an explicit required value — because on
  every cluster we actually have, cert-manager is already there.
* **Back up the root key as part of the install**, not as a runbook step
  someone might skip. If it is only in a Secret, it is one `kubectl delete`
  from a fleet rebuild.
* Keep `commonName: "AIS Edge Root CA"` pinned to the live value, and add a
  render-time guard so changing it is impossible by accident — it re-issues
  the root and invalidates every distributed bundle.

---

## 4. Reclaimer completeness 🟠 — restructure it, do not patch it

XNAT creates the experiment on the **first** resource POST, so
`xnat_has_session` confirms existence, not delivery. An upload that died after
3 of 400 scans confirms, and the staged copy — including the 397 scans that
never arrived — is deleted.

I proposed adding a count comparison and a completion marker. That is a
better check bolted onto the wrong architecture, and it would leave the debt
in place.

### Do it properly: the component that has the knowledge does the deletion

The uploader knows exactly what it sent, how many resources, and what XNAT
answered. The reclaimer is a *different process, later, re-deriving that
knowledge from two external systems* — which is why it needs a completeness
heuristic at all. Move the responsibility:

* **The mgmt uploader deletes its own staged session** immediately after it
  has verified its upload, using knowledge it already holds. `xnat-ingest`
  already auto-generates a per-session `MANIFEST.json`, so "did everything
  arrive" is answerable against a real artifact rather than inferred.
* **The reclaimer becomes a garbage collector for residue only** — orphaned
  prefixes from a crashed uploader, empty directory entries, sessions whose
  uploader pod died mid-run. It can then be far more conservative: a long
  `minAge` (days, not `1d`), the two-consecutive-runs rule below, and it never
  needs to decide whether a session was *delivered*, only whether it has been
  *abandoned*.

This removes an entire class of bug rather than adding a guard against one
instance of it, and it makes the dangerous component boring.

**The race I found and dropped.** In the empty-prefix branch, `count == 0` →
delete, but a small single-part PUT can land between the count and the delete.
The multipart probe does not catch it because a small object is not multipart.
Fix: **require the prefix to have been empty on two consecutive runs**,
persisted in a small state object. At an hourly schedule that closes the race
completely without locking.

---

## 5. Counting objects 🟠

`--output text` applies `--query` **per page**, so any session over 1000
objects returns a multi-line answer, fails the numeric check and is kept
forever. Fail-safe, but it silently disables reclaiming for exactly the large
sessions that matter most.

### Do it properly

* Use `--output json` (fully buffered, one document) and parse it explicitly
  in Python — the image ships it — failing hard on anything unexpected.
* **Never derive a count from a pipeline whose left side can fail.**
  `aws ... | wc -l` yields `0` when `aws` errors, and `0` reads as "empty,
  safe to delete". This is the exact shape of the bug that deleted a session
  during earlier testing.
* Add a unit test with a mocked multi-page response, so the paging behaviour
  is pinned rather than rediscovered.

---

## 6. Alerting correctness 🟠 — fix the class, not the instance

`SeaweedFSDiskFull` selects `kubelet_volume_stats_*` for a hostPath volume.
Those series do not exist and never will — the hostPath plugin has no metrics
provider. The alert has been "green" its whole life.

Three of the Prometheus rules were already known to be unable to fire
(`EdgeWorkerDisconnected`, `KonnectivityTunnelFlapping`, `EdgePodCrashLoop`)
because mgmt Prometheus cannot scrape across the one-way konnectivity tunnel.
That is four out of ~21. **An alert that cannot fire is worse than no alert,
because it reads as coverage.**

### Do it properly

* Point the disk alert at SeaweedFS's own `:9324` metrics, which is the
  correct source regardless.
* Re-express the three edge-cluster rules as Loki absence rules over Vector's
  own log stream, which does cross the tunnel.
* **Build an alert smoke-test harness**: for every rule, inject a synthetic
  log line or metric and assert the rule fires. Run it in CI. This is the only
  thing that stops the class of bug recurring, and it is the difference
  between an alerting stack and a collection of hopeful YAML.

---

## 7. Data-retention guarantees 🟠 — audit the whole class

Loki's StatefulSet carries `persistentVolumeClaimRetentionPolicy: Delete`.
`helm.sh/resource-policy: keep` does **not** protect against it — that
annotation governs Helm, not the StatefulSet controller. I had assumed the
annotation was sufficient, and used it as the retention story throughout.

### Do it properly

* Set `enableStatefulSetAutoDeletePVC: false`.
* **Audit every StatefulSet and every PVC in both releases** for the same
  field, including inside subcharts, and assert it in CI: render the chart and
  fail if any PVC that holds data can be auto-deleted. The annotation gave a
  false sense of safety in one place, so it should be assumed to have done so
  everywhere until checked.

---

## 8. Adopting the existing cluster 🟠

`Namespace/edge-dev` and `Cluster/edge-dev` exist without Helm ownership
metadata, so the first install aborts before applying anything.

### Do it properly

* `scripts/adopt-existing.sh` with a **dry-run default**, listing exactly what
  it would label and annotate, and a written record of what was adopted.
* CI must also prove the **greenfield** path: the chart installs cleanly into
  an empty kind cluster with no adoption at all. Otherwise adoption quietly
  becomes a prerequisite and a new site cannot be built from the chart alone.

Not a force flag, and not `--replace`. Both hide exactly the collision that
tells you the cluster is not in the state you think it is.

---

## 9. Sizing and immutable fields 🟠

`k0smotron.persistence.size: 10Gi` renders against a live 1Gi
`volumeClaimTemplate`. Those are immutable, so k0smotron's update is rejected
and its reconcile loop wedges.

### Do it properly

* Separate keys for the control-plane volume and the etcd volume; they are
  independent and one knob for two volumes is how this happened.
* Default to the live 1Gi so an upgrade is a no-op on existing sites.
* **A preflight check in the upgrade path** that compares every rendered
  immutable field against what is live and refuses to proceed on a mismatch,
  naming both values. Immutable-field conflicts fail *after* Helm has started
  applying, which is the worst time to discover them.

---

## 10. Two more things worth doing while we are here

Neither is in the findings list, but both are the same category of debt.

**Per-site XNAT credentials.** One fleet-wide XNAT account writes every site's
data. A compromised edge — or a bug in one site's routing map — can write into
any project. XNAT supports per-project permissions, so each site should have
its own account scoped to its own projects. This is the same argument as
bucket-per-site, applied to the other end of the pipeline, and it is cheap to
do now and expensive to retrofit once sites are live.

**The edge S3 identity needs `Write`, which includes DELETE.** SeaweedFS folds
object deletion into the `Write` action, so an edge can delete its own staged
data. With bucket-per-site the blast radius is one site, and the edge holds
the originals in its facility backup, so this is acceptable — but it should be
recorded as a known property, not discovered later. The mitigation that
matters is behavioural: the edge uploader never issues a delete, using a
content-fingerprint state file instead.

---

# Critique of how this was produced

Asked for, and worth writing down honestly.

## What went wrong in my own work

**I wrote confident comments asserting properties I had not verified.** The
S3 isolation claim is the clearest case: I wrote that losing an edge key
"exposes neither XNAT nor any other site's data" into `values.yaml`, as
documentation, without testing it. It was half wrong, and it was wrong in the
direction that matters. A comment that asserts a security property is a claim,
and I should hold it to the same standard as code. **Rule going forward: no
comment states a safety or security property unless there is a measurement
behind it.**

**I praised the reclaimer before it had been adversarially reviewed.** I read
it, called it "genuinely good work", and listed the fail-safe properties I had
checked. I missed that its central check confirms existence rather than
completeness — the single most important thing about it. Reading for "are the
stated properties present" is not the same as asking "what is this actually
checking, and is that the right question".

**I dropped a thread I had explicitly opened.** Mid-review I noticed a race in
the empty-prefix branch (count=0 → a small single-part PUT lands → delete) and
said I would come back to it after the verify results. I never did. It is
still unfixed and is not in the findings list above because no agent found it
either. Adding it now: **the empty-prefix delete should require the prefix to
have been empty on two consecutive runs**, which closes the race for an hourly
job without needing locks.

**I under-weighted that none of this has ever run.** Everything so far is
render-time and dry-run verification. That is real, but the volume of output
invites more confidence than is earned. Nothing has ingested a DICOM.

**Comment density is itself a risk.** These files carry a lot of explanatory
comment. That is deliberate and I would defend it for the incident-derived
ones — but comments that explain *why* age badly and silently, and I have
already produced two that were wrong. Fewer, load-bearing, verified comments
would be better than many confident ones.

## What went wrong in the method

**Parallel agents produced confident, plausible, wrong recommendations.** The
Vector escaping advice would have broken every management log stream, and it
was written with a `>>> READ THIS BEFORE PASTING <<<` banner. The adversarial
verify pass caught it — and independently, so did checking the live cluster.
The lesson is not "don't use agents" but that **a subagent's confidence is
uncorrelated with its correctness**, and anything load-bearing needs an
independent check against reality, not a second opinion.

**The verify pass earned its cost.** 5 critical and 16 high findings, several
of which I had personally read past. It should have run before I committed,
not after.

**Version pinning was done from what is running, which is right, but I did not
check those versions for known CVEs** — worth doing before this is called
production-grade.

## Structural things I would change

* `edge.validate` is invoked from exactly one template (`storage.yaml`). If
  that file is ever renamed or made conditional, **every guard silently stops
  running**. It should be invoked from a dedicated always-rendered template,
  or from every template.
* We now have **two edge charts**: `helm/edge` (James's, with my three fixes)
  and `charts/edge` (consolidated). That duplication has to be resolved before
  this merges, or sites will install the wrong one.
* There is no CI. Everything verified here was verified by hand in a session.
  `helm lint` + `helm template` + `bash -n` + the JSON/YAML parse checks +
  a `--dry-run=server` against a kind cluster should all run on every push.

## Recommended order of work

Ordered so that nothing is built on something that is about to change shape.

1. **Bucket per site (§0) and per-site XNAT credentials (§10).** Both change
   the shape of the uploader and reclaimer, so everything else is built on top
   rather than retrofitted onto them.
2. **PKI (§3).** The root/intermediate split has to happen before more
   certificates are issued from the current root, and the mTLS work in §1
   depends on the issuer being settled.
3. **mTLS on the Loki push path (§1)** and **per-edge hostnames + SNI (§2).**
   Nothing installs correctly for more than one site until these land.
4. **Restructure the deletion responsibility (§4)**: uploader deletes what it
   delivered, reclaimer becomes a conservative GC, plus the two-consecutive-runs
   rule for empty prefixes. Ship `dataPolicy.enabled: false` until this is done
   and tested.
5. **CI first, then the rest (§5–§9).** The alert smoke-test harness and the
   PVC-retention assertion are what stop these classes of bug recurring, so
   they should exist before the remaining fixes are made, not after.
6. Adoption script, then a real end-to-end install on this VM, then the
   documentation rewrite.

Steps 1–4 are the ones that are expensive to retrofit once sites are live.
Steps 5–6 are expensive to skip.

---

# Re-critique of the recommendations above

Done before implementing. Six of my own recommendations did not survive it.
Measurements are from the live cluster.

## R1. "The uploader deletes what it delivered" is not implementable — §4 revised

The recommendation was architecturally right and practically wrong. The
management uploader **is** `xnat-ingest upload`, an upstream binary. It does
not delete from S3, and with `--loop` it processes every session in one
invocation, so there is no per-session hook to attach a deletion to. Making
"the component with the knowledge deletes" true would mean wrapping it and
parsing its log output to infer per-session success — which is precisely the
fragile coupling I rejected for the edge `assign` stage two days ago.

**Revised §4.** Keep the reclaimer as a separate component, and fix the check
rather than the architecture:

* Compare **`MANIFEST.json` against XNAT's actual resource inventory** for the
  session. `xnat-ingest` already writes that manifest, so this is a real
  file-by-file completeness check, not a heuristic — it answers "is everything
  that was staged now in XNAT", which is the question that matters.
* Keep minAge, and keep the two-consecutive-runs rule for empty prefixes.
* Separately, **open an upstream issue/PR on xnat-ingest for S3 retention**.
  The absence of it is the root cause; everything here is a workaround, and it
  should be labelled as one rather than quietly owned forever.

I was wrong to present a restructure as obviously correct without checking
whether the component I was restructuring was ours to change.

## R2. mTLS introduces a rotation failure mode I did not account for — §1 amended

cert-manager renews the client certificate **on the management cluster**. The
edge holds a copy that the bootstrap script pushed once. Nothing re-pushes it.
So a certificate that renews at two-thirds of its lifetime leaves the edge
holding an expired one, and log shipping stops silently at a date nobody has
in a calendar. A bearer token does not expire, so mTLS is strictly *worse*
here unless renewal is handled.

**Amended §1**, two additions, both required:

* **A cert-sync CronJob on the management cluster** that pushes renewed
  Secrets into each child cluster using the kubeconfigs it already holds. This
  is not extra complexity — it **replaces** the manual `scripts/07b`
  distribution step, and it can carry the CA bundle too. Net reduction in
  moving parts.
* **mTLS must not ship before the log-absence alert** (§6). Without it, the
  failure mode is invisible. Sequencing matters more than either piece.

## R3. Per-site uploaders have a measured ceiling — §0 amended

Measured on the live uploader: **231Mi resident, 4m CPU**, and the Deployment
has **no resource limits at all** (`resources: {}` — its own latent bug).
The management node has 16Gi / 8 CPU allocatable.

So N uploaders costs ~231Mi each: fine at 5 sites, tight at 15 alongside
Prometheus, Loki, Grafana and SeaweedFS, and not viable at 30.

**Amended §0.** Keep per-site uploaders — the isolation argument stands — but:

* Size them from the measurement: 128Mi request / 512Mi limit, and set limits
  everywhere, which the current deployment does not do.
* **State the ceiling honestly in the docs: roughly 15 sites per management
  node.** Beyond that the single-management-node design needs revisiting, and
  pretending otherwise is how a fleet discovers a scaling wall in production.
* I considered CronJob-per-site instead (cheaper at rest). Rejected: a large
  session benefits from continuous progress, and a cold start plus scheduling
  delay on every cycle is a worse trade than idle memory.

## R4. SNI would change a working system — §2 amended

`edge-dev` today runs `service.type: NodePort` with `apiPort: 30443`,
`konnectivityPort: 30132` and `externalAddress: 203.101.224.240`, and it
works. My recommendation deletes NodePorts "from the design", which on this
cluster means changing the one thing that is currently proven.

**Amended §2.** The destination is unchanged — per-edge hostnames and SNI —
but:

* Support **both** exposure modes per edge, with NodePort as the documented
  legacy path, so existing sites are not forced through a change they did not
  ask for.
* **Verify ssl-passthrough works for the konnectivity gRPC stream** before any
  site is migrated. I have not tested this, and konnectivity is the tunnel
  every edge depends on. Asserting it works because SNI passthrough works for
  HTTPS is exactly the kind of inference this document exists to stop.
* Migrate one site, confirm, then the rest.

## R5. The offline root must be optional — §3 amended

An offline root requires an out-of-band signing ceremony that cannot live in
`install.sh`. For a tier-1 single-site install that is pure friction for no
benefit.

Also worth being honest about the threat model: **if the management node is
compromised the attacker already holds the staged imaging, the XNAT
credentials and every child cluster kubeconfig.** The CA is not the crown
jewel. What the two-tier split actually buys is *recoverability* — rotating a
compromised intermediate without touching every edge, versus a fleet-wide
trust redistribution by hand. That is still worth it, but it is a different
and smaller claim than "the root is protected".

**Amended §3:** `certManager.ca.mode: selfSigned | intermediate`. `selfSigned`
stays the default for dev and tier-1; `intermediate` is required for a
multi-site production fleet and documented with the ceremony.

## R6. Alert testing splits into two very different problems — §6 amended

I proposed one smoke-test harness. In practice:

* **PrometheusRules have `promtool test rules`** — a real unit-test format,
  no cluster, runs in seconds. There is no excuse for not having this, and it
  would have caught `SeaweedFSDiskFull` immediately.
* **LogQL rules have no equivalent.** Testing those genuinely needs a Loki
  with the ruler running and time to evaluate.

**Amended §6:** promtool unit tests in CI on every push; a heavier
docker-compose Loki smoke test run nightly and before a release. Pretending
one harness covers both would have produced a harness that covers neither.

## What survived unchanged

§5 (count with `--output json`, never through a failing pipe), §7 (PVC
retention audit in CI), §8 (adoption script with dry-run, plus a greenfield CI
path), §9 (preflight on immutable fields), §10 (per-site XNAT credentials).
And §0's core: bucket per site, which is measured and not in question.

## Net effect on sequencing

The dependencies are tighter than the original order implied:

* §1 (mTLS) now **depends on** the cert-sync job and on §6's absence alert.
* §6 (promtool half) should come **first**, not fifth — it is cheap and it is
  the thing that catches the rest.
* §2 (SNI) needs a konnectivity passthrough test before it is committed to.

Revised order: **§6-promtool → §0 → §3 → cert-sync → §1 → §4 → §2 → §5/§7/§8/§9 → §10**.
