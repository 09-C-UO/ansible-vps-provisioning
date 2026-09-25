"""Stand-in for Discord in the lab: records every webhook call as a JSON line.

Usage: python3 webhook_sink.py <bind-address> <port> <log-file>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Sink(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - http.server naming
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(sys.argv[3], "a", encoding="utf-8") as log:
            log.write(json.dumps({"channel": self.path.strip("/"),
                                  "content": json.loads(body).get("content", "")},
                               ensure_ascii=False) + "\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


HTTPServer((sys.argv[1], int(sys.argv[2])), Sink).serve_forever()
