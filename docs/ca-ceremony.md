# The out-of-band root CA ceremony

For `certManager.ca.mode: intermediate` in `charts/mgmt`. If you are running
`mode: selfSigned` — the default, and the right answer for dev and for a
tier-1 single-site install — none of this applies to you and you can stop
reading.

---

## What the two modes are

| | `selfSigned` (default) | `intermediate` |
|---|---|---|
| Who generates the root | cert-manager, in the cluster | you, on an offline machine |
| Where the root key lives | a Secret on the management node | offline, see below |
| What the cluster signs with | the root | an intermediate signed by the root |
| What edges pin (`ca-bundle`) | the root | the root |
| Rotating the signing key | re-distribute trust to every site by hand | replace one Secret |
| Chart renders a CA `Certificate` | yes | **no** |

In `intermediate` mode the chart renders no bootstrap `Issuer` and no CA
`Certificate`. That absence is the point: the key needed to sign a CA
certificate is deliberately not in the cluster, so nothing in the cluster can
generate one. The chart consumes an existing Secret, named by
`certManager.ca.intermediate.secretRef`, and refuses to render if that name is
empty.

## What this buys, and what it does not

It buys **recoverability**, not root protection.

If the management node is compromised, the attacker already holds the staged
imaging in SeaweedFS, the XNAT credentials and every child cluster kubeconfig.
Moving the root key offline protects none of that, and anyone claiming it
"secures the fleet" is selling something.

What it changes is what happens *next*. With one self-signed root in a Secret,
recovering means generating a new root and hand-carrying a new trust anchor to
every site — which is what `scripts/rotate-ca.sh` does, and why it is a
two-phase procedure run weeks apart. With the split, the compromised or
expiring thing is the intermediate; you replace one Secret in one namespace and
the edges never notice, because what they pin is the root and the root has not
changed.

That is a smaller claim than the usual one, and it is the only one being made
here.

---

## Where the root key lives

Decide this **before** you generate anything, because the answer determines
whether the ceremony was worth doing at all. A root key that ends up on the
management node, in git, in a Kubernetes Secret, or in the same password vault
that holds the cluster admin credentials has bought you nothing — it is back
inside the blast radius you moved it out of.

In rough order of preference:

1. **An HSM or a hardware token** (YubiKey PIV, SoftHSM on an air-gapped box).
   The key is never extractable, so "did a copy leak" stops being a question
   anyone has to answer.
2. **An encrypted key file on removable media**, two copies, in two physically
   separate locked locations, with the passphrase held by a different person
   and stored separately from both copies. The commands below assume this.
3. **The institution's credential-escrow / secrets-management service**, if it
   is separate from the infrastructure this CA signs for. If it is not
   separate, this is option 4.
4. Anywhere on the management node. This is not two-tier; it is one tier with
   extra steps.

Record, in the operations runbook and not only in someone's head:

* the SHA-256 fingerprint of the root certificate;
* the root's `notAfter` date, with a calendar reminder at least a year before;
* who holds the media and who holds the passphrase;
* the date and operator of every signing, including this first one.

The root's *public* certificate is not secret. Commit it, publish it, put it
in the `ca-bundle` Secret on every edge. Only the key is sensitive.

---

## The ceremony

Run on a machine that is not the management node and is not on the imaging
network. All commands below were run and their output checked on
**OpenSSL 3.0.2**; `-addext` on `openssl req -x509` needs 1.1.1 or newer.

### 1. Generate the root

The CN is pinned. It must be `AIS Edge Root CA`, matching the CA already
deployed on the existing management cluster, because every `ca-bundle` already
distributed to every edge verifies against that subject. `charts/mgmt` refuses
to render if `certManager.ca.commonName` is anything else.

```bash
openssl genrsa -aes256 -out ais-edge-root-ca.key 4096

openssl req -x509 -new -key ais-edge-root-ca.key -sha256 -days 3650 \
  -subj "/CN=AIS Edge Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -out ais-edge-root-ca.crt
```

`-aes256` prompts for a passphrase. Use one; an unencrypted root key on
removable media is a root key that leaks the first time the media does.

Check it before going further:

```bash
openssl x509 -in ais-edge-root-ca.crt -noout -subject -issuer -dates
openssl x509 -in ais-edge-root-ca.crt -noout -text | grep -A2 "Basic Constraints"
openssl x509 -in ais-edge-root-ca.crt -noout -fingerprint -sha256
```

Expected: subject and issuer both `CN = AIS Edge Root CA`, Basic Constraints
`critical, CA:TRUE`. Write the fingerprint into the runbook now.

### 2. Generate the intermediate key and CSR

Name it for the year or the rotation, not "intermediate" — you will have more
than one, and telling them apart in a certificate chain later is otherwise
guesswork.

