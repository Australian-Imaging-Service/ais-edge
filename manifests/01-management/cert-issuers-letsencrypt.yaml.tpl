# =============================================================================
# Let's Encrypt ClusterIssuers (cloud topology, real public DNS)
# =============================================================================
# Two ClusterIssuers:
#   1. letsencrypt-staging — Let's Encrypt's staging environment. Certs are
#                            signed by a fake intermediate (untrusted by
#                            browsers). Useful for end-to-end DNS-01 testing
#                            without burning the real-world rate limits.
#   2. letsencrypt-prod    — Let's Encrypt production. Real CA, trusted by
#                            every modern client out of the box.
#
# Both use the DNS-01 challenge because we run SSL passthrough at the
# ingress — HTTP-01 challenges can't terminate at the controller. DNS-01
# also works for wildcard certificates.
#
# This template is only applied when CERT_ISSUER=letsencrypt-* in the
# operator's config. It's rendered by 02b-bootstrap-ca.sh which substitutes
# the DNS-provider-specific solver block via {{DNS01_SOLVER_BLOCK}}.
# =============================================================================
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    email: {{ACME_EMAIL}}
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging-account
    solvers:
      - dns01:
{{DNS01_SOLVER_BLOCK}}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: {{ACME_EMAIL}}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
      - dns01:
{{DNS01_SOLVER_BLOCK}}
