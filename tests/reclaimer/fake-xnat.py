#!/usr/bin/env python3
# A fake XNAT for the filesystem cases of run-tests.sh. Usage: fake-xnat.py <case dir>
#
# It answers from <case dir>/xnat.json, read again on each request:
#   experiments  {"<project>/<subject>": [rows]}     GET .../subjects/<s>/experiments
#   files        {"<experiment id>": [rows]}         GET .../experiments/<id>/scans/ALL/files
#   head         {"<uri>": {"status", "length", "no_length", "location"}}   overrides
#   on_head      {"<uri>": {"append": path} or {"create": path}}  writes during the proof
#   status       {"experiments" or "files": code}    a failing GET
# A HEAD of a listed URI answers 200 with the row's Size, unless overridden. Any
# other request answers 404. Each request goes to <case dir>/xnat-requests.log.
# As XNAT does, a request that logs in (Basic auth) opens a NEW session and gets a
# JSESSIONID cookie; DELETE /data/JSESSION ends it. Both go to the log as
# SESSION-OPENED / SESSION-CLOSED, so a case can count them. The token in
# <case dir>/xnat-shared-session (the shell's login, through stub-curl) is accepted
# as an open session: the helper borrows it, and must not close it.
import base64
import http.server
import itertools
import json
import os
import sys
import urllib.parse

CASE = sys.argv[1]
GOOD_AUTH = "Basic " + base64.b64encode(b"u:p").decode()
SESSIONS, NEXT = set(), itertools.count(1)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"   # the client keeps one connection

    def log_message(self, *args):
        pass

    def answer(self, status, body=b"", length=None, headers=()):
        self.send_response(status)
        if getattr(self, "new_session", None):
            self.send_header("Set-Cookie", f"JSESSIONID={self.new_session}; Path=/; HttpOnly")
        for k, v in headers:
            self.send_header(k, v)
        if length is not False:
            self.send_header("Content-Length", str(len(body) if length is None else length))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def handle_any(self):
        log = open(os.path.join(CASE, "xnat-requests.log"), "a")
        log.write(f"{self.command} {self.path}\n")
        with open(os.path.join(CASE, "xnat.json")) as f:
            fx = json.load(f)
        self.new_session = None
        cookie = self.headers.get("Cookie", "").split("JSESSIONID=")[-1].split(";")[0] if "JSESSIONID=" in self.headers.get("Cookie", "") else ""
        shared = ""   # the session the shell opened through stub-curl: the helper may borrow it
        try:
            with open(os.path.join(CASE, "xnat-shared-session")) as f:
                shared = f.read().strip()
        except FileNotFoundError:
            pass
        if self.headers.get("Authorization") == GOOD_AUTH:
            self.new_session = f"S{next(NEXT)}"
            SESSIONS.add(self.new_session)
            log.write(f"SESSION-OPENED {self.new_session}\n")
        elif cookie not in SESSIONS and not (cookie and cookie == shared):
            log.close()
            return self.answer(401, b"<html>401</html>")
        if self.command == "DELETE" and self.path.split("?")[0] == "/data/JSESSION":
            SESSIONS.discard(cookie)
            log.write(f"SESSION-CLOSED {cookie}\n")
            log.close()
            return self.answer(200)
        log.close()
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        parts = path.strip("/").split("/")
        # The shell's own calls, with the real curl: the login answers the new
        # session id; the pre-flight probe answers an empty project list.
        if self.command == "GET" and path == "/data/JSESSION":
            return self.answer(200, (self.new_session or cookie).encode())
        if self.command == "GET" and path == "/data/projects":
            code = fx.get("status", {}).get("projects", 200)
            return self.answer(code, json.dumps({"ResultSet": {"Result": []}}).encode())
        if self.command == "GET" and parts[-1] == "experiments" and len(parts) == 6:
            code = fx.get("status", {}).get("experiments", 200)
            rows = fx.get("experiments", {}).get(f"{parts[2]}/{parts[4]}", [])
            return self.answer(code, json.dumps({"ResultSet": {"Result": rows}}).encode())
        if self.command == "GET" and len(parts) == 3 and parts[:2] == ["data", "experiments"]:
            exists = any(r.get("ID") == parts[2] for rows in fx.get("experiments", {}).values() for r in rows)
            code = fx.get("status", {}).get("experiment", 200 if exists else 404)
            return self.answer(code, json.dumps({"items": [{"data_fields": {"ID": parts[2]}}]}).encode())
        if self.command == "GET" and path.endswith("/scans/ALL/files"):
            code = fx.get("status", {}).get("files", 200)
            rows = fx.get("files", {}).get(parts[2], [])
            return self.answer(code, json.dumps({"ResultSet": {"Result": rows}}).encode())
        if self.command == "HEAD":
            hook = fx.get("on_head", {}).get(path, {})
            if "append" in hook:
                with open(hook["append"], "ab") as f:
                    f.write(b"x")
            if "create" in hook:
                open(hook["create"], "w").close()
            listed = {urllib.parse.unquote(r["URI"]): int(r["Size"])
                      for rows in fx.get("files", {}).values() for r in rows}
            o = fx.get("head", {}).get(path, {})
            status = o.get("status", 200 if path in listed else 404)
            length = False if o.get("no_length") else o.get("length", listed.get(path, 0))
            loc = [("Location", o["location"])] if "location" in o else []
            return self.answer(status, length=length, headers=loc)
        return self.answer(404)

    do_GET = do_HEAD = do_PUT = do_POST = do_DELETE = handle_any


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(CASE, "xnat-port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
