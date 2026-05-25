# =============================================================================
# Phase 3 — nginx-ingress controller helm values (CLOUD topology)
# =============================================================================
# Used when INSTALL_TOPOLOGY=cloud. The controller runs as a normal Deployment
# (no hostNetwork) and is exposed via Service type: LoadBalancer. The cloud
# provider's CCM (Octavia on OpenStack / NLB on AWS / Azure LB / GCP LB)
# provisions an actual L4 load balancer and assigns it the pre-allocated
# floating IP from LB_PUBLIC_IP.
#
# SSL passthrough is still enabled so each backend keeps its own TLS context
# and SNI routing happens at the L4 LB → controller Service hop.
#
# Why no hostNetwork on cloud:
#   * Managed K8s (EKS/AKS/GKE/Magnum) does not let you bind hostNetwork on
#     cluster nodes for inbound traffic. The accepted pattern is LB → Service.
#   * Multiple replicas can run side-by-side; the LB load-balances across them.
#
# Why LoadBalancerIP:
#   * Lets us pre-allocate the public IP and set the DNS records before
#     install (chicken-and-egg avoided). The OpenStack CCM honours this and
#     attaches the existing floating IP to the LB it provisions.
#
# Why externalTrafficPolicy: Cluster (default):
#   * Source IP is rewritten — but for our use (SNI passthrough to TLS-aware
#     backends) we don't need the client IP at the controller. Cluster gives
#     better LB → backend connection reuse and works with multi-node clusters.
# =============================================================================
controller:
  replicaCount: 2                                # can scale; LB load-balances
  hostNetwork: false
  dnsPolicy: ClusterFirst
  ingressClassResource:
    name: nginx
    enabled: true
    default: true
  service:
    type: LoadBalancer
{{#LB_PUBLIC_IP}}    loadBalancerIP: "{{LB_PUBLIC_IP}}"           # pre-allocated public IP / FIP
{{/LB_PUBLIC_IP}}    # OpenStack/Octavia hints — harmless on other providers but help the
    # OpenStack CCM associate the existing floating IP correctly.
    # On Nectar QLD topology (where the LB is on the external network),
    # leave LB_PUBLIC_IP blank; Octavia auto-assigns a usable public IP.
    annotations:
      # AWS NLB hint (also harmless on non-AWS):
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
  extraArgs:
    enable-ssl-passthrough: "true"
  config:
    proxy-body-size: "50g"
    proxy-read-timeout: "3600"
    proxy-send-timeout: "3600"
    use-forwarded-headers: "true"
  tolerations:
    - operator: Exists
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 1
      memory: 512Mi
