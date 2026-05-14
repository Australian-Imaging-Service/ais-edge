# =============================================================================
# Server certs for Grafana + Loki Ingresses, signed by ais-edge-ca
# =============================================================================
# cert-manager auto-renews these 30 days before expiry. SANs cover the
# hostnames + the management node IP so curl --resolve works too.
# =============================================================================
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-tls
  namespace: observability
spec:
  secretName: grafana-tls
  duration: 8760h          # 1 year
  renewBefore: 720h        # auto-renew 30 days before expiry
  privateKey:
    algorithm: RSA
    size: 2048
  dnsNames:
    - {{GRAFANA_HOSTNAME}}
  ipAddresses:
    - {{MGMT_NODE_IP}}
  issuerRef:
    name: ais-edge-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: loki-tls
  namespace: observability
spec:
  secretName: loki-tls
  duration: 8760h
  renewBefore: 720h
  privateKey:
    algorithm: RSA
    size: 2048
  dnsNames:
    - {{LOKI_HOSTNAME}}
  ipAddresses:
    - {{MGMT_NODE_IP}}
  issuerRef:
    name: ais-edge-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
