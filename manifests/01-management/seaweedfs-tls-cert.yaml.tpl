# =============================================================================
# SeaweedFS server certificate
# =============================================================================
# Issuer selected by CERT_ISSUER (see config/management.env). Defaults to
# ais-edge-ca (self-signed root from 02b). Renewed automatically by
# cert-manager 30 days before expiry.
#
# Used by the nginx Ingress (TLS passthrough). Edge clients verify this
# cert against the bundled ais-edge-ca.crt (or trust LE roots when
# CERT_ISSUER=letsencrypt-*).
#
# IP SANs (ipAddresses) are emitted only in onprem topology where /etc/
# hosts maps the hostname to MGMT_NODE_IP. In cloud topology pure DNS is
# used and IP SANs add nothing; Let's Encrypt doesn't issue them anyway.
# =============================================================================
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: seaweedfs-tls
  namespace: seaweedfs
spec:
  secretName: seaweedfs-tls
  duration: 8760h         # 1 year
  renewBefore: 720h       # auto-renew 30 days before expiry
  privateKey:
    algorithm: RSA
    size: 2048
  dnsNames:
    - {{SEAWEEDFS_HOSTNAME}}
  {{#ONPREM_ONLY}}
  ipAddresses:
    - {{MGMT_NODE_IP}}
  {{/ONPREM_ONLY}}
  issuerRef:
    name: {{CERT_ISSUER}}
    kind: ClusterIssuer
    group: cert-manager.io
