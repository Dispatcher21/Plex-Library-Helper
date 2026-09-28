# A stand-in for qBittorrent's Web UI API (only what the helper uses), for testing without touching the real one.
# GET /test/state shows what the helper did; POST /test/set?progress=1 finishes the first torrent.
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

S = {"turtle": 0, "toggles": 0, "alt": {"alt_dl_limit": 10240, "alt_up_limit": 10240}, "progress": 0.42}

def torrents():
    return [
        {"name": "Big.Buck.Bunny.2008.2160p", "hash": "a" * 40, "progress": S["progress"], "state": "downloading" if S["progress"] < 1 else "uploading",
         "dlspeed": 0 if S["progress"] >= 1 else 5_000_000, "upspeed": 250_000, "size": 12_000_000_000, "eta": 1300 if S["progress"] < 1 else 8640000, "ratio": 0.1, "added_on": 200},
        {"name": "Sintel.2010.1080p", "hash": "b" * 40, "progress": 1.0, "state": "stalledUP", "dlspeed": 0, "upspeed": 90_000, "size": 3_000_000_000, "eta": 8640000, "ratio": 1.7, "added_on": 100},
        {"name": "Tears.of.Steel.2012", "hash": "c" * 40, "progress": 0.1, "state": "stoppedDL", "dlspeed": 0, "upspeed": 0, "size": 5_000_000_000, "eta": 8640000, "ratio": 0, "added_on": 150},
    ]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = urlparse(self.path).path
        if p == "/api/v2/app/version": return self.send("v5.0.4", "text/plain")
        if p == "/api/v2/torrents/info": return self.send(json.dumps(torrents()))
        if p == "/api/v2/transfer/speedLimitsMode": return self.send(str(S["turtle"]), "text/plain")
        if p == "/api/v2/app/preferences": return self.send(json.dumps(S["alt"]))
        if p == "/test/state": return self.send(json.dumps(S))
        self.send_response(404); self.end_headers()
    def do_POST(self):
        u = urlparse(self.path); n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n).decode()
        if u.path.startswith("/api/") and not (self.headers.get("Referer") or self.headers.get("Origin")):
            self.send_response(401); self.end_headers(); return   # qBittorrent's CSRF check
        if u.path == "/api/v2/transfer/toggleSpeedLimitsMode": S["turtle"] ^= 1; S["toggles"] += 1; return self.send("", "text/plain")
        if u.path == "/api/v2/app/setPreferences": S["alt"].update(json.loads(parse_qs(body)["json"][0])); return self.send("", "text/plain")
        if u.path == "/test/set":
            q = parse_qs(u.query)
            if "progress" in q: S["progress"] = float(q["progress"][0])
            if "turtle" in q: S["turtle"] = int(q["turtle"][0])
            return self.send(json.dumps(S))
        self.send_response(404); self.end_headers()

HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 18080), H).serve_forever()
