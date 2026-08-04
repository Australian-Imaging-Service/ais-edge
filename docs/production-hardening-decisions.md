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

## 1. Loki push path is dead on a default install 🔴

`observability.loki.push.requireAuth: true` renders an Ingress with
`auth-type: basic` + `auth-secret: loki-push-auth`, but **nothing creates that
Secret**, and `charts/edge` pushes with `strategy: bearer`. A default install
therefore rejects every edge log push. Worse, the pre-existing behaviour was
the opposite failure: the token was minted, shipped and sent but *never
validated*, so `loki.<domain>:443` accepted unauthenticated writes from
anything that could route to it.

### Recommendation: switch the edge to basic auth and generate the htpasswd Secret

nginx-ingress cannot validate a bearer token natively; it can do basic auth
with an htpasswd Secret. Vector's Loki sink supports `strategy: basic`. So:

* `charts/edge` Vector sink → `strategy: basic`, user = the edge name,
  password = the existing per-edge push token (no new secret material, no new
  distribution path — the token Secret already reaches every edge).
* `charts/mgmt` generates one `loki-push-auth` Secret containing an htpasswd
  line per edge, from the same `edges[].lokiTokenRef` Secrets.
* Per-site revocation stays: drop the edge from the list, upgrade, that
  site's credential stops working.

**Alternative, stronger, more work: mTLS.** We already run an internal CA, so
issuing a client certificate per edge is natural and nginx-ingress supports
`auth-tls-secret`. It is the better long-term answer. It needs a per-edge
client cert *distributed to the edge*, which is a new distribution path — the
edges currently receive only the CA bundle, not a client identity. I would do
basic auth now and treat mTLS as a follow-up, not block on it.

**Do not** turn on Loki multi-tenancy to solve this: `auth_enabled: true`
changes tenant IDs and orphans every chunk already in `logs-bucket`.

---

## 2. Every edge renders the same apiHost / konnectivityHost 🔴

Two edges produce two Ingresses claiming one hostname. The multi-site
capability this chart is supposed to deliver does not actually work, which is
exactly the defect the port claimed to have fixed.

Related: NodePorts are derived from the edge's **position in the list**
(`add 30443 $i`). Reorder or delete an entry and a running site's cluster-wide
NodePort silently moves to a different site — and because the Cluster CRs
carry `resource-policy: keep`, the old Service is still holding the old port.

### Recommendation: per-edge hostnames, and stop deriving ports from list order

* `k0s-<edge>.<domain>` and `konnectivity-<edge>.<domain>`. A wildcard
  resolver such as nip.io handles this with no DNS work; a real domain needs
  one wildcard record.
* Route by **SNI on :443** through the existing ssl-passthrough ingress, which
  is what the management plane already does for SeaweedFS/Grafana/Loki. That
  removes NodePorts from the design entirely — no port allocation to manage,
  no collisions, nothing tied to list order.
* If a site genuinely needs a NodePort, it becomes an **explicit field on that
  edge's entry**, never a computed one. A running site's port must never be a
  function of anything else's presence.

---

## 3. cert-manager namespace keys off the wrong thing 🔴

`certManager.enabled` means "install the subchart", but the template uses it
to decide *where cert-manager reads cluster-scoped resources from*. On this
cluster cert-manager was installed with `kubectl apply` (no Helm labels,
verified) and runs `--cluster-resource-namespace=$(POD_NAMESPACE)` =
`cert-manager`. With the chart default, the CA Certificate lands in a
namespace cert-manager does not read, and no certificate ever issues.

### Recommendation

* Add `certManager.clusterResourceNamespace` (default `cert-manager`),
  independent of `enabled`.
* Default `certManager.enabled: false`, because on every cluster we actually
  have, cert-manager is already installed. Installing the subchart is the
  greenfield case, not the common one.
* Guard: if `enabled: false`, verify at render time that the namespace value
  was set deliberately rather than defaulted.

---

## 4. The reclaimer can delete a partially-uploaded session 🟠 — the data-loss one

XNAT creates the experiment as soon as the **first** resource is POSTed. An
upload that dies after 3 of 400 scans leaves an experiment labelled
`<visit>`. `xnat_has_session` then matches that label exactly, logs
`reclaim_confirmed`, and deletes the staged copy — including the 397 scans
that never arrived.

This is the one component in either chart whose bugs destroy patient data, and
its central check confirms the wrong property: **existence, not completeness.**

### Recommendation: three independent conditions, all required

