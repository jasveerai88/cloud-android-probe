#!/usr/bin/env python3
# PhoneVault live-view fallback (v4.4, Lane 1 design): slideshow + tap control.
# HONEST LABEL: this is NOT video. adb screencap costs ~0.7-3 s per frame, so
# expect roughly 0.3-1 fps: enough to see the phone's state and act on it
# deliberately, not to watch motion.
# Zero dependencies beyond the Python standard library + adb. Binds
# 127.0.0.1 only; authentication is the gate proxy's job (gate.js in front).
# Usage: fallback.py --port 8001 --serial emulator-5554
import argparse
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

SERIAL = "emulator-5554"
_lock = threading.Lock()
_frame = b""
_frame_ts = 0.0
_dev_w, _dev_h = 1080, 2400


def adb(*args, timeout=30):
    return subprocess.run(["adb", "-s", SERIAL, *args],
                          capture_output=True, timeout=timeout)


def capture_loop():
    global _frame, _frame_ts, _dev_w, _dev_h
    try:
        out = adb("shell", "wm", "size", timeout=15).stdout.decode("utf-8", "replace")
        for tok in out.replace(":", " ").split():
            if "x" in tok and tok.replace("x", "").isdigit():
                w, h = tok.split("x")
                _dev_w, _dev_h = int(w), int(h)
                break
    except Exception:
        pass
    while True:
        try:
            r = adb("exec-out", "screencap", "-p", timeout=30)
            if r.stdout and r.stdout.startswith(b"\x89PNG"):
                with _lock:
                    _frame = r.stdout
                    _frame_ts = time.time()
        except Exception:
            time.sleep(1)


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PhoneVault live (slideshow)</title>
<style>body{font-family:-apple-system,sans-serif;background:#111;color:#eee;margin:8px}
img{width:100%;max-width:480px;border:1px solid #444}
button{font-size:16px;padding:10px 14px;margin:4px}
input{font-size:16px;padding:10px;width:60%}</style></head><body>
<p>PhoneVault live view &mdash; slideshow (not video). Tap the picture to tap the phone.</p>
<img id="f" src="/frame.png" alt="phone screen">
<div>
<button onclick="key(3)">Home</button><button onclick="key(4)">Back</button>
<button onclick="key(187)">Recents</button><button onclick="key(26)">Power</button>
<button onclick="key(24)">Vol+</button><button onclick="key(25)">Vol-</button>
</div>
<div><input id="t" placeholder="text to type"><button onclick="sendText()">Type</button></div>
<p id="s"></p>
<script>
const img=document.getElementById('f');
setInterval(()=>{img.src='/frame.png?'+Date.now()},1500);
img.addEventListener('click',e=>{
  const r=img.getBoundingClientRect();
  const x=(e.clientX-r.left)/r.width, y=(e.clientY-r.top)/r.height;
  fetch('/tap',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:'x='+x+'&y='+y}).then(()=>{document.getElementById('s').textContent='tapped';});
});
function key(c){fetch('/key',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'code='+c});}
function sendText(){const v=document.getElementById('t').value;
  fetch('/text',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'text='+encodeURIComponent(v)});}
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/frame.png"):
            with _lock:
                f = _frame
            if f:
                self._send(200, f, "image/png")
            else:
                self._send(503, b"no frame yet")
        elif self.path == "/" or self.path.startswith("/?"):
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")
        else:
            self._send(404, b"")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        q = parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        try:
            if self.path == "/tap":
                x = float(q["x"][0]) * _dev_w
                y = float(q["y"][0]) * _dev_h
                adb("shell", "input", "tap", str(int(x)), str(int(y)), timeout=15)
            elif self.path == "/key":
                adb("shell", "input", "keyevent", str(int(q["code"][0])), timeout=15)
            elif self.path == "/text":
                t = q["text"][0].replace(" ", "%s")
                adb("shell", "input", "text", t, timeout=15)
            else:
                self._send(404, b"")
                return
            self._send(200, b"ok")
        except Exception as e:
            self._send(500, ("err: %s" % e).encode())


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8001)
    ap.add_argument("--serial", default="emulator-5554")
    a = ap.parse_args()
    SERIAL = a.serial
    threading.Thread(target=capture_loop, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()
