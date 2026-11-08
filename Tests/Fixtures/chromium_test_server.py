#!/usr/bin/env python3
"""Synthetic loopback pages for the opt-in ChromiumSmokeCheck (preview builds).

Run:  python3 Tests/Fixtures/chromium_test_server.py [port]   (default 18866)
Then launch the chromium-preview app with NOUS_CHROMIUM_SMOKE_REPORT=<file>.

Everything here is fake: no real accounts, no network beyond 127.0.0.1 and
localhost (a second origin for the cross-origin iframe and form actions).
"""
import http.server
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18866
OTHER = f"http://localhost:{PORT}"

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>
<style>body{{font:14px -apple-system;margin:24px;max-width:640px}}label{{display:block;margin:10px 0}}</style>
</head><body>{body}</body></html>"""

LOGIN_FORM = """<form id="login" action="{action}" method="post">
<label>Email <input id="username" name="username" type="email" autocomplete="username"></label>
<label>Password <input id="password" name="password" type="password" autocomplete="current-password"></label>
<button type="submit">Sign in</button></form>
<script>
const fixtureEvents = {{submit: 0, input: 0}};
const form = document.getElementById('login');
form.addEventListener('submit', event => {{ fixtureEvents.submit += 1; event.preventDefault(); }});
form.addEventListener('input', () => {{ fixtureEvents.input += 1; }});
{extra}
</script>"""


def page(title, body):
    return PAGE.format(title=title, body=body).encode()


ROUTES = {
    "/": lambda: page("Nous synthetic fixture", f"""
<h1>Synthetic fixture</h1>
<label>Message <input id="message" aria-label="Message"></label>
<label>Files <input id="files" type="file" multiple></label>
<label>Editor <textarea id="editor"></textarea></label>
<button onclick="window.open('/popup','nousSmokePopup')">Open popup with opener</button>
<iframe src="{OTHER}/frame" title="Cross-origin frame" width="320" height="60"></iframe>
<script>
window.__fixture = {{}};
addEventListener('message', event => {{
  if (event.origin === '{OTHER}') window.__fixture.iframeReport = event.data;
}});
</script>"""),
    "/frame": lambda: page("Cross-origin frame", """<p>Cross-origin frame</p><script>
parent.postMessage({passwordBinding: typeof globalThis.__nousPasswordCandidate,
                    smokeBinding: typeof globalThis.__nousSmokeMessage}, '*');
</script>"""),
    "/page2": lambda: page("Page two", "<h1>Page two</h1><p>Synthetic second page.</p>"),
    "/popup": lambda: page("Popup", """<p>Popup</p><script>
window.__hasOpener = !!window.opener;
try { if (window.opener) window.opener.__popupReply = 'popup-replied'; } catch (_) {}
</script>"""),
    "/never-selected": lambda: page("Never selected", """<p>Background page</p><script>
const started = performance.now();
const state = window.__nousNeverSelected = {
  initialVisibility: document.visibilityState, initialHidden: document.hidden,
  initialReadyState: document.readyState,
  loadID: Math.random().toString(36).slice(2), rafCount: 0, longTimer: null};
setTimeout(() => { state.longTimer = {visibility: document.visibilityState, elapsed: performance.now() - started}; }, 1200);
(function tick() { requestAnimationFrame(() => { state.rafCount += 1; tick(); }); })();
</script>"""),
    "/login": lambda: page("Synthetic login", LOGIN_FORM.format(action="/login-submit", extra="")),
    "/alternate": lambda: page("Synthetic login (alternate)", LOGIN_FORM.format(action="/login-submit", extra="")),
    "/cross-action": lambda: page("Cross-origin action", LOGIN_FORM.format(action=f"{OTHER}/collect", extra="")),
    "/mutate-on-username": lambda: page("Mutating action", LOGIN_FORM.format(
        action="/login-submit",
        extra=f"document.getElementById('username').addEventListener('input', () => {{ form.action = '{OTHER}/collect'; }});")),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        route = ROUTES.get(self.path.split("?")[0])
        if route is None:
            self.send_error(404)
            return
        body = route()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    # Bind both loopback names so 127.0.0.1 and localhost are distinct origins.
    with Server(("127.0.0.1", PORT), Handler) as server:
        print(f"Synthetic fixture on http://127.0.0.1:{PORT}/ (second origin {OTHER})")
        server.serve_forever()
