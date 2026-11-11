#!/usr/bin/env python3
"""List the Secrets that a rendered chart needs but does not create.

Reads `helm template` output on stdin. Prints one `<namespace>/<name>` per
line: every Secret that a workload, an Alertmanager or a Prometheus resource
of the render refers to, minus the Secrets that the render itself creates
(as a manifest, or through a Helm hook Job such as kube-webhook-certgen).
An `optional: true` reference is left out, because the pod starts without it.

install.sh uses it when a site has no secrets.enc.yaml: the install may then
go on only if each listed Secret is already in the cluster.
"""
import sys

import yaml


def pod_specs(doc):
    kind, spec = doc.get("kind"), doc.get("spec") or {}
    if kind == "Pod":
        return [spec]
    if kind in ("Deployment", "DaemonSet", "StatefulSet", "ReplicaSet", "Job"):
        return [(spec.get("template") or {}).get("spec") or {}]
    if kind == "CronJob":
        job = (spec.get("jobTemplate") or {}).get("spec") or {}
        return [(job.get("template") or {}).get("spec") or {}]
    return []


def main():
    default_ns = sys.argv[1] if len(sys.argv) > 1 else "default"
    created, needed = set(), set()
    for doc in yaml.safe_load_all(sys.stdin):
        if not isinstance(doc, dict):
            continue
        ns = (doc.get("metadata") or {}).get("namespace") or default_ns
        kind = doc.get("kind")
        if kind == "Secret":
            created.add(f"{ns}/{doc['metadata']['name']}")
            continue
        # A Helm hook Job can create a Secret at install time: the
        # kube-prometheus-stack webhook certificate (kube-webhook-certgen,
        # --secret-name=<name>) is made this way before the operator starts.
        hook = ((doc.get("metadata") or {}).get("annotations") or {}).get("helm.sh/hook")
        if kind == "Job" and hook:
            for ps in pod_specs(doc):
                for c in ps.get("containers") or []:
                    args = [str(a) for a in (c.get("args") or [])]
                    for i, a in enumerate(args):
                        if a.startswith("--secret-name="):
                            created.add(f"{ns}/{a.split('=', 1)[1]}")
                        elif a == "--secret-name" and i + 1 < len(args):
                            created.add(f"{ns}/{args[i + 1]}")
        for ps in pod_specs(doc):
            for ref in ps.get("imagePullSecrets") or []:
                needed.add(f"{ns}/{ref['name']}")
            for vol in ps.get("volumes") or []:
                sec = vol.get("secret")
                if sec and not sec.get("optional"):
                    needed.add(f"{ns}/{sec['secretName']}")
                for src in (vol.get("projected") or {}).get("sources") or []:
                    sec = src.get("secret")
                    if sec and not sec.get("optional"):
                        needed.add(f"{ns}/{sec['name']}")
            for c in (ps.get("containers") or []) + (ps.get("initContainers") or []):
                for env in c.get("env") or []:
                    ref = (env.get("valueFrom") or {}).get("secretKeyRef")
                    if ref and not ref.get("optional"):
                        needed.add(f"{ns}/{ref['name']}")
                for env in c.get("envFrom") or []:
                    ref = env.get("secretRef")
                    if ref and not ref.get("optional"):
                        needed.add(f"{ns}/{ref['name']}")
        if kind in ("Alertmanager", "Prometheus"):
            spec = doc.get("spec") or {}
            for name in spec.get("secrets") or []:
                needed.add(f"{ns}/{name}")
            if spec.get("configSecret"):
                needed.add(f"{ns}/{spec['configSecret']}")
    for ref in sorted(needed - created):
        print(ref)


if __name__ == "__main__":
    main()
