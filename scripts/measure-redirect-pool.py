#!/usr/bin/env python3
"""Two-server rig that measures how apt behaves against a redirected pool.

Server A ("index"): serves this repository as static files, so ``dists/**`` and
``spectroscope.asc`` come from the signed tree unchanged. Every request whose
path starts with ``/pool/`` is answered with a 302 to server B instead of a
file. That is the shape the worker design proposes: signed indexes on Pages,
packages somewhere else.

Server B ("pool"): serves whatever file is currently staged as the package.
Swapping that file is how the hash-mismatch case gets measured. It speaks
Range requests, because a release asset host or an object store does.

Both servers append one JSON line per request to the log, including the
request headers, so a Range header or anything else apt sends is visible
afterwards rather than guessed at.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, SimpleHTTPRequestHandler, ThreadingHTTPServer

REPO_ROOT = os.environ.get("REPO_ROOT", "/Users/christopher.ezell/Spectroscope/apt-repo")
POOL_DIR = os.environ["POOL_DIR"]          # directory server B serves from
LOG_PATH = os.environ["LOG_PATH"]
PORT_A = int(os.environ.get("PORT_A", "8810"))
PORT_B = int(os.environ.get("PORT_B", "8811"))
# Host name the redirect points at, as seen from inside the container.
REDIRECT_HOST = os.environ.get("REDIRECT_HOST", "host.docker.internal")
TLS_CERT = os.environ.get("TLS_CERT")      # set both to run the pair over https
TLS_KEY = os.environ.get("TLS_KEY")
# When set to a byte count, server B cuts the very first package transfer short
# and closes the socket. That is how a resume gets provoked on purpose, so the
# Range behaviour can be read off the log instead of assumed.
TRUNCATE_FIRST = int(os.environ.get("POOL_TRUNCATE_FIRST", "0"))
# A second hop. A GitHub release download is itself a redirect to signed object
# storage, so the real chain is worker -> release -> objects, not one jump.
CHAIN_PORT = int(os.environ.get("POOL_CHAIN_PORT", "0"))
# Pretend the pool host has no Range support and always answers 200 with the
# whole body, to see what apt does with a resume it cannot have.
IGNORE_RANGE = os.environ.get("POOL_IGNORE_RANGE") == "1"

SCHEME = "https" if TLS_CERT else "http"
_log_lock = threading.Lock()
_truncate_lock = threading.Lock()
_truncated_once = False


def claim_truncation() -> bool:
    global _truncated_once
    if not TRUNCATE_FIRST:
        return False
    with _truncate_lock:
        if _truncated_once:
            return False
        _truncated_once = True
        return True


def log(record: dict) -> None:
    record["t"] = time.strftime("%H:%M:%S")
    with _log_lock:
        with open(LOG_PATH, "a") as handle:
            handle.write(json.dumps(record) + "\n")


def interesting_headers(headers) -> dict:
    keep = ("range", "if-range", "user-agent", "accept", "host", "cache-control",
            "if-modified-since", "if-none-match", "connection", "accept-encoding")
    return {k: v for k, v in headers.items() if k.lower() in keep}


class IndexHandler(SimpleHTTPRequestHandler):
    """Server A: the signed tree, plus a 302 for anything under /pool/."""

    server_label = "A-index"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=REPO_ROOT, **kwargs)

    def _redirect_target(self) -> str:
        name = self.path.split("?", 1)[0].rsplit("/", 1)[-1]
        return f"{SCHEME}://{REDIRECT_HOST}:{PORT_B}/assets/{name}"

    def _maybe_redirect(self) -> bool:
        if not self.path.startswith("/pool/"):
            return False
        target = self._redirect_target()
        log({"server": self.server_label, "method": self.command, "path": self.path,
             "status": 302, "location": target, "headers": interesting_headers(self.headers)})
        self.send_response(302)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.end_headers()
        return True

    def do_GET(self):
        if self._maybe_redirect():
            return
        log({"server": self.server_label, "method": "GET", "path": self.path,
             "headers": interesting_headers(self.headers)})
        super().do_GET()

    def do_HEAD(self):
        if self._maybe_redirect():
            return
        log({"server": self.server_label, "method": "HEAD", "path": self.path,
             "headers": interesting_headers(self.headers)})
        super().do_HEAD()

    def log_message(self, fmt, *args):  # keep stderr quiet; the JSON log is the record
        pass


class PoolHandler(BaseHTTPRequestHandler):
    """Server B: the package bytes, with Range support."""

    server_label = "C-pool" if CHAIN_PORT else "B-pool"
    protocol_version = "HTTP/1.1"

    def _resolve(self):
        name = self.path.split("?", 1)[0].rsplit("/", 1)[-1]
        path = os.path.join(POOL_DIR, name)
        return path if os.path.isfile(path) else None

    def _serve(self, body: bool):
        path = self._resolve()
        hdrs = interesting_headers(self.headers)
        if path is None:
            log({"server": self.server_label, "method": self.command, "path": self.path,
                 "status": 404, "headers": hdrs})
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        size = os.path.getsize(path)
        start, end = 0, size - 1
        status = 200
        rng = None if IGNORE_RANGE else self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            spec = rng[len("bytes="):].split(",")[0].strip()
            lo, _, hi = spec.partition("-")
            if lo:
                start = int(lo)
                end = int(hi) if hi else size - 1
            elif hi:  # suffix range
                start = max(0, size - int(hi))
            end = min(end, size - 1)
            status = 206

        length = max(0, end - start + 1)
        cut = TRUNCATE_FIRST if (body and claim_truncation()) else 0
        log({"server": self.server_label, "method": self.command, "path": self.path,
             "status": status, "served_file": os.path.basename(path), "file_size": size,
             "range_out": f"{start}-{end}", "truncated_to": cut, "headers": hdrs})

        self.send_response(status)
        self.send_header("Content-Type", "application/vnd.debian.binary-package")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if not body:
            return
        budget = cut if cut else length
        with open(path, "rb") as handle:
            handle.seek(start)
            remaining = min(length, budget)
            while remaining > 0:
                chunk = handle.read(min(1 << 20, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)
        if cut:
            # Promised more than was delivered, then hang up: a dropped transfer.
            self.close_connection = True
            try:
                self.wfile.flush()
                self.connection.close()
            except OSError:
                pass

    def do_GET(self):
        self._serve(body=True)

    def do_HEAD(self):
        self._serve(body=False)

    def log_message(self, fmt, *args):
        pass


class ChainHandler(BaseHTTPRequestHandler):
    """Server B when a second hop is configured: it only points further on."""

    server_label = "B-chain"
    protocol_version = "HTTP/1.1"

    def _bounce(self):
        name = self.path.split("?", 1)[0].rsplit("/", 1)[-1]
        target = f"{SCHEME}://{REDIRECT_HOST}:{CHAIN_PORT}/final/{name}"
        log({"server": self.server_label, "method": self.command, "path": self.path,
             "status": 302, "location": target, "headers": interesting_headers(self.headers)})
        self.send_response(302)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = do_HEAD = _bounce

    def log_message(self, fmt, *args):
        pass


def wrap_tls(httpd):
    if not TLS_CERT:
        return httpd
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(TLS_CERT, TLS_KEY)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    return httpd


def main() -> None:
    servers = [(wrap_tls(ThreadingHTTPServer(("0.0.0.0", PORT_A), IndexHandler)), "A-index")]
    if CHAIN_PORT:
        servers.append((wrap_tls(ThreadingHTTPServer(("0.0.0.0", PORT_B), ChainHandler)), "B-chain"))
        servers.append((wrap_tls(ThreadingHTTPServer(("0.0.0.0", CHAIN_PORT), PoolHandler)), "C-pool"))
    else:
        servers.append((wrap_tls(ThreadingHTTPServer(("0.0.0.0", PORT_B), PoolHandler)), "B-pool"))
    for srv, name in servers:
        threading.Thread(target=srv.serve_forever, daemon=True, name=name).start()
    print(f"A ({SCHEME}) :{PORT_A} -> {REPO_ROOT}", flush=True)
    if CHAIN_PORT:
        print(f"B ({SCHEME}) :{PORT_B} -> 302 to :{CHAIN_PORT}", flush=True)
        print(f"C ({SCHEME}) :{CHAIN_PORT} -> {POOL_DIR}", flush=True)
    else:
        print(f"B ({SCHEME}) :{PORT_B} -> {POOL_DIR}", flush=True)
    print(f"truncate_first={TRUNCATE_FIRST} ignore_range={IGNORE_RANGE}", flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
