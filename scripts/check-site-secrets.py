#!/usr/bin/env python3
"""Cross-check a site's DECRYPTED secrets against its values.yaml.

Reads the decrypted secret documents on stdin (so plaintext never touches
disk) and the site values path as argv[1]. Prints one line per problem and
exits 0 regardless -- the caller decides what to do with the output.

Catches the two classes install.sh's REPLACE_ guard cannot see, both of which
otherwise cost a full install to discover:

1. edges[].s3SecretRef naming a Secret that does not exist. Renaming the edge
   in a scaffolded site without renaming its Secret is the obvious way in.
   Nothing complains until SeaweedFS has sat in Init:0/1 for nine minutes and
   `helm --wait` gives up with "timed out waiting for the condition" -- the
   real cause being a MountVolume event on a pod nobody thought to describe.

2. Shipped EXAMPLE values that are not REPLACE_ placeholders and so survive
   every guard. xnat-credentials ships `server: https://xnat.example.org`; an
   operator who fills in the username and password but never touches the
   server installs cleanly, and the uploader then CrashLoops on a DNS error.
"""
import sys, yaml

EXAMPLE_MARKERS = ("example.org", "example.com", "example.net", "changeme")


def main() -> int:
    docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
    site = yaml.safe_load(open(sys.argv[1])) or {}
    names = {(d.get("metadata") or {}).get("name") for d in docs}
    names.discard(None)
    problems = []

    for edge in site.get("edges") or []:
        ref = edge.get("s3SecretRef")
        if ref and ref not in names:
            problems.append(
                f"  edge {edge.get('name')}: s3SecretRef '{ref}' names no Secret in "
                f"this site. Present: {', '.join(sorted(names))}")

    for d in docs:
        name = (d.get("metadata") or {}).get("name")
        values = dict(d.get("stringData") or {})
        values.update(d.get("data") or {})
        for key, val in values.items():
            if isinstance(val, str) and any(m in val.lower() for m in EXAMPLE_MARKERS):
                problems.append(
                    f"  Secret {name}, key '{key}': still a shipped example value "
                    f"({val}) -- nothing will resolve it at runtime")

    print("\n".join(problems))
    return 0


if __name__ == "__main__":
    sys.exit(main())
