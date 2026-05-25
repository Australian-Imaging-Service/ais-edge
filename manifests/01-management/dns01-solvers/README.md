# DNS-01 solver stubs for cert-manager Let's Encrypt ClusterIssuers

Each file in this directory is a YAML fragment that defines the
`solvers[*].dns01` body. `02b-bootstrap-ca.sh` reads the file matching
`DNS_PROVIDER=<name>` and splices it into
`cert-issuers-letsencrypt.yaml.tpl`.

Add the provider you need by dropping a file here. The fragment must be
valid YAML and properly indented for a `solvers[*].dns01` block — the
script adds 10 leading spaces to each line so the fragment itself should
start unindented.

## Examples

### `cloudflare.yaml`
```yaml
cloudflare:
  email: noreply@example.com
  apiTokenSecretRef:
    name: cloudflare-api-token
    key: api-token
```
Plus a Secret in the same namespace as the ClusterIssuer:
```bash
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token='<your token>'
```

### `route53.yaml`
```yaml
route53:
  region: ap-southeast-2
  hostedZoneID: ZXXXXXXXXXXXXX
  accessKeyIDSecretRef:
    name: route53-credentials
    key: access-key-id
  secretAccessKeySecretRef:
    name: route53-credentials
    key: secret-access-key
```

### `rfc2136.yaml` (e.g. self-hosted BIND)
```yaml
rfc2136:
  nameserver: ns1.example.com:53
  tsigKeyName: cert-manager.example.com.
  tsigAlgorithm: HMACSHA256
  tsigSecretSecretRef:
    name: rfc2136-tsig
    key: tsig-secret
```

## Why this is gated behind a directory rather than a chart
We don't depend on the cert-manager helm chart's webhook config — keeping
the issuer definition local lets us add a new DNS provider without
upgrading the chart. The cert-manager itself stays at the version the
operator originally installed.