1. **Count comparison, not existence.** Ask XNAT for the experiment's
   scan/resource count and require it to be `>=` the staged object count.
   This is the check that actually answers "did it all arrive".
2. **A completion marker written by the uploader.** After a verified upload
   the mgmt uploader writes `_COMPLETE` into the session prefix; the reclaimer
   requires it. Cheap, and it makes "the uploader believes it finished" an
   explicit fact rather than an inference.
3. **minAge on top**, unchanged.

Require all three. Any one missing → keep. The cost is one extra XNAT call per
session and one PUT per upload; the benefit is that no single wrong answer can
cause a delete.

Until this is implemented, ship with **`verifyAgainstXnat: true` and
`dataPolicy.enabled: false`** so the reclaimer only ever logs.

---

## 5. `aws --query 'length(...)'` returns one number per page 🟠

With `--output text`, the AWS CLI applies `--query` **per page**, so any
session with more than 1000 objects yields a multi-line answer, fails the
numeric check, and is kept forever as `listing_failed`. Fail-safe, so not
dangerous — but it silently disables reclaiming for exactly the large sessions
that matter most for disk.

### Recommendation

Count with `--output json` and parse it explicitly (the image has Python),
failing hard if the JSON does not parse. Never derive a count from a pipeline
whose left-hand side can fail — `aws ... | wc -l` returns `0` on failure,
which reads as "empty, safe to delete".

---

## 6. `SeaweedFSDiskFull` still cannot fire 🟠

The alert selects `kubelet_volume_stats_used_bytes{persistentvolumeclaim=~".*seaweedfs.*"}`.
Wrapping a hostPath in a PV/PVC does **not** make kubelet emit those series —
the hostPath volume plugin has no metrics provider. The port added a comment
asserting this was fixed. It is not.

### Recommendation: alert on SeaweedFS's own metrics, which is the right source anyway

SeaweedFS exports volume and disk statistics on `:9324`, already scraped by the
ServiceMonitor. Alert on those rather than on kubelet PVC stats, which will
never exist for this volume. Optionally also enable node-exporter on the
management node only, for whole-disk headroom.

Generalise the lesson: **an alert that cannot fire is worse than no alert**,
because it reads as coverage. Worth a one-off audit that every rule has
actually fired at least once in a test.

---

## 7. Loki's PVC is deleted with the StatefulSet 🟠

The rendered StatefulSet carries
`persistentVolumeClaimRetentionPolicy: {whenDeleted: Delete, whenScaled: Delete}`
(the Loki chart's `enableStatefulSetAutoDeletePVC` default).
`helm.sh/resource-policy: keep` does not protect against this — it governs
Helm, not the StatefulSet controller.

### Recommendation

Set `loki.singleBinary.persistence.enableStatefulSetAutoDeletePVC: false`.
Then audit every other StatefulSet in the release for the same field —
`resource-policy: keep` gave a false sense of safety here and may elsewhere.

---

## 8. First install aborts on pre-existing objects 🟠

`Namespace/edge-dev` and `Cluster/edge-dev` already exist, created
imperatively, with no `meta.helm.sh/release-name` or
`app.kubernetes.io/managed-by: Helm`. Helm refuses to adopt them and the
install fails before applying anything.

### Recommendation: an explicit adoption step, not a force flag

A small `scripts/adopt-existing.sh` that labels and annotates the existing
objects for the target release, run once, with a dry-run mode that lists what
it would touch. This is the standard Helm adoption path and it is auditable.

The alternative — install into a fresh namespace and migrate sites one at a
time — is cleaner but means a scheduled outage per site. Adoption is the
right call for an existing cluster with live data.

---

## 9. k0smotron etcd size is immutable on a running site 🟠

`k0smotron.persistence.size: 10Gi` renders against a live 1Gi
`volumeClaimTemplate`. Those are immutable, so k0smotron's update is rejected
and its reconcile loop wedges.

### Recommendation

* Default to the live **1Gi** so an upgrade is a no-op on existing sites.
* Split the value: the control-plane volume and the etcd volume are
  independent and should not share one key.
* Document that changing it on a running site requires recreating the
  StatefulSet — a deliberate, scheduled operation.

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

1. Bucket per site (§0) — it changes the shape of the uploader and reclaimer,
   so everything else should be built on top of it, not retrofitted.
2. The four 🔴 items (§1–3) — nothing installs correctly until these are done.
3. The reclaimer completeness check (§4) and the empty-prefix race — ship
   `dataPolicy.enabled: false` until both land.
4. The remaining 🟠 items.
5. CI, then a real end-to-end install on this VM, then the documentation.
