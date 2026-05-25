apiVersion: v1
kind: Namespace
metadata:
  name: xnat-upload
---
apiVersion: v1
kind: Secret
metadata:
  name: xnat-credentials
  namespace: xnat-upload
type: Opaque
stringData:
  server: "{{XNAT_URL}}"
  username: "{{XNAT_USER}}"
  password: "{{XNAT_PASS}}"
---
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: xnat-upload
type: Opaque
stringData:
  access-key: "{{S3_ADMIN_ACCESS_KEY}}"
  secret-key: "{{S3_ADMIN_SECRET_KEY}}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xnat-ingest-upload
  namespace: xnat-upload
  labels:
    app: xnat-ingest
    component: upload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: xnat-ingest
      component: upload
  template:
    metadata:
      labels:
        app: xnat-ingest
        component: upload
    spec:
      containers:
        - name: upload
          # Default points at our fork on ghcr.io with the AIS_LOG_FORMAT=json
          # patch. Override XNAT_INGEST_IMAGE
          # in config/management.env when upstream merges to switch back to
          # ghcr.io/australian-imaging-service/xnat-ingest:latest.
          image: {{XNAT_INGEST_IMAGE}}
          # Pre-flight probe: detect XNAT servers that redirect https→http
          # and refuse to start rather than silently downgrade credentials
          # to plain HTTP.
          #
          # The python xnat client follows 30x redirects, including across
          # schemes. When XNAT (or a fronting proxy) is misconfigured to
          # answer https with `302 Location: http://...`, the client logs
          # only a warning and continues over plain HTTP — leaking
          # admin creds in cleartext. We caught this on a dev cluster
          # where the misconfigured XNAT was accepting auth over both
          # schemes; production XNATs may reject HTTP entirely, giving
          # a confusing 401 instead.
          #
          # The probe is a single curl that follows redirects with
          # `--proto-default https` and `--proto-redir =https` — any
          # downgrade is reported with `curl: (60)` (cannot speak http
          # after https start) and we exit non-zero so K8s loops the pod
          # until the XNAT server is fixed. Set XNAT_ALLOW_INSECURE_REDIRECT=1
          # in the env to bypass this guard for known-misconfigured dev
          # XNATs — this LOWERS security, only use in dev/test.
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              if [ "${XNAT_ALLOW_INSECURE_REDIRECT:-0}" != "1" ]; then
                # Probe the BASE URL **without** basic auth — that's how
                # the python xnat client probes XNAT during connect(). On
                # a misconfigured XNAT the unauthenticated GET / returns
                # a 302 with Location: http://... (anonymous user gets
                # bounced to the login page on plain HTTP). The xnat
                # client then permanently switches its session._server to
                # http and sends admin credentials in cleartext for every
                # subsequent call.
                #
                # An authenticated probe would mask this — XNAT returns
                # 200 directly when auth is present, never emitting the
                # redirect. So this probe deliberately omits -u.
                case "${XINGEST_HOST}" in
                  https://*)
                    base="${XINGEST_HOST%/}"
                    # Single hop, no auth. We only care about the first
                    # redirect target.
                    loc=$(curl -sk -I --max-redirs 0 "${base}/" 2>/dev/null \
                            | sed -n 's/^[Ll]ocation:[[:space:]]*//p' \
                            | tr -d '\r' | head -1)
                    case "$loc" in
                      http://*)
                        echo "FATAL: XNAT downgrades HTTPS to HTTP on unauthenticated requests." >&2
                        echo "       Probe: GET ${base}/ (no auth)" >&2
                        echo "       Response: 302 Location: $loc" >&2
                        echo "" >&2
                        echo "       The python xnat client probes the base URL without auth" >&2
                        echo "       during connect(), follows this redirect, and adopts http" >&2
                        echo "       for the session — sending admin credentials in cleartext" >&2
                        echo "       on every subsequent call." >&2
                        echo "" >&2
                        echo "       Fix the XNAT server's TLS / proxy configuration:" >&2
                        echo "         * Tomcat connector must declare scheme=\"https\"," >&2
                        echo "           secure=\"true\", and proxyName matching the public hostname" >&2
                        echo "           when sitting behind a TLS-terminating reverse proxy" >&2
                        echo "         * Reverse proxy (nginx/Apache) must send" >&2
                        echo "           X-Forwarded-Proto: https AND Tomcat must trust it" >&2
                        echo "           (RemoteIpValve / RemoteIpFilter)" >&2
                        echo "         * Remove any rewrite/redirect rule pointing http://" >&2
                        echo "" >&2
                        echo "       To bypass for dev/test (LEAKS ADMIN CREDS OVER CLEAR HTTP)," >&2
                        echo "       set XNAT_ALLOW_INSECURE_REDIRECT=1 in management.env." >&2
                        exit 1
                        ;;
                    esac
                    ;;
                esac
              fi
              # Hand off to the actual upload command.
              exec xnat-ingest upload \
                "s3://{{S3_BUCKET}}/staged" \
                "${XINGEST_HOST}" \
                --always-include all \
                --loop 60 \
                --dont-require-manifest \
                --dont-verify-ssl \
                --store-credentials \
                "${S3_ACCESS_KEY}" \
                "${S3_SECRET_KEY}"
          env:
            - name: XINGEST_HOST
              valueFrom:
                secretKeyRef:
                  name: xnat-credentials
                  key: server
            - name: XINGEST_USER
              valueFrom:
                secretKeyRef:
                  name: xnat-credentials
                  key: username
            - name: XINGEST_PASS
              valueFrom:
                secretKeyRef:
                  name: xnat-credentials
                  key: password
            - name: S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-credentials
                  key: access-key
            - name: S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: s3-credentials
                  key: secret-key
            # Point boto3 at the in-cluster SeaweedFS service
            - name: AWS_ENDPOINT_URL
              value: "http://seaweedfs.seaweedfs.svc.cluster.local:8333"
            - name: AWS_DEFAULT_REGION
              value: "us-east-1"
            # Emit one JSON object per log line so Vector indexes
            # ts/level/logger/message without regex parsing.
            - name: AIS_LOG_FORMAT
              value: "json"
            # Set to "1" to skip the https→http downgrade guard. ONLY for
            # dev/test against a misconfigured XNAT — leaks admin creds
            # over cleartext. Default (empty) keeps the guard armed.
            - name: XNAT_ALLOW_INSECURE_REDIRECT
              value: "{{XNAT_ALLOW_INSECURE_REDIRECT}}"
