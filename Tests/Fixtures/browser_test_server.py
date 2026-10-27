#!/usr/bin/env python3
"""Local development fixture. All accounts and cookies here are synthetic.

Run with: python3 Tests/Fixtures/browser_test_server.py
Open /downloads for Save-panel, authenticated, Blob, and media download cases.
This fixture has no application runtime dependency and never uses real accounts.
"""

import argparse
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from html import escape
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import math
import re
import struct
import time
from urllib.parse import parse_qs, urlsplit
import wave
import zlib


COOKIE_NAME = "nous_browser_fixture_session"
COOKIE_VALUE = "synthetic-local-session"
STORAGE_KEY = "nous-browser-fixture-note"
DOWNLOAD_COOKIE_NAME = "nous_browser_download_fixture"
DOWNLOAD_COOKIE_VALUE = "synthetic-download-session"
DOWNLOAD_PAYLOAD = b"Nous Browser saved download fixture\nSynthetic data only.\n"


def make_fixture_icon(letter: str, color: tuple[int, int, int]) -> bytes:
    """Create a deterministic 32px RGBA PNG from synthetic fixture pixels."""
    glyphs = {
        "F": ("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
        "S": ("11111", "10000", "10000", "11111", "00001", "00001", "11111"),
        "G": ("01111", "10000", "10000", "10111", "10001", "10001", "01111"),
    }
    glyph = glyphs[letter]
    scanlines = bytearray()
    for y in range(32):
        scanlines.append(0)  # PNG filter: None.
        for x in range(32):
            inside_circle = (x - 15.5) ** 2 + (y - 15.5) ** 2 <= 15.5 ** 2
            pixel = (*color, 255) if inside_circle else (0, 0, 0, 0)
            column, row = (x - 8) // 3, (y - 5) // 3
            if 0 <= column < 5 and 0 <= row < 7 and glyph[row][column] == "1":
                pixel = (255, 255, 255, 255)
            scanlines.extend(pixel)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(scanlines), level=9))
        + chunk(b"IEND", b"")
    )


FAVICON_FIXTURES = {
    "/favicon-icons/primary.png": make_fixture_icon("F", (35, 105, 240)),
    "/favicon-icons/secondary.png": make_fixture_icon("S", (239, 132, 31)),
    "/favicon.ico": make_fixture_icon("G", (108, 116, 126)),
}


def make_fixture_audio() -> bytes:
    """Generate one second of quiet 440 Hz mono PCM audio without asset files."""
    sample_rate = 8000
    samples = b"".join(
        struct.pack("<h", round(2000 * math.sin(2 * math.pi * 440 * frame / sample_rate)))
        for frame in range(sample_rate)
    )
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(sample_rate)
        audio.writeframes(samples)
    return output.getvalue()


DOWNLOAD_AUDIO = make_fixture_audio()
DOWNLOAD_IMAGE = make_fixture_icon("F", (35, 105, 240))


def downloads_body() -> str:
    return r"""
<section aria-label="Save panel verification">
  <h2>Choose a destination</h2>
  <p>Each download should open the native Save panel. Choose a folder and filename,
     then Save. Cancel should leave no final file. Download twice to test replacement.</p>
  <nav>
    <a id="download-attribute" href="/downloads/payload.txt" download="chosen-name.txt">Download attribute</a>
    <a id="download-attachment" href="/downloads/attachment">Attachment response</a>
    <a id="download-new-window" href="/downloads/attachment" target="_blank">New-window attachment</a>
    <a id="download-data" href="data:text/plain;charset=utf-8,Nous%20data%20download%20fixture%0A" download="data-fixture.txt">Data URL</a>
  </nav>
  <button id="download-blob">Download Blob</button>
  <script>
    document.getElementById('download-blob').addEventListener('click', () => {
      const url = URL.createObjectURL(new Blob(['Nous blob download fixture\n'], {type: 'text/plain'}));
      const link = document.createElement('a');
      link.href = url;
      link.download = 'blob-fixture.txt';
      document.body.append(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
    });
  </script>
</section>
<section aria-label="Authenticated and interrupted downloads">
  <h2>Session and failure handling</h2>
  <p>Opening this page sets a synthetic HttpOnly cookie scoped to /downloads. The
     protected attachment requires it; no real account is used.</p>
  <p><a id="download-protected" href="/downloads/protected">Authenticated attachment</a></p>
  <p><a id="download-interrupted" href="/downloads/interrupted">Interrupted download</a></p>
  <p>For the interrupted case, choose an existing test file and confirm Replace.
     The connection deliberately ends early; the original file must remain intact.</p>
</section>
<section aria-label="Native media context menu downloads">
  <h2>Native context menus</h2>
  <p>Right-click the image, audio, or the link to test Save Image, Download Audio,
     and Download Linked File. The image and one-second quiet tone are generated locally.</p>
  <p><img id="download-image" src="/downloads/image.png" width="128" height="128" alt="Synthetic blue F image"></p>
  <audio id="download-audio" aria-label="Synthetic one-second audio" controls preload="metadata" src="/downloads/audio.wav"></audio>
  <p><a href="/downloads/payload.txt">Native linked-file download</a></p>
</section>"""


