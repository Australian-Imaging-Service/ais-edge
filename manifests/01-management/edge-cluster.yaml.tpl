# =============================================================================
# k0smotron hosted cluster for an edge site
# =============================================================================
# Phase 2: spec.ingress is added so k0smotron auto-creates nginx Ingresses
# for the API server and konnectivity, both routed via SNI on port 443
# (with ssl-passthrough — k0s/konnectivity use mTLS that nginx must NOT
# decrypt, so we pass raw TLS through).
#
# spec.service (NodePort) is kept for parallel migration; remove in M7.
#
# spec.k0sConfig.spec.api.sans adds {{K0S_API_HOSTNAME}} as a SAN on the
# k0s API server certificate so worker nodes verifying via the new hostname
# don't fail TLS verification.
# =============================================================================
apiVersion: k0smotron.io/v1beta1
kind: Cluster
metadata:
  name: {{CLUSTER_NAME}}
  namespace: {{CLUSTER_NAME}}
spec:
  replicas: 1
  version: v1.35.2+k0s.0
  externalAddress: {{MGMT_NODE_IP}}
  # Phase 2: NodePort kept for in-cluster reachability of the kubernetes
  # Service (10.96.0.1:443) on the edge worker — kube-router, kube-proxy,
  # metrics-server use that path. Edges themselves use the Ingress URL
  # (https://{{K0S_API_HOSTNAME}}:443) via the rewritten join token, so
  # edge-firewall outbound is still single-port 443. The NodePort listener
  # is reachable on the management node but not used by edges directly.
  service:
    type: NodePort
    apiPort: 30443
    konnectivityPort: 30132
  ingress:
    deploy: true
    className: nginx
    apiHost: {{K0S_API_HOSTNAME}}
    konnectivityHost: {{KONNECTIVITY_HOSTNAME}}
    port: {{INGRESS_PORT}}
    annotations:
      nginx.ingress.kubernetes.io/ssl-passthrough: "true"
      nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
  persistence:
    type: emptyDir
  k0sConfig:
    apiVersion: k0s.k0sproject.io/v1beta1
    kind: ClusterConfig
    spec:
      api:
        sans:
          - {{K0S_API_HOSTNAME}}
          - {{KONNECTIVITY_HOSTNAME}}
          - {{MGMT_NODE_IP}}
