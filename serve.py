#!/usr/bin/env python3
"""Serve this directory cross-origin isolated, which webR needs for SharedArrayBuffer.

Without COOP/COEP the SharedArrayBuffer channel is unavailable and webR silently falls
back to PostMessage, which cannot do readline()/menu()/browser() or interrupt a running
computation -- i.e. the terminal stops working. See README "Why the server matters".

    python3 serve.py [port]
"""

import argparse
import functools
import http.server
import os
import sys

# Python's mimetypes DB predates these; .mjs served as text/plain makes the ESM import fail.
EXTRA_TYPES = {
    ".mjs": "text/javascript",
    ".js": "text/javascript",
    ".wasm": "application/wasm",
    ".data": "application/octet-stream",
    ".metadata": "application/json",
    ".tgz": "application/gzip",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    # Keep-alive; the webR distribution is many separate files.
    protocol_version = "HTTP/1.1"

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def guess_type(self, path):
        ext = os.path.splitext(path)[1].lower()
        if ext in EXTRA_TYPES:
            return EXTRA_TYPES[ext]
        return super().guess_type(path)

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", nargs="?", type=int, default=8080)
    parser.add_argument(
        "--root",
        default=os.path.dirname(os.path.abspath(__file__)),
        help="directory to serve (default: this file's directory; use dist/ to test a build)",
    )
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    handler = functools.partial(Handler, directory=root)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler)

    print(f"Serving {root}")
    print(f"  http://127.0.0.1:{args.port}")
    print("  COOP/COEP set; check `crossOriginIsolated === true` in the browser console.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
