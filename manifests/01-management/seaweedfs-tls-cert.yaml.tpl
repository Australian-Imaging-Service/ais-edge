# =============================================================================
# Phase 2 — SeaweedFS server certificate
# =============================================================================
# Issued by ais-edge-ca-issuer (the CA we created in step 02b).
# Renewed automatically by cert-manager 30 days before expiry.
#
# Used by the nginx Ingress (TLS termination). Edges verify this cert
# against the bundled ais-edge-ca.crt — that's the trust chain.
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
  ipAddresses:
    - {{MGMT_NODE_IP}}
  issuerRef:
    name: ais-edge-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
