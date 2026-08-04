#!/usr/bin/env python3
# =============================================================================
# bg-backup integration rig - a throwaway HTTP receiver for the notifiers
# =============================================================================
# The notification channels were the largest untested surface in the tool: the
# unit suite proved only that each provider FILE loads, never that a delivery
# leaves the host. A backup that fails silently because its webhook was dead is
# precisely the scenario bg-backup exists to prevent, so "the notifier loads" is
# not a useful thing to know.
#
# This records every request it receives and serves the recording back at
# /_requests, one JSON object per line. Reading the log over HTTP rather than
# through a shared volume keeps the victim container free of any mount, and
# removes a whole class of ordering and permission problems from the assertions.
#
# DELIBERATELY DUMB. It answers 200 to everything except /_requests and
# /_reset, because the point is to observe what bg-backup sends, not to
# simulate Teams or Uptime Kuma. A sink that validated payloads would start
# failing for reasons that have nothing to do with the tool under test.
# =============================================================================

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

REQUESTS = []


class Sink(BaseHTTPRequestHandler):
    # The default logger writes a line to stderr per request, which buries the
    # suite's own output in the compose log.
    def log_message(self, fmt, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _record(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        REQUESTS.append(
            {
                "method": self.command,
                "path": parsed.path,
                "query": parsed.query,
                # Header names are normalised to lower case: curl and the
                # providers are not consistent about capitalisation, and an
                # assertion should not depend on which one wrote the request.
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": raw.decode("utf-8", "replace"),
            }
        )

    def _dispatch(self):
        parsed = urlparse(self.path)
        if parsed.path == "/_requests":
            # One JSON object per line - greppable from the suite with jq, and
            # readable without it.
            body = ("\n".join(json.dumps(r) for r in REQUESTS) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/_reset":
            REQUESTS.clear()
            self._json(200, {"ok": True, "reset": True})
            return
        self._record()
        self._json(200, {"ok": True})

    do_GET = _dispatch
    do_POST = _dispatch
    do_PUT = _dispatch
    do_HEAD = _dispatch


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    HTTPServer(("", port), Sink).serve_forever()