```bash
openssl genrsa -out ais-edge-intermediate-2026.key 4096

openssl req -new -key ais-edge-intermediate-2026.key \
  -subj "/CN=AIS Edge Intermediate CA 2026" \
  -out ais-edge-intermediate-2026.csr
```

The intermediate key is **not** encrypted: cert-manager has to read it
unattended out of a Secret. Its exposure is the exposure of the management
node, which is the trade this whole design accepts.

### 3. Sign the CSR with the root

```bash
cat > intermediate.ext <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
EOF

openssl x509 -req -in ais-edge-intermediate-2026.csr \
  -CA ais-edge-root-ca.crt -CAkey ais-edge-root-ca.key \
  -CAcreateserial -days 1826 -sha256 \
  -extfile intermediate.ext \
  -out ais-edge-intermediate-2026.crt
```

`pathlen:0` means this intermediate may sign leaf certificates and may not
sign another CA. Five years (`1826`) is deliberately shorter than the root's
ten: the point of the split is that this one is replaceable, so replacing it
should be a rehearsed operation rather than a first-time one at expiry.

`-days` and the rotation calendar are the same fact written twice. Put the
`notAfter` in the runbook with a reminder at 4 years, not at 4 years 11 months
— see "Rotating the intermediate" below for why the tail matters.

Verify before it goes anywhere:

```bash
openssl x509 -in ais-edge-intermediate-2026.crt -noout -subject -issuer -dates
openssl x509 -in ais-edge-intermediate-2026.crt -noout -text | grep -A2 "Basic Constraints"
openssl verify -CAfile ais-edge-root-ca.crt ais-edge-intermediate-2026.crt
```

Expected: issuer `CN = AIS Edge Root CA`, Basic Constraints
`critical, CA:TRUE, pathlen:0`, and `ais-edge-intermediate-2026.crt: OK`.

Confirm the key and certificate are actually a pair. A mismatch here produces
a cert-manager error message that does not say "wrong key":

```bash
openssl x509 -noout -modulus -in ais-edge-intermediate-2026.crt | openssl sha256
openssl rsa  -noout -modulus -in ais-edge-intermediate-2026.key | openssl sha256
```

The two digests must be identical.

### 4. Put the root key away

Before the intermediate goes near a cluster, while the ceremony is still the
thing you are doing:

* copy `ais-edge-root-ca.key` to the storage chosen above, twice, verifying
  each copy (`sha256sum`);
* **shred the working copy** — `shred -u ais-edge-root-ca.key` on the ceremony
  machine, along with `.srl` serial files if that machine is not itself the
  offline store;
* keep `ais-edge-root-ca.crt` (public) — it goes to every edge.

A root key still sitting in `~/ceremony/` a month later is the normal way this
design fails.

### 5. Load the intermediate into the cluster

The Secret lives in cert-manager's `--cluster-resource-namespace`, which on
this fleet is `cert-manager` (`certManager.clusterResourceNamespace`). A
`ClusterIssuer`'s `spec.ca.secretName` is resolved there and nowhere else — the
namespace of the `Certificate` asking for a cert is irrelevant. Getting this
wrong produces a `ClusterIssuer` reporting "secret not found" while every
`Certificate` looks fine.

```bash
kubectl -n cert-manager create secret generic ais-edge-intermediate-ca \
  --from-file=tls.crt=ais-edge-intermediate-2026.crt \
  --from-file=tls.key=ais-edge-intermediate-2026.key \
  --from-file=ca.crt=ais-edge-root-ca.crt
```

`generic`, not `tls`: `kubectl create secret tls` accepts only `--cert` and
`--key`, and `ca.crt` has to be in there — it is the root, and it is what
should end up in the `ca-bundle` every edge pins.

This Secret is **not** a Helm resource. It is never templated, never in git,
and `helm uninstall` cannot remove it. Back it up wherever the site's other
non-Helm cluster state is backed up; losing it means another ceremony, which
means fetching the root key again.

### 6. Point the chart at it

```yaml
certManager:
  clusterResourceNamespace: cert-manager
  ca:
    mode: intermediate
    intermediate:
      secretRef: ais-edge-intermediate-ca
```

`certManager.ca.commonName` stays `AIS Edge Root CA` and
`certManager.ca.secretName` stays whatever it was — in `intermediate` mode the
chart never writes to it, and the chart refuses to render if the two Secret
names are the same, because sharing them means a later switch back to
`selfSigned` would let cert-manager overwrite your offline-signed intermediate
with a freshly generated root.

### 6b. And re-point cert-sync at the Secret that now holds the root

