# =============================================================================
# Server certs for Grafana + Loki Ingresses
# =============================================================================
# Signed by whichever ClusterIssuer is selected via CERT_ISSUER:
#   ais-edge-ca                  — self-signed root, default
#   letsencrypt-prod / -staging  — Let's Encrypt via DNS-01 (cloud topology only)
#
# cert-manager auto-renews 30 days before expiry.
#
# IP SANs (ipAddresses) are emitted ONLY in onprem topology where edges
# resolve hostnames via /etc/hosts → MGMT_NODE_IP and tools like curl can
# verify the cert by IP. In cloud topology the cert is purely DNS-named —
# the load balancer fronts the IP and clients dial by hostname.
# Let's Encrypt does not issue IP SANs at all, so when CERT_ISSUER is
# letsencrypt-*, the IP-SAN block (gated on onprem topology below) is
# stripped by render_with_topology even though we're technically running
# in cloud mode.
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
  {{#ONPREM_ONLY}}
  ipAddresses:
    - {{MGMT_NODE_IP}}
  {{/ONPREM_ONLY}}
  issuerRef:
    name: {{CERT_ISSUER}}
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
  {{#ONPREM_ONLY}}
  ipAddresses:
    - {{MGMT_NODE_IP}}
  {{/ONPREM_ONLY}}
  issuerRef:
    name: {{CERT_ISSUER}}
    kind: ClusterIssuer
    group: cert-manager.io
