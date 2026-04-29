# =============================================================================
# nginx Ingresses for Grafana + Loki  —  share the existing :443 listener
# =============================================================================
# These add two more SNI routes to the nginx-ingress controller already
# bound to *:443 on the management host. No new firewall ports.
#
# - grafana.aisedge.local  → svc/kube-prometheus-stack-grafana:80  (TLS terminate)
#       Operator browser access to dashboards. Self-signed cert via cert-manager.
# - loki.aisedge.local     → svc/loki-gateway:80                    (TLS terminate)
#       Vector pods on edges push log batches here. Bearer-auth at Loki.
# =============================================================================
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: observability
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - {{GRAFANA_HOSTNAME}}
      secretName: grafana-tls
  rules:
    - host: {{GRAFANA_HOSTNAME}}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-grafana
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: loki
  namespace: observability
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - {{LOKI_HOSTNAME}}
      secretName: loki-tls
  rules:
    - host: {{LOKI_HOSTNAME}}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: loki
                port:
                  number: 3100
