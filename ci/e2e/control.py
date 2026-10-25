"""Owns the e2e flextunnel servers a UI test may take down, and lets the test
runner stop and restart them over loopback HTTP: `POST /<name>/stop` and
`POST /<name>/start` (idempotent; each answers once the server has exited, or
has been started). `GET /health` answers 200 while every server runs.

    uv run --no-project python ci/e2e/control.py <port> <servers.json>

`servers.json` maps a name to {"argv": [...], "home": dir, "log": file}. Each
server runs with its own HOME (its lock and blocklist stay scratch files) and
appends to its log across restarts. SIGTERM stops every server, then exits.
"""

import json
import os
import signal
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
with open(sys.argv[2]) as f:
    specs = json.load(f)

procs = {}
lock = threading.Lock()


def start(name):
    proc = procs.get(name)
    if proc is not None and proc.poll() is None:
        return
    spec = specs[name]
    log = open(spec["log"], "a")
    procs[name] = subprocess.Popen(
        spec["argv"],
        env={**os.environ, "HOME": spec["home"]},
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    log.close()


def stop(name):
    proc = procs.get(name)
    if proc is None or proc.poll() is not None:
        return
    # SIGTERM: the server closes its endpoint, so the client sees the
    # connection go at once rather than after the QUIC idle timeout.
    proc.terminate()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            return self.reply(404, "no such path")
        with lock:
            dead = [n for n, p in procs.items() if p.poll() is not None]
        if dead:
            return self.reply(503, "exited: " + ", ".join(dead))
        self.reply(200, "ok")

    def do_POST(self):
        parts = self.path.strip("/").split("/")
        if len(parts) != 2 or parts[0] not in specs or parts[1] not in ("start", "stop"):
            return self.reply(404, "no such server or action")
        name, action = parts
        with lock:
            (start if action == "start" else stop)(name)
        print(f"[control] {action} {name}", flush=True)
        self.reply(200, "ok")

    def reply(self, status, text):
        body = (text + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def shutdown(*_):
    with lock:
        for name in procs:
            stop(name)
    os._exit(0)


signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)
with lock:
    for name in specs:
        start(name)
ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
