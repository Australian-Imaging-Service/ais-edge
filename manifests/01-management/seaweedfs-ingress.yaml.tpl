# =============================================================================
# Phase 2 — SeaweedFS S3 Ingress (TLS termination at nginx)
# =============================================================================
# Edges connect to https://{{SEAWEEDFS_HOSTNAME}}:443.
# nginx-ingress terminates TLS using the seaweedfs-tls Secret (signed by
# ais-edge-ca), then forwards plain HTTP to the SeaweedFS pod on port 8333
# (in-cluster, never leaves the node).
#
# Why TLS termination (not ssl-passthrough):
#   - Edge ↔ mgmt link is the part that crosses public internet — that's the
#     leg we need to encrypt. nginx → seaweedfs is in-cluster.
#   - Lets us keep the existing HTTP NodePort path alive in parallel during
#     migration (M4 → M6) without dual-listener complexity.
#   - For k0s API + konnectivity (M5) we DO use ssl-passthrough because those
#     protocols use mTLS that nginx cannot terminate.
#
# Body size + timeouts matter for large DICOM uploads (already set globally
# in the nginx-ingress controller config; per-Ingress overrides here for safety).
# =============================================================================
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: seaweedfs
  namespace: seaweedfs
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50g"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    # Allow chunked uploads (mc multipart)
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - {{SEAWEEDFS_HOSTNAME}}
      secretName: seaweedfs-tls
  rules:
    - host: {{SEAWEEDFS_HOSTNAME}}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: seaweedfs
                port:
                  number: 8333
