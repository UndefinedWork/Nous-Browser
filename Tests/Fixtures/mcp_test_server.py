#!/usr/bin/env python3
"""Loopback-only, disposable page for Nous MCP integration tests."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Nous MCP Fixture {title}</title>
<style>body{{font:18px system-ui;margin:30px}}input,button,a{{font:inherit;margin:8px;padding:8px}} .spacer{{height:1800px}}footer{{padding:20px}}</style>
</head><body>
<h1>Nous MCP Fixture {title}</h1><p>This is synthetic, disposable browser test content.</p>
<label for="message">Message</label><input id="message" aria-label="Message" autocomplete="off">
<button id="increment">Increment</button><a href="/page2">Next page</a>
<p id="echo">Input event: empty</p><p id="counter">Counter: 0</p><p id="keyboard">Key: none</p>
<label for="secret">Synthetic password</label><input id="secret" aria-label="Synthetic password" type="password" value="FIXTURE_ONLY_NOT_A_REAL_PASSWORD">
<button id="disabled" disabled>Disabled fixture button</button>
<div hidden>HIDDEN_FIXTURE_TEXT</div><textarea style="display:none">HIDDEN_FIXTURE_VALUE</textarea>
<div class="spacer"></div><footer>Fixture footer</footer>
<script>
let count = 0;
const message = document.querySelector('#message');
message.addEventListener('input', () => {{ document.querySelector('#echo').textContent = 'Input event: ' + message.value; }});
message.addEventListener('keydown', e => {{ document.querySelector('#keyboard').textContent = 'Key: ' + e.key; }});
document.querySelector('#increment').onclick = () => {{ document.querySelector('#counter').textContent = 'Counter: ' + (++count); }};
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path not in ("/", "/page2"):
            self.send_error(404)
            return
        data = PAGE.format(title="Two" if path == "/page2" else "One").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8767)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http://127.0.0.1:{server.server_port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
