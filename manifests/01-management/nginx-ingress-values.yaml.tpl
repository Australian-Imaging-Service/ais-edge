# =============================================================================
# Phase 2 — nginx-ingress controller helm values
# =============================================================================
# Single-replica controller running with hostNetwork: true so it binds the
# management node's port 443 directly. SSL passthrough is enabled so we can
# route TLS traffic by SNI without terminating it (each backend keeps its
# own server cert: SeaweedFS, k0smotron API, konnectivity).
#
# Why hostNetwork:
#   - We want port 443 on the node, not a NodePort
#   - This is a single-node management cluster; only one nginx pod can bind
#     :443. Don't scale to >1 replica with hostNetwork.
#
# Why dnsPolicy: ClusterFirstWithHostNet:
#   - With hostNetwork, default dnsPolicy "ClusterFirst" gives us the host's
#     /etc/resolv.conf — but we still need to resolve in-cluster Service
#     names (like seaweedfs.seaweedfs.svc.cluster.local) for the upstreams.
#
# Why proxy-body-size: 50g:
#   - DICOM sessions can be large (>1GB). Default 1MB would block uploads.
# =============================================================================
controller:
  replicaCount: 1
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  ingressClassResource:
    name: nginx
    enabled: true
    default: true
  service:
    # Service is internal only; the host port is what edges connect to
    type: ClusterIP
  extraArgs:
    enable-ssl-passthrough: "true"
  config:
    proxy-body-size: "50g"
    proxy-read-timeout: "3600"
    proxy-send-timeout: "3600"
    use-forwarded-headers: "true"
  # Tolerate single-node taints if any exist
  tolerations:
    - operator: Exists
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 1
      memory: 512Mi
