apiVersion: k0smotron.io/v1beta1
kind: Cluster
metadata:
  name: {{CLUSTER_NAME}}
  namespace: {{CLUSTER_NAME}}
spec:
  replicas: 1
  version: v1.35.2+k0s.0
  service:
    type: NodePort
    apiPort: 30443
    konnectivityPort: 30132
  persistence:
    type: emptyDir
