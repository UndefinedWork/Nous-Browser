#!/usr/bin/env python3
"""Local, synthetic fixtures for native reload, find, zoom, and storage QA.

Run: python3 Tests/Fixtures/shortcut_test_server.py --port 8766 --log requests.jsonl
Visit /cache.html, advance the revision with /advance, then compare ordinary and
cache-bypassing reloads. The request log includes only cache-related headers.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
from urllib.parse import urlsplit


COOKIE = "nous_shortcut_fixture=synthetic; Path=/; SameSite=Lax"
HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Shortcut Test</title>
  <style>
    :root { color-scheme: light dark; font: 17px/1.65 system-ui, sans-serif; }
    body { max-width: 900px; margin: 0 auto; padding: 32px; }
    header { padding-bottom: 24px; border-bottom: 1px solid #8886; }
    .status { display: grid; gap: 6px; margin: 18px 0; }
    output { display: block; font-family: ui-monospace, monospace; }
    label { display: block; margin-top: 20px; }
    input, button { font: inherit; padding: 8px 12px; }
    input { max-width: 100%; box-sizing: border-box; }
    button { margin: 8px 0; }
    section { min-height: 850px; padding-top: 40px; border-bottom: 1px solid #8886; }
    p { max-width: 70ch; }
  </style>
  <script defer src="/version.js"></script>
</head>
<body>
  <header>
    <h1>Shortcut Test</h1>
    <p>This page and every value below are local synthetic test fixtures.</p>
    <div class="status" aria-label="Fixture status">
      <output id="resource-version">Resource version: waiting</output>
      <output id="cookie-status">Cookie present: checking</output>
      <output id="viewport-width">Viewport width: checking</output>
    </div>
    <label for="test-note">Test note</label>
    <input id="test-note" type="text" autocomplete="off" placeholder="Synthetic test note">
    <button id="save-note" type="button">Save test note</button>
    <output id="saved-note" aria-live="polite">Saved note: none</output>
  </header>
  <main>
    <section id="first-section">
      <h2>First section</h2>
      <p>Needle Alpha appears in the first paragraph near the top of the page.</p>
      <p>Use page find to move between the separated paragraphs. This tall section
      keeps the next result outside the initial viewport.</p>
    </section>
    <section id="second-section">
      <h2>Second section</h2>
      <p>The second paragraph contains Needle Alpha in the middle of the document.</p>
      <p>This is independent fixture text. Zooming the page changes the CSS
      viewport width shown in the header.</p>
    </section>
    <section id="third-section">
      <h2>Third section</h2>
      <p>At the bottom, Needle Alpha marks the third and final matching paragraph.</p>
      <p>End of the shortcut fixture.</p>
    </section>
  </main>
  <script>
    (() => {
      const noteKey = 'nous-shortcut-fixture-note';
      const note = document.getElementById('test-note');
      const savedNote = document.getElementById('saved-note');
      function showSavedNote(value) {
        savedNote.textContent = 'Saved note: ' + (value || 'none');
      }
      try {
        note.value = localStorage.getItem(noteKey) || '';
        showSavedNote(note.value);
      } catch (_) {
        savedNote.textContent = 'Saved note: storage unavailable';
      }
      document.getElementById('save-note').addEventListener('click', () => {
        try {
          localStorage.setItem(noteKey, note.value);
          showSavedNote(note.value);
        } catch (_) {
          savedNote.textContent = 'Saved note: storage unavailable';
        }
      });
      const syntheticCookiePresent = document.cookie.split(';').some(
        part => part.trim() === 'nous_shortcut_fixture=synthetic'
      );
      document.getElementById('cookie-status').textContent =
        'Cookie present: ' + (syntheticCookiePresent ? 'yes' : 'no');
      function updateViewport() {
        document.getElementById('viewport-width').textContent =
          'Viewport width: ' + window.innerWidth;
      }
      window.addEventListener('resize', updateViewport);
      updateViewport();
    })();
  </script>
</body>
</html>
""".encode("utf-8")


class FixtureState:
    def __init__(self, log_stream=None):
        self.revision = 1
        self.lock = threading.Lock()
        self.log_stream = log_stream

    def snapshot(self, advance=False):
        with self.lock:
            if advance:
                self.revision += 1
            return self.revision

    def append_log(self, event):
        if self.log_stream is None:
            return
        with self.lock:
            self.log_stream.write(json.dumps(event, ensure_ascii=False) + "\n")
            self.log_stream.flush()


class ShortcutServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, state):
        self.state = state
        super().__init__(address, ShortcutHandler)


class ShortcutHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "NousShortcutFixture/1.0"

    def log_message(self, _format, *_args):
        # Optional JSONL below is the only access log. Never log Cookie headers.
        pass

    def do_GET(self):
        self._route()

    def do_HEAD(self):
        self._route()

    def _route(self):
        path = urlsplit(self.path).path
        revision = self.server.state.snapshot(advance=path == "/advance")
        if path in ("/", "/cache.html"):
            self._respond(200, HTML, "text/html; charset=utf-8", revision)
        elif path == "/version.js":
            etag = '"revision-%d"' % revision
            script = (
                "(() => {\n"
                "  const version = %d;\n" % revision
                + "  document.getElementById('resource-version').textContent = 'Resource version: ' + version;\n"
                + "  window.shortcutFixtureResourceVersion = version;\n"
                + "})();\n"
            ).encode("utf-8")
            validators = [value.strip() for value in self.headers.get("If-None-Match", "").split(",")]
            unchanged = etag in validators or ("W/" + etag) in validators
            self._respond(304 if unchanged else 200, script, "text/javascript; charset=utf-8", revision,
                          cache_control="public, max-age=31536000", etag=etag)
        elif path == "/advance":
            body = (json.dumps({"revision": revision}) + "\n").encode("utf-8")
            self._respond(200, body, "application/json; charset=utf-8", revision)
        elif path == "/favicon.ico":
            self._respond(204, b"", "image/x-icon", revision)
        else:
            self._respond(404, b"Fixture page not found.\n", "text/plain; charset=utf-8", revision)

    def send_error(self, code, message=None, explain=None):
        # Include the fixture cookie and bounded cache metadata for error replies too.
        revision = self.server.state.snapshot()
        self._respond(code, b"Request not supported.\n", "text/plain; charset=utf-8", revision)

    def _respond(self, status, body, content_type, revision, cache_control="no-store", etag=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", cache_control)
        self.send_header("Set-Cookie", COOKIE)
        self.send_header("X-Content-Type-Options", "nosniff")
        if etag is not None:
            self.send_header("ETag", etag)
        if status != 204:
            # For 304, this is the length of the corresponding 200 representation.
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and status not in (204, 304):
            self.wfile.write(body)
        headers = getattr(self, "headers", {})
        self.server.state.append_log({
            "method": getattr(self, "command", ""),
            "path": urlsplit(getattr(self, "path", "")).path,
            "cache_control": headers.get("Cache-Control", ""),
            "if_none_match": headers.get("If-None-Match", ""),
            "revision": revision,
            "status": status,
        })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8766, help="Local port (default: 8766)")
    parser.add_argument("--log", type=Path, help="Append cache-related request metadata as JSONL")
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("--port must be between 0 and 65535")
    log_stream = args.log.open("a", encoding="utf-8") if args.log else None
    server = None
    try:
        server = ShortcutServer(("127.0.0.1", args.port), FixtureState(log_stream))
        print("Shortcut fixture: http://127.0.0.1:%d/cache.html" % server.server_address[1], flush=True)
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        if server is not None:
            server.server_close()
        if log_stream is not None:
            log_stream.close()


if __name__ == "__main__":
    main()
