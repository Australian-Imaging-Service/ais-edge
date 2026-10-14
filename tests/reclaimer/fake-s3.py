#!/usr/bin/env python3
# A fake S3 for the mgmt cases of run-tests.sh. Usage: fake-s3.py <case dir>
#
# It answers from <case dir>/s3.json, read again on each request:
#   objects   {"<key>": {"size": n, "etag": "<md5>", "modified": "<RFC 3339>", "body": "<text>"}}
#   status    {"list" | "get" | "delete": <HTTP code>}   a failing call
#   fail_delete {"<key>": <HTTP code>}                  one failing delete
#   page      <n>: list at most n keys per page (pagination)
#   after_list {"<key>": {object} or null}  applied ONCE, after the first listing
#             without a delimiter (the helper's snapshot of a session): an object
#             written or rewritten after the snapshot, or one removed (null),
#             before its GET, DELETE or the second listing
# ListObjectsV2 answers XML as S3 does; GetObject the body; DeleteObject needs an
# If-Match equal to the object's ETag (unquoted, as SeaweedFS 4.34 compares it),
# else 412, and removes the key from s3.json on 204. Every request goes to
# <case dir>/s3-requests.log as "<method> <key> [if-match=<value>]".
import http.server
import json
import os
import sys
import urllib.parse
from xml.sax.saxutils import escape

CASE = sys.argv[1]
FX = os.path.join(CASE, "s3.json")


def load():
    with open(FX) as f:
        return json.load(f)


def save(fx):
    with open(FX, "w") as f:
        json.dump(fx, f)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def answer(self, status, body=b"", ctype="application/xml", headers=()):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def error(self, status, code):
        self.answer(status, f'<?xml version="1.0"?><Error><Code>{code}</Code></Error>'.encode())

    def handle_any(self):
        fx = load()
        u = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(u.query)
        parts = urllib.parse.unquote(u.path).strip("/").split("/", 1)   # bucket, key
        key = parts[1] if len(parts) > 1 else ""
        ifm = self.headers.get("If-Match", "")
        with open(os.path.join(CASE, "s3-requests.log"), "a") as log:
            log.write(f"{self.command} {key}" + (f" if-match={ifm}" if ifm else "") + "\n")
        status = fx.get("status", {})
        if self.command == "GET" and not key:                      # ListObjectsV2
            if "list" in status:
                return self.error(status["list"], "InternalError")
            prefix = q.get("prefix", [""])[0]
            keys = sorted(k for k in fx.get("objects", {}) if k.startswith(prefix))
            delim = q.get("delimiter", [""])[0]
            common = ""
            if delim:
                # Keys under a sub-folder become one CommonPrefix each, as S3 does;
                # "folders" lists empty folder entries, which SeaweedFS shows too.
                heads = sorted({prefix + k[len(prefix):].split(delim, 1)[0] + delim for k in keys if delim in k[len(prefix):]}
                               | {f for f in fx.get("folders", []) if f.startswith(prefix)})
                keys = [k for k in keys if delim not in k[len(prefix):]]
                common = "".join(f"<CommonPrefixes><Prefix>{escape(h)}</Prefix></CommonPrefixes>" for h in heads)
            start = q.get("continuation-token", [""])[0]
            keys = [k for k in keys if k > start] if start else keys
            page = int(fx.get("page", 0) or 0)
            shown, more = (keys[:page], len(keys) > page) if page else (keys, False)
            items = common + "".join(
                f"<Contents><Key>{escape(k)}</Key><Size>{fx['objects'][k]['size']}</Size>"
                f"<ETag>&quot;{fx['objects'][k]['etag']}&quot;</ETag>"
                f"<LastModified>{fx['objects'][k]['modified']}</LastModified></Contents>" for k in shown)
            nxt = f"<NextContinuationToken>{escape(shown[-1])}</NextContinuationToken>" if more else ""
            body = (f'<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><Name>{escape(parts[0])}</Name>'
                    f"<Prefix>{escape(prefix)}</Prefix><KeyCount>{len(shown)}</KeyCount>"
                    f"<IsTruncated>{'true' if more else 'false'}</IsTruncated>{nxt}{items}</ListBucketResult>")
            if "after_list" in fx and not delim and not more:   # after the helper's own listing of the session
                for k, v in fx.pop("after_list").items():
                    if v is None:
                        fx["objects"].pop(k, None)
                    else:
                        fx["objects"][k] = v
                save(fx)
            return self.answer(200, body.encode())
        obj = fx.get("objects", {}).get(key)
        if self.command == "HEAD" and not key:                      # HeadBucket
            return self.answer(200)
        if self.command in ("GET", "HEAD"):
            if "get" in status:
                return self.error(status["get"], "InternalError")
            if obj is None:
                return self.error(404, "NoSuchKey")
            if ifm and ifm.strip('"') != obj["etag"]:
                return self.error(412, "PreconditionFailed")
            body = (obj.get("body") or "").encode()
            return self.answer(200, body, "application/octet-stream", [("ETag", f'"{obj["etag"]}"')])
        if self.command == "DELETE":
            if "delete" in status:
                return self.error(status["delete"], "InternalError")
            if key in fx.get("fail_delete", {}):
                return self.error(fx["fail_delete"][key], "InternalError")
            if obj is None:
                return self.answer(204)
            if ifm != obj["etag"]:
                return self.error(412, "PreconditionFailed")
            del fx["objects"][key]
            save(fx)
            return self.answer(204)
        return self.error(405, "MethodNotAllowed")

    do_GET = do_HEAD = do_DELETE = do_PUT = do_POST = handle_any


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(CASE, "s3-port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
