#!/usr/bin/env python3
"""Tiny local server for the browser camera probe.

Serves tests/cam-test.html over http://127.0.0.1 -- which browsers treat as a
secure context, so getUserMedia is allowed -- and accepts the probe's POST /result
callback, writing it to out/browser-result.json. Exits once a result arrives or
the deadline passes, so the test script can just wait on the process.
"""

import argparse
import http.server
import json
import pathlib
import sys
import threading

ROOT = pathlib.Path(__file__).resolve().parent.parent
done = threading.Event()


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(ROOT / "tests"), **kw)

    def do_POST(self):
        if self.path not in ("/result", "/image"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        (ROOT / "out").mkdir(exist_ok=True)

        # The frame arrives separately from the verdict, so a large image can
        # never cost us the result.
        if self.path == "/image":
            import base64

            text = raw.decode("utf-8", "replace")
            if "," in text:
                (ROOT / "out" / "chrome-capture.jpg").write_bytes(
                    base64.b64decode(text.split(",", 1)[1])
                )
            self.send_response(204)
            self.end_headers()
            done.set()
            return

        target = ROOT / "out" / "browser-result.json"
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"verdict": "UNPARSEABLE", "raw": raw.decode("utf-8", "replace")}
        target.write_text(json.dumps(payload, indent=1))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_a):
        pass  # keep the test output readable


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--timeout", type=float, default=60.0)
    args = ap.parse_args()

    result = ROOT / "out" / "browser-result.json"
    result.unlink(missing_ok=True)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"serving http://127.0.0.1:{args.port}/cam-test.html", flush=True)

    got = done.wait(args.timeout)
    srv.shutdown()
    sys.exit(0 if got else 1)


if __name__ == "__main__":
    main()