def page(title: str, body: str, head: str = "") -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  {head}
  <style>
    :root {{ color-scheme: light dark; font: 16px system-ui; }}
    body {{ max-width: 720px; margin: 40px auto; padding: 24px; line-height: 1.6; }}
    nav {{ display: flex; flex-wrap: wrap; gap: 16px; }}
    section {{ border: 1px solid #8885; border-radius: 16px; padding: 20px; margin: 20px 0; }}
    button, input {{ font: inherit; padding: 8px 12px; margin: 4px 0; }}
    label {{ display: block; }}
    output {{ display: block; font-weight: 600; overflow-wrap: anywhere; }}
    small {{ opacity: .65; }}
  </style>
</head>
<body>
  <h1>{title}</h1>
  <p><small>Local browser development fixture. Synthetic data only.</small></p>
  {body}
  <nav aria-label="Fixture navigation"><a href="/">Browser Test</a><a href="/account">Account</a></nav>
</body>
</html>"""


def storage_form() -> str:
    return f"""
<section aria-label="Local storage persistence">
  <h2>Local storage</h2>
  <form id="note-form">
    <label for="note-input">Test note</label>
    <input id="note-input" name="note" placeholder="Enter a synthetic test note" autocomplete="off">
    <button type="submit">Save note</button>
  </form>
  <p>Saved note:</p><output id="saved-note" aria-live="polite"></output>
</section>
<script>
  const storageKey = {STORAGE_KEY!r};
  const savedNote = document.getElementById('saved-note');
  const noteInput = document.getElementById('note-input');
  function showSavedNote() {{
    const value = localStorage.getItem(storageKey);
    savedNote.textContent = value === null ? 'No saved note' : value;
    noteInput.value = value || '';
  }}
  document.getElementById('note-form').addEventListener('submit', event => {{
    event.preventDefault();
    localStorage.setItem(storageKey, noteInput.value);
    showSavedNote();
  }});
  showSavedNote();
</script>"""


def browser_profile_body(request_user_agent: str) -> str:
    """Expose only browser identity and viewport diagnostics, never account data."""
    safe_request_user_agent = escape(request_user_agent, quote=True)
    return """
<style>
  body { max-width: 720px; margin: 0 auto; padding: 16px; font-size: 12px; }
  h1 { margin: 0 0 4px; font-size: 22px; }
  body > p { margin: 4px 0 8px; }
  .profile-label { display: block; margin-top: 10px; font-weight: 600; }
  .profile-field { box-sizing: border-box; width: 100%; min-height: 62px; resize: vertical; padding: 7px; font: 11px/1.45 ui-monospace, monospace; overflow-wrap: anywhere; }
  .profile-summary { margin: 8px 0; padding: 8px; background: #8881; border: 1px solid #8885; border-radius: 6px; }
  #profile-json { white-space: pre-wrap; overflow-wrap: anywhere; font: 11px/1.45 ui-monospace, monospace; }
</style>
<output id="javascript-status" aria-live="polite">JavaScript status: not run (server-rendered default)</output>
<noscript><p>JavaScript status: disabled</p></noscript>
<label class="profile-label" for="request-user-agent">Request User-Agent header</label>
<textarea id="request-user-agent" class="profile-field" rows="3" readonly aria-label="Request User-Agent header">""" + safe_request_user_agent + """</textarea>
<label class="profile-label" for="navigator-user-agent">navigator.userAgent</label>
<textarea id="navigator-user-agent" class="profile-field" rows="3" readonly aria-label="navigator.userAgent">Waiting for JavaScript</textarea>
<div class="profile-summary">
  <output id="navigator-platform" aria-live="polite">navigator.platform: waiting for JavaScript</output>
  <output id="viewport-profile" aria-live="polite">Viewport: waiting for JavaScript</output>
</div>
<details open>
  <summary>Browser profile JSON</summary>
  <pre id="profile-json" tabindex="0" aria-label="Browser profile JSON">Waiting for JavaScript</pre>
</details>
<nav aria-label="Browser profile navigation">
  <a href="https://www.google.com/" target="_blank" rel="noopener">Open Google homepage in new tab</a>
  <a href="/">Fixture home</a>
</nav>
<script>
  function showBrowserProfile() {
    const profile = {
      requestUserAgent: document.getElementById('request-user-agent').value,
      navigatorUserAgent: navigator.userAgent,
      navigatorPlatform: navigator.platform,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio,
      javaScriptEnabled: true
    };
    document.getElementById('javascript-status').textContent = 'JavaScript status: enabled (script executed)';
    document.getElementById('navigator-user-agent').value = profile.navigatorUserAgent;
    document.getElementById('navigator-platform').textContent = `navigator.platform: ${profile.navigatorPlatform}`;
    document.getElementById('viewport-profile').textContent = `Viewport: ${profile.innerWidth} × ${profile.innerHeight}; devicePixelRatio: ${profile.devicePixelRatio}`;
    document.getElementById('profile-json').textContent = JSON.stringify(profile, null, 2);
  }
  showBrowserProfile();
  window.addEventListener('resize', showBrowserProfile);
</script>"""


def scrollbar_test_body() -> str:
    """Intentionally visible author-styled bars; the app must hide them."""
    return r"""
<style>
  :root { color-scheme: light; scrollbar-color: #ff2020 #ffd8d8; scrollbar-width: auto; }
  html { overflow: scroll; }
  body { max-width: none; margin: 0; padding: 12px; font-size: 12px; color: #202020; background: #fafafa; }
  body > h1 { margin: 0 0 2px; font-size: 20px; line-height: 1.2; }
  body > p { margin: 2px 0 8px; }
  * { box-sizing: border-box; }
  *::-webkit-scrollbar { width: 18px; height: 18px; background: #ffd8d8; }
  *::-webkit-scrollbar-thumb { background: #ff2020; border: 2px solid #ffd8d8; }
  *::-webkit-scrollbar-corner { background: #ff8080; }
  .fixture-content { width: min(100%, 600px); }
  .fixture-status { position: sticky; top: 0; z-index: 5; padding: 5px 8px; background: #fff7d6; border: 1px solid #ddc576; }
  .fixture-grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 12px; margin: 10px 0; }
  .fixture-card { min-width: 0; }
  h2 { margin: 0 0 4px; font-size: 13px; line-height: 1.3; }
  .scroll-panel { width: 100%; height: 100px; overflow: scroll; border: 2px solid #808080; background: white; scrollbar-color: #ff2020 #ffd8d8; scrollbar-width: auto; }
  .scroll-panel:focus { outline: 2px solid #3264e8; outline-offset: 1px; }
  .panel-content { width: 800px; height: 420px; padding: 8px; background: repeating-linear-gradient(#edf3ff 0 29px, #c9d8f4 29px 30px); }
  .panel-bottom { margin-top: 300px; }
  .panel-right { display: inline-block; margin-left: 600px; }
  output { font-size: 11px; line-height: 1.5; }
  iframe { width: 100%; height: 155px; border: 2px solid #808080; background: white; }
  #dynamic-controls { margin: 9px 0; }
  #dynamic-controls button { padding: 5px 10px; font-size: 12px; }
  #dynamic-target { margin-top: 6px; }
  .page-spacer { height: 900px; padding-top: 24px; background: linear-gradient(#fafafa, #edf3ff); }
  .page-bottom { padding: 12px; border: 2px solid #38834c; background: #e8f6e9; }
  .horizontal-extent { width: 1280px; height: 42px; padding: 8px; background: #e7eafa; white-space: nowrap; }
  .horizontal-extent span { margin-left: 1000px; }
</style>
<main class="fixture-content">
  <output id="window-position" class="fixture-status" aria-live="polite" aria-label="Window scroll position">Window x: 0 y: 0</output>
  <div class="fixture-grid">
    <div class="fixture-card">
      <h2>Nested scroll panel</h2>
      <div id="nested-panel" class="scroll-panel" role="region" tabindex="0" aria-label="Nested scroll panel" aria-describedby="nested-position">
        <div class="panel-content">Nested top sentinel. Click here, then use arrow keys.
          <span class="panel-right">Nested right sentinel</span>
          <p class="panel-bottom">Nested bottom sentinel</p>
        </div>
      </div>
      <output id="nested-position" aria-live="polite">Nested x: 0 y: 0</output>
    </div>
    <div class="fixture-card">
      <h2>Open shadow root panel</h2>
      <div id="shadow-host"></div>
      <output id="shadow-position" aria-live="polite">Shadow x: 0 y: 0</output>
    </div>
  </div>
  <h2>Same-origin iframe</h2>
  <iframe src="/scrollbars-frame" title="Same-origin scrollbar iframe"></iframe>
  <div id="dynamic-controls">
    <button id="add-dynamic" type="button">Add dynamic scroll panel</button>
    <output id="dynamic-position" aria-live="polite">Dynamic panel not added</output>
    <div id="dynamic-target"></div>
  </div>
  <nav aria-label="Scrollbar fixture navigation"><a href="/">Fixture home</a><a href="#page-bottom">Jump to page bottom</a></nav>
  <div class="page-spacer">Page scrolling area. Scroll downward to reveal the green page-bottom sentinel.</div>
  <div id="page-bottom" class="page-bottom" tabindex="0">Page bottom sentinel — vertical page scrolling works.</div>
</main>
<div class="horizontal-extent">Page horizontal scrolling area<span>Page right sentinel</span></div>
<script>
  function updateWindowPosition() {
    document.getElementById('window-position').textContent = `Window x: ${Math.round(window.scrollX)} y: ${Math.round(window.scrollY)}`;
  }
  window.addEventListener('scroll', updateWindowPosition, { passive: true });
  function trackPanel(panel, outputId, label) {
    const output = document.getElementById(outputId);
    const update = () => { output.textContent = `${label} x: ${Math.round(panel.scrollLeft)} y: ${Math.round(panel.scrollTop)}`; };
    panel.addEventListener('scroll', update, { passive: true });
    update();
  }
  trackPanel(document.getElementById('nested-panel'), 'nested-position', 'Nested');
  const shadow = document.getElementById('shadow-host').attachShadow({ mode: 'open' });
  shadow.innerHTML = `
    <style>
      :host { display: block; }
      #shadow-panel { box-sizing: border-box; width: 100%; height: 100px; overflow: scroll; border: 2px solid #808080; background: white; scrollbar-color: #ff2020 #ffd8d8; scrollbar-width: auto; }
      #shadow-panel:focus { outline: 2px solid #3264e8; outline-offset: 1px; }
      *::-webkit-scrollbar { width: 18px; height: 18px; background: #ffd8d8; }
      *::-webkit-scrollbar-thumb { background: #ff2020; border: 2px solid #ffd8d8; }
      *::-webkit-scrollbar-corner { background: #ff8080; }
      .content { box-sizing: border-box; width: 800px; height: 420px; padding: 8px; font: 12px/1.6 system-ui; background: repeating-linear-gradient(#fff3e9 0 29px, #e9c8a9 29px 30px); }
    </style>
    <div id="shadow-panel" role="region" tabindex="0" aria-label="Shadow scroll panel">
      <div class="content">Shadow top sentinel. Click here, then use arrow keys.
        <span style="display:inline-block;margin-left:600px">Shadow right sentinel</span>
        <p style="margin-top:300px">Shadow bottom sentinel</p>
      </div>
    </div>`;
  trackPanel(shadow.getElementById('shadow-panel'), 'shadow-position', 'Shadow');
  document.getElementById('add-dynamic').addEventListener('click', event => {
    const panel = document.createElement('div');
    panel.id = 'dynamic-panel';
    panel.className = 'scroll-panel';
    panel.tabIndex = 0;
    panel.setAttribute('role', 'region');
    panel.setAttribute('aria-label', 'Dynamic scroll panel');
    panel.innerHTML = '<div class="panel-content">Dynamic top sentinel. Added after page load.<span class="panel-right">Dynamic right sentinel</span><p class="panel-bottom">Dynamic bottom sentinel</p></div>';
    document.getElementById('dynamic-target').appendChild(panel);
    trackPanel(panel, 'dynamic-position', 'Dynamic');
    event.currentTarget.disabled = true;
    panel.focus({ preventScroll: true });
  });
  updateWindowPosition();
</script>"""


def scrollbar_frame_body() -> str:
    return r"""
<style>
  :root { color-scheme: light; scrollbar-color: #ff2020 #ffd8d8; scrollbar-width: auto; }
  html { overflow: scroll; }
  body { max-width: none; margin: 0; padding: 6px; font-size: 11px; color: #202020; background: #f7fff6; }
  body > h1 { margin: 0; font-size: 13px; line-height: 1.2; }
  body > p { margin: 2px 0; font-size: 9px; }
  *::-webkit-scrollbar { width: 18px; height: 18px; background: #ffd8d8; }
  *::-webkit-scrollbar-thumb { background: #ff2020; border: 2px solid #ffd8d8; }
  *::-webkit-scrollbar-corner { background: #ff8080; }
  output { font-size: 10px; line-height: 1.4; }
  #frame-panel { box-sizing: border-box; width: 100%; height: 50px; overflow: scroll; border: 2px solid #5a8c5a; scrollbar-color: #ff2020 #ffd8d8; scrollbar-width: auto; }
  #frame-panel:focus { outline: 2px solid #3264e8; }
  #frame-panel > div { width: 900px; height: 360px; background: repeating-linear-gradient(#e7f5e7 0 24px, #afceaf 24px 25px); }
  .frame-spacer { width: 1050px; height: 700px; padding-top: 16px; }
</style>
<output id="frame-position" aria-live="polite">Frame x: 0 y: 0</output>
<div id="frame-panel" role="region" tabindex="0" aria-label="Iframe nested scroll panel">
  <div>Iframe nested top sentinel<span style="display:inline-block;margin-left:700px">Iframe nested right sentinel</span><p style="margin-top:260px">Iframe nested bottom sentinel</p></div>
</div>
<output id="frame-panel-position" aria-live="polite">Iframe nested x: 0 y: 0</output>
<div class="frame-spacer">Iframe page scrolling area</div>
<p tabindex="0">Iframe page bottom sentinel</p>
<script>
  const frameOutput = document.getElementById('frame-position');
  window.addEventListener('scroll', () => {
    frameOutput.textContent = `Frame x: ${Math.round(window.scrollX)} y: ${Math.round(window.scrollY)}`;
  }, { passive: true });
  const framePanel = document.getElementById('frame-panel');
  framePanel.addEventListener('scroll', () => {
    document.getElementById('frame-panel-position').textContent = `Iframe nested x: ${Math.round(framePanel.scrollLeft)} y: ${Math.round(framePanel.scrollTop)}`;
  }, { passive: true });
</script>"""


def web_compatibility_body() -> str:
    return r"""
<section aria-label="Fullscreen verification">
  <h2>Element fullscreen</h2>
  <p>Click the button. The colored panel should fill the screen; press Esc to return.</p>
  <div id="fullscreen-target" style="padding:24px;border-radius:12px;background:#3264e8;color:white">Fullscreen panel</div>
  <button id="enter-fullscreen">Enter fullscreen</button>
  <output id="fullscreen-status" aria-live="polite"></output>
</section>
<section aria-label="Popup blocking verification">
  <h2>Popup blocking</h2>
  <p>This page tried to open a tab on load. No new tab should have appeared.</p>
  <output id="automatic-popup-status" aria-live="polite"></output>
  <button id="open-popup">Open tab from click</button>
  <p><small>The click opens /popup in a new tab, which can close itself.</small></p>
</section>
<script>
  const fullscreenStatus = document.getElementById('fullscreen-status');
  fullscreenStatus.textContent = `Fullscreen API enabled: ${document.fullscreenEnabled}`;
  document.getElementById('enter-fullscreen').addEventListener('click', () => {
    document.getElementById('fullscreen-target').requestFullscreen()
      .catch(error => { fullscreenStatus.textContent = `Fullscreen failed: ${error.message}`; });
  });
  document.addEventListener('fullscreenchange', () => {
    fullscreenStatus.textContent = document.fullscreenElement ? 'In fullscreen' : 'Left fullscreen';
  });
  const automatic = window.open('/popup', '_blank');
  document.getElementById('automatic-popup-status').textContent =
    automatic ? 'Automatic popup was allowed (unexpected)' : 'Automatic popup was blocked';
  document.getElementById('open-popup').addEventListener('click', () => window.open('/popup', '_blank'));
</script>"""


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "NousBrowserFixture/1.0"

    def send_download_fixture(self, route: str) -> None:
        status = 200
        headers = {}
        content_type = "text/plain; charset=utf-8"
        if route in ("/downloads", "/downloads/"):
            payload = page("Download Save Panel", downloads_body()).encode("utf-8")
            content_type = "text/html; charset=utf-8"
            headers["Set-Cookie"] = (
                f"{DOWNLOAD_COOKIE_NAME}={DOWNLOAD_COOKIE_VALUE}; Path=/downloads; HttpOnly; SameSite=Lax"
            )
        elif route == "/downloads/payload.txt":
            payload = DOWNLOAD_PAYLOAD
        elif route == "/downloads/attachment":
            payload = DOWNLOAD_PAYLOAD
            headers["Content-Disposition"] = 'attachment; filename="attachment-fixture.txt"'
        elif route == "/downloads/protected":
            jar = cookies.SimpleCookie()
            try:
                jar.load(self.headers.get("Cookie", ""))
            except cookies.CookieError:
                pass
            token = jar.get(DOWNLOAD_COOKIE_NAME)
            if token is not None and token.value == DOWNLOAD_COOKIE_VALUE:
                payload = b"Nous authenticated download fixture\n"
                headers["Content-Disposition"] = 'attachment; filename="authenticated-fixture.txt"'
                content_type = "application/octet-stream"
            else:
                status = 401
                payload = b"Synthetic download session missing; open /downloads first.\n"
        elif route == "/downloads/interrupted":
            payload = b"Deliberately incomplete download.\n"
            headers["Content-Disposition"] = 'attachment; filename="interrupted-fixture.txt"'
            headers["Content-Length"] = "1000000"
            headers["Connection"] = "close"
            self.close_connection = True
        elif route == "/downloads/image.png":
            payload = DOWNLOAD_IMAGE
            content_type = "image/png"
        elif route == "/downloads/audio.wav":
            payload = DOWNLOAD_AUDIO
            content_type = "audio/wav"
            headers["Accept-Ranges"] = "bytes"
            # WebKit can probe native media with Range: bytes=0-1 before playback.
            byte_range = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
            if byte_range and any(byte_range.groups()):
                first, last = byte_range.groups()
                length = len(payload)
                start = int(first) if first else max(0, length - int(last))
                end = min(int(last), length - 1) if first and last else length - 1
                if start >= length or start > end:
                    status = 416
                    headers["Content-Range"] = f"bytes */{length}"
                    payload = b""
                else:
                    status = 206
                    headers["Content-Range"] = f"bytes {start}-{end}/{length}"
                    payload = payload[start:end + 1]
        else:
            self.send_html("Not found", "<p>Unknown download fixture route.</p>", status=404)
            return

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", headers.pop("Content-Length", str(len(payload))))
        self.send_header("Cache-Control", "no-store")
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(payload)
            self.wfile.flush()
            if route == "/downloads/interrupted":
                # Leave time to accept Save/Replace before the deliberate EOF.
                # HTTP-only fixture checks can use ?delay=0 to avoid the wait.
                try:
                    delay = float(parse_qs(urlsplit(self.path).query).get("delay", ["20"])[0])
                except ValueError:
                    delay = 20
                time.sleep(max(0, min(delay, 60)))
        except (BrokenPipeError, ConnectionResetError):
            pass  # Choosing Cancel may close the download connection.

    def send_html(self, title: str, body: str, status: int = 200, head: str = "") -> None:
        encoded = page(title, body, head).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def is_signed_in(self) -> bool:
        jar = cookies.SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
        except cookies.CookieError:
            return False
        token = jar.get(COOKIE_NAME)
        return token is not None and token.value == COOKIE_VALUE

    def redirect_with_cookie(self, cookie: str) -> None:
        self.send_response(303)
        self.send_header("Location", "/account")
        self.send_header("Set-Cookie", cookie)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        route = urlsplit(self.path).path
        if route == "/":
            self.send_html(
                "Browser Test",
                """<nav aria-label="Browser features">
<a href="/next">Next Page</a>
<a href="/popup" target="_blank" rel="opener">New Window</a>
<a href="/download" download>Download sample.txt</a>
<a href="/downloads">Download Save Panel</a>
<a href="/scrollbars">Scrollbar Test</a>
<a href="/favicon-test">Favicon Primary</a>
<a href="/favicon-test-second">Favicon Secondary</a>
<a href="/browser-profile">Browser Profile</a>
<a href="/web-compatibility">Fullscreen and Popups</a>
</nav>
<section aria-label="Synthetic login">
  <h2>Cookie persistence</h2>
  <p>This fake login sets one persistent HttpOnly cookie for localhost.</p>
  <a href="/login">Sign in to test account</a>
</section>"""
                + storage_form(),
            )
        elif route == "/downloads" or route.startswith("/downloads/"):
            self.send_download_fixture(route)
        elif route == "/login":
            expires = format_datetime(datetime.now(timezone.utc) + timedelta(days=365), usegmt=True)
            self.redirect_with_cookie(
                f"{COOKIE_NAME}={COOKIE_VALUE}; Path=/; Max-Age=31536000; "
                f"Expires={expires}; HttpOnly; SameSite=Lax"
            )
        elif route == "/logout":
            self.redirect_with_cookie(
                f"{COOKIE_NAME}=; Path=/; Max-Age=0; "
                "Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax"
            )
        elif route == "/account":
            status = "Signed in" if self.is_signed_in() else "Signed out"
            action = '<a href="/logout">Sign out of test account</a>' if self.is_signed_in() else '<a href="/login">Sign in to test account</a>'
            self.send_html(
                "Account",
                f'<section><h2 id="account-status">{status}</h2><p>{action}</p>'
                '<p id="cookie-visibility"></p></section>'
                '<script>document.getElementById("cookie-visibility").textContent = '
                '"Document cookie: " + (document.cookie || "empty (session is HttpOnly)");</script>'
                + storage_form(),
            )
        elif route == "/next":
            self.send_html(
                "Next Page",
                '<p id="navigation-result">Navigation succeeded.</p><a href="/">Return to Browser Test</a>',
            )
        elif route == "/popup":
            self.send_html(
                "Popup Page",
                '<p id="popup-result">New-window link opened successfully.</p>'
                '<button onclick="window.close()">Close this tab</button>',
            )
        elif route == "/scrollbars":
            self.send_html("Scrollbar Test", scrollbar_test_body())
        elif route == "/scrollbars-frame":
            self.send_html("Iframe scroll test", scrollbar_frame_body())
        elif route == "/web-compatibility":
            self.send_html("Fullscreen and Popups", web_compatibility_body())
        elif route == "/browser-profile":
            self.send_html("Browser Profile", browser_profile_body(self.headers.get("User-Agent", "(not supplied)")))
        elif route == "/favicon-test":
            self.send_html(
                "Favicon Primary",
                '<section aria-label="Primary favicon verification"><h2>Blue F favicon</h2>'
                '<p>This page explicitly declares the blue circular F icon. The tab should show the blue F instead of the gray G fallback.</p>'
                '<img src="/favicon-icons/primary.png" width="64" height="64" alt="Expected blue F favicon">'
                '<p><a href="/favicon-test-second">Open secondary favicon page</a></p></section>',
                head='<link id="fixture-favicon" rel="icon" type="image/png" sizes="32x32" href="/favicon-icons/primary.png">',
            )
        elif route == "/favicon-test-second":
            self.send_html(
                "Favicon Secondary",
                '<section aria-label="Secondary favicon verification"><h2>Orange S favicon</h2>'
                '<p>This page declares a different icon on the same origin. The tab should change to the orange S.</p>'
                '<img src="/favicon-icons/secondary.png" width="64" height="64" alt="Expected orange S favicon">'
                '<p><a href="/favicon-test">Return to primary favicon page</a></p></section>',
                head='<link id="fixture-favicon" rel="icon" type="image/png" sizes="32x32" href="/favicon-icons/secondary.png">',
            )
        elif route == "/favicon-dynamic":
            self.send_html(
                "Dynamic Document Icon",
                '''<section><h2 id="document-icon">⭐</h2>
                <p>A document updates its favicon after the page load. Its tab must show the star, not the original blue F.</p>
                <button id="star" onclick="setIcon('⭐')">Star icon</button>
                <button id="moon" onclick="setIcon('🌙')">Moon icon</button>
                <button id="blob" onclick="setIcon('🌿', true)">Blob leaf icon</button>
                <button id="remove" onclick="document.querySelector('#fixture-favicon').remove();document.querySelector('#document-icon').textContent='Default blue F'">Remove document icon</button>
                <button id="route" onclick="history.pushState({}, '', '/favicon-dynamic#second');setIcon('💜');document.title='Second Document'">SPA second document</button>
                <p><a href="/favicon-test-second" target="_blank">Open another document on this site</a></p>
                <output id="icon-status">Waiting for document data…</output></section>
                <script>
                function setIcon(emoji, blob=false) {
                    let link = document.querySelector('#fixture-favicon');
                    if (!link) { link=document.createElement('link');link.id='fixture-favicon';link.rel='icon';document.head.append(link); }
                    const svg='<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><text y="54" font-size="56">'+emoji+'</text></svg>';
                    link.type='image/svg+xml';
                    link.href=blob?URL.createObjectURL(new Blob([svg],{type:'image/svg+xml'})):'data:image/svg+xml,'+encodeURIComponent(svg);
                    document.querySelector('#document-icon').textContent=emoji;
                    document.querySelector('#icon-status').textContent='Current document favicon: '+emoji;
                }
                window.addEventListener('load',()=>setTimeout(()=>setIcon('⭐'),700));
                </script>''',
                head='<link rel="icon" type="image/png" href="/favicon-icons/primary.png">',
            )
        elif route in FAVICON_FIXTURES:
            payload = FAVICON_FIXTURES[route]
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "public, max-age=3600")
            self.end_headers()
            self.wfile.write(payload)
        elif route == "/download":
            payload = b"Nous Browser download fixture\nSynthetic local development data only.\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Disposition", 'attachment; filename="sample.txt"')
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.send_html("Not found", "<p>Unknown fixture route.</p>", status=404)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), FixtureHandler)
    print(f"Local browser test fixture: http://127.0.0.1:{args.port}/", flush=True)
    print("Synthetic data only. Stop with Control-C.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