Not optional, and nothing catches it for you. `certSync.secrets[0]` sources the
edge `ca-bundle` from `ais-edge-ca-secret` in the `cert-manager` namespace — the
Secret **cert-manager generates from the CA `Certificate`**. In `intermediate`
mode the chart renders no CA `Certificate` and no bootstrap `Issuer` at all
(that absence is the whole point: the root key is offline), so
`ais-edge-ca-secret` is never created. Left as-is, every cert-sync run logs
`sync_failed` for a Secret that does not exist, no edge ever receives
`ca-bundle`, and the edge pods that mount it sit in
`CreateContainerConfigError` — the first row of the troubleshooting table in
`README.md`, reached from a change that looked like it only touched the CA.

The render guards do not stop this: the checks in
`charts/mgmt/templates/cert-sync.yaml` are keyed on
`$src.name == certManager.ca.secretName` and are mode-blind, so they say nothing
when the mode makes that Secret unreachable.

The ceremony Secret already carries the right material — step 5 put the **root**
in its `ca.crt`, which is exactly what edges pin. So point the entry at it:

```yaml
certSync:
  secrets:
    - source:
        namespace: cert-manager        # certManager.clusterResourceNamespace
        name: ais-edge-intermediate-ca # == certManager.ca.intermediate.secretRef
        keys:
          ca.crt: ca.crt               # ca.crt ONLY — see below
      destination:
        namespace: <the edge namespace>
        name: ca-bundle
        type: Opaque
```

CAUTION: copy `ca.crt` and nothing else. The chart's "never distribute
`tls.key`" guard only fires for `certManager.ca.secretName`, so with the
intermediate named here it is silent — and `tls.key` in this Secret is the
intermediate's signing key. Distributing it would let any edge mint a
certificate for any hostname in the fleet.

Then:

```bash
helm upgrade --install mgmt charts/mgmt \
  --namespace ais-mgmt --create-namespace \
  -f sites/<site>/values.yaml --timeout 15m
```

`--namespace` is load-bearing, not decoration. `install.sh` installs this
release as `mgmt` into `ais-mgmt` (`MGMT_RELEASE` / `MGMT_NS`). Helm scopes a
release to a namespace, so the same command without `--namespace` targets your
kubeconfig's current namespace — normally `default` — and creates a **second,
separate** `mgmt` release there. It reports a successful upgrade, the live
release in `ais-mgmt` is untouched, and nothing about the CA has changed.

---

## Verify after install

None of this can be checked at render time — Helm cannot read cluster state —
so these are not optional.

```bash
# 1. The issuer accepted the Secret.
kubectl get clusterissuer ais-edge-ca -o wide
#    Expect READY=True. "secret not found" means wrong namespace;
#    "failed to get keypair" means a missing or malformed tls.crt/tls.key.

# 2. Something actually gets issued from it. The leaf certificates live in
#    the RELEASE namespace — ais-mgmt with the installer's defaults. There
#    is no `observability` namespace: observability is a set of subcharts of
#    charts/mgmt and renders wherever the release is installed.
kubectl -n ais-mgmt get certificate
kubectl -n ais-mgmt describe certificate loki-tls | tail -20

# 3. THE ONE THAT MATTERS: what the server presents must include the
#    intermediate. Measured locally with openssl 3.0.2: a leaf signed by
#    this intermediate does NOT verify against the root alone —
#      openssl verify -CAfile root.crt leaf.crt
#      -> error 20 ... unable to get local issuer certificate
#    and verifies only when the intermediate is supplied as well. Edges pin
#    the ROOT, so if the served chain omits the intermediate, every edge's
#    TLS validation fails.
#
#    This chart has NOT been run in intermediate mode against a live
#    cluster, so whether cert-manager's CA issuer emits the full chain into
#    tls.crt is UNVERIFIED here. Check it before migrating any site:
kubectl -n ais-mgmt get secret loki-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | grep -c "BEGIN CERTIFICATE"
#    Expect 2 (leaf + intermediate), not 1.

#    And end to end, from a machine holding only the root:
openssl s_client -connect loki.<domain>:443 -servername loki.<domain> \
  -CAfile ais-edge-root-ca.crt </dev/null 2>&1 | grep -E "Verify return code|s:|i:"
#    Expect "Verify return code: 0 (ok)" and a chain showing the leaf, the
#    intermediate, and the root as issuer.
```

If step 3 shows one certificate, stop. Do not migrate a site; fix the chain
first. This is the failure mode that looks fine on the management node and
breaks every edge at once.

---

## Rotating the intermediate

This is the operation the whole design exists to make cheap. Edges are not
touched, because the root they pin has not changed.

1. Fetch the root key from offline storage. Repeat steps 2–4 with a new name
   (`ais-edge-intermediate-2031`).
2. Load it under a **new** Secret name, so the old one is still there to roll
   back to:
   ```bash
   kubectl -n cert-manager create secret generic ais-edge-intermediate-2031 \
     --from-file=tls.crt=ais-edge-intermediate-2031.crt \
     --from-file=tls.key=ais-edge-intermediate-2031.key \
     --from-file=ca.crt=ais-edge-root-ca.crt
   ```
