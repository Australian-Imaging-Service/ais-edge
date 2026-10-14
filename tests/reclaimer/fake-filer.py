#!/usr/bin/env python3
# A fake SeaweedFS filer for the reclaimer's pre-flight gate. Usage: fake-filer.py <case dir>
#
# GET /buckets/?limit=N answers the JSON bucket listing from <case dir>/filer.json:
#   {"buckets": {"<bucket>": {"<attribute name>": "<value>"}}}
# Each attribute is base64 in "Extended", as the filer encodes it. Without the file,
# the bucket "ingest-edge-dev" carries both attributes the gate wants. Every request
# goes to <case dir>/filer-requests.log.
import base64
import http.server
import json
import os
import sys

CASE = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(os.path.join(CASE, "filer-requests.log"), "a") as log:
            log.write(f"GET {self.path}\n")
        buckets = {"ingest-edge-dev": {"Seaweed-X-Amz-Allow-Empty-Folders": "true",
                                       "Seaweed-X-Ais-Cleaner-Drained": "2026-10-14T00:00:00Z"}}
        try:
            with open(os.path.join(CASE, "filer.json")) as f:
                buckets = json.load(f).get("buckets", {})
        except FileNotFoundError:
            pass
        entries = [{"FullPath": "/buckets/" + name, "Mode": 2147484159,
                    "Extended": {k: base64.b64encode(v.encode()).decode() for k, v in attrs.items()} or None}
                   for name, attrs in buckets.items()]
        body = json.dumps({"Path": "/buckets", "Entries": entries, "Limit": 1000, "ShouldDisplayLoadMore": False}).encode()
        self.send_response(200 if self.path.startswith("/buckets/") else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(CASE, "filer-port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