3. Point `certManager.ca.intermediate.secretRef` at the new Secret — and the
   `certSync` entry from step 6b with it, since that is the Secret the edges'
   `ca-bundle` is now copied from — then `helm upgrade` **with
   `--namespace ais-mgmt`**, for the reason given in step 6. Confirm
   `clusterissuer/ais-edge-ca` is READY again.
4. Re-issue the leaf certificates, so nothing is still serving a chain that
   ends at the retired intermediate. Either `cmctl renew --all` in each
   namespace, or delete the leaf Secrets and let cert-manager re-create them.
   Verify with the `grep -c "BEGIN CERTIFICATE"` check above.
5. Put the root key back. Delete the old intermediate Secret only after every
   leaf has been re-issued and verified.

Certificates issued by the old intermediate keep validating until they expire,
because both intermediates chain to the same root — which is why this can be
done without a maintenance window, and why step 4 is a tidy-up rather than a
race.

## When the root expires

It does not rotate cheaply; that is the trade. A new root is a new trust
anchor, so every edge needs a bundle containing **both** roots before the old
one expires. That is the fleet-wide two-phase redistribution
`scripts/rotate-ca.sh` was written for — and it is exactly what this design is
trying to make rare rather than impossible. Plan it with a year of overlap,
distribute the two-root bundle, and only then start issuing from an
intermediate under the new one.

CAUTION — `rotate-ca.sh` is not currently usable against this chart, in either
mode. Its names predate the chart and no longer match what renders: it
re-points a ClusterIssuer called `ais-edge-ca-issuer` and signs the successor
root from a ClusterIssuer called `selfsigned-bootstrap`, while the chart
renders `ais-edge-ca` (from `certManager.issuer`) and
`<release>-selfsigned-bootstrap` (from `certManager.ca.bootstrapIssuerName`,
defaulting to `mgmt-selfsigned-bootstrap` with the installer's default release
name). Both chart names are values, so a brownfield cluster adopted from the
pre-chart installer may still carry the script's names — which is exactly why
this has to be checked rather than assumed. Its phase-2 re-issue loop also selects
Certificates by `spec.issuerRef.name == "ais-edge-ca-issuer"`, which matches
none of them. Treat the script as the *procedure* — two phases, a grace period,
a both-roots bundle, then retirement — and check the names against
`kubectl get clusterissuer` before running any of it.

---

## Known gaps

Recorded rather than implied away.

* **This has not been run against a live cluster in `intermediate` mode.**
  Everything above renders, and the openssl half was executed and its output
  checked; the cert-manager half — chain construction in issued Secrets in
  particular — is unverified. See the verification section.
* **There is no longer a CA bootstrap script to assume `selfSigned`.**
  `scripts/02b-bootstrap-ca.sh` was deleted: `install.sh` says outright that
  "Steps 4 and 7 replace what used to be scripts 02b/02c/02d/03/04/07/07b/07c".
  CA bootstrap is now the chart itself (`templates/cert-issuers.yaml` renders
  the bootstrap `ClusterIssuer` and the `ais-edge-ca` `Certificate` in
  `selfSigned` mode, and neither in `intermediate` mode), plus the one-shot
  cert-sync seeding `install.sh` performs per edge after step 7 — it runs the
  edge's cert-sync CronJob immediately with `create job --from=cronjob`, so the
  site is not waiting up to six hours for its `ca-bundle`. What the old script's
  assumption has become is the gap recorded in **step 6b**: the CA distribution
  path still names `ais-edge-ca-secret`, which `intermediate` mode never
  creates, and you must re-point it by hand. The bundle edges need is still
  `ais-edge-root-ca.crt` from step 1 — the same bytes as `ca.crt` in the
  ceremony Secret.
* **A stale reference to that script survives in the chart.** The naming
  rationale block in `charts/mgmt/templates/cert-issuers.yaml` still explains
  the fixed `ais-edge-ca` Certificate name by citing
  `scripts/02b-bootstrap-ca.sh`. The name is still fixed and still load-bearing
  — `rotate-ca.sh` and the operator runbook depend on it — but the script it
  cites as the reason is gone. Recorded here so nobody goes looking for it.
* **`scripts/rotate-ca.sh` rotates the root**, not the intermediate. In
  `intermediate` mode the routine operation is "Rotating the intermediate"
  above, and `rotate-ca.sh` is only for the root-expiry case — where its
  hardcoded issuer names no longer match what the chart renders. See the
  caution under "When the root expires".
* **Nothing enforces the Secret's contents at render time.** A Secret with a
  leaf certificate instead of a CA, or with `ca.crt` missing, renders exactly
  the same and fails at runtime as a NotReady issuer.
