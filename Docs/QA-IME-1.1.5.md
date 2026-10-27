# 1.1.5 Chinese IME / Zoom Slides investigation

Date: 2026-10-27. This records the source evidence and regression checks separately from installed-app acceptance.

## Cause and scope

The user reported an extra newline when Return confirms the raw English text of an active Chinese composition in Zoom Slides. In installed 1.1.4, a local textarea event trace captured `compositionend` followed by the confirming `keydown` (`key=Enter`, `keyCode=229`, `isComposing=false`) and `keyup` (`keyCode=13`). The ordinary textarea committed the text without a newline. This isolates the extra editing action to the site's handling of that sequence, rather than an unconditional duplicate Return from Nous.

The public Zoom Slides frontend provides the missing connection:

1. `office.f7e118f3.js`, module `724454`, reads `window.navigator.userAgent`. Its Safari branches require `Version/...Safari` or `AppleWebKit/...Zoom`. A native WKWebView UA with only the `NousBrowser` suffix matches neither. Module `275863` re-exports this detector as `cO`.
2. `21762.688261fa.js`, module `955295`, creates the Slides editor's hidden textarea and uses that detector. Its `compositionend` handler records the time and clears `isCompositing`. The `keydown` handler suppresses the next near-composition event only when `browser.safari` is true:

   ```js
   this.isCompositing ||
     (browser.safari && performance.now() - this.compositionendTime < 50) ||
     this.delegate?.onTextInputKeyDown(event);
   ```

3. `95172.90f7745c.js` forwards that callback to the text body view. Its Enter branch calls `handleEnterInEmptyList(shift)` or `openNewLine(shift)`.

Thus the default Nous UA disables the editor's existing WebKit composition safeguard. This code path matches the observed event order and the user's symptom. The installed-app user acceptance below confirms the expected Return behavior in an actual Zoom Slides document.

The change uses the existing Safari compatibility identity for exact HTTPS hosts `slides.zoom.us`, `slides.zoom.com`, and `present.zoom.us`, with no credentials and the default HTTPS port. Public requests verified that the latter two redirect to `slides.zoom.us`. Other Zoom destinations retain the existing native navigation policy. The identity retains the system-probed platform and WebKit engine plus the Nous version. Existing Google rules remain unchanged. No keyboard events, composition data, native editing APIs, or website handlers are replaced.

## Public source evidence

All bundles were discovered from the unauthenticated public [Zoom Slides root](https://slides.zoom.us/). The source investigation did not read private documents or account data. The editor initialization is in the same document; this evidence does not require broadening compatibility to an iframe host.

| Bundle | Relevant module / purpose | SHA-256 of downloaded bytes |
| --- | --- | --- |
| [office.f7e118f3.js](https://st1.zoom.us/zoom-docs/release/web/lynx/editor/assets/office.f7e118f3.js) | `724454`, `275863`: UA detector | `78a8f7f376b9e2a2fc675e19a54c8e2ccb6fb1070b9fd380bc868833dab24e9a` |
| [21762.688261fa.js](https://st1.zoom.us/zoom-docs/release/web/lynx/editor/assets/21762.688261fa.js) | `955295`: hidden textarea and Safari composition guard | `a6f061b4b32b50cdb019514941da1f0b7b4c18ab9443a94ba409296f785d9c81` |
| [95172.90f7745c.js](https://st1.zoom.us/zoom-docs/release/web/lynx/editor/assets/95172.90f7745c.js) | Text body Enter → `openNewLine` | `1ff6d1f63bf7d1384a15dce174e929259ab0a6c48b2a941fbd6cc7a5a328d897` |
| [3696.04fb2d9f.js](https://st1.zoom.us/zoom-docs/release/web/lynx/editor/assets/3696.04fb2d9f.js) | `296306`: Slides editor initialization | `43cfa7cfe80be566fafd4e1f6506542313d5a3d9148ac5d3a61fbd430d9f7904` |

Related upstream evidence: [WebKit bug 324380](https://bugs.webkit.org/show_bug.cgi?id=324380) describes this composition/keyboard event ordering. The targeted fix enables Zoom's own safeguard rather than adding a browser-wide Enter suppression timer.

## Regression verification

`BrowserUserAgentTests` covers:

- Exact host / HTTPS / credentials / port boundaries, aliases, unrelated Zoom products, deceptive hostnames, and nil URLs.
- Cold entry into Slides, reuse across Slides and Google, and clearing when navigating to another Zoom site or Google Accounts.
- Popup `applyKnownIdentity` boundaries and rejecting an old asynchronous identity result after leaving Slides.
- Real WKWebView `navigator.userAgent` after navigation-policy resolution, using local HTML origins without contacting accounts; Zoom's actual Safari detection patterns evaluate true only for the intended destinations.
- The observed Zoom composition guard evaluated against that real Navigator: composition-active and immediate confirming events are suppressed in the Safari branch, while a subsequent ordinary Enter is passed through. This deterministic site-policy check does not simulate the native input method.
- Existing Google capability, identity construction, inherited configuration, cancellation, and native fallback behavior.

Focused test result: 19 `BrowserUserAgentTests` passed in the final rerun, including the real Navigator and composition-guard assertions. Log: `.build/ime45-user-agent-tests.log`.

## Installed acceptance criteria

Use the installed candidate in Zoom Slides with real Chinese IME composition. Verify Return commits raw English without adding a newline, a subsequent Return adds exactly one newline, Space confirms a Chinese candidate, Shift-Return behaves normally after composition, and ordinary typing, deletion, selection, undo/redo, and clipboard editing still work. Repeat address/search input composition checks. Synthetic keyboard events and a passing UA test do not establish this live result.

## Native address and Find input audit

The native address palette and Find field were also exercised using actual NSTextField field editors hosted in NSHostingView. Before the fix, a SwiftUI refresh while the field editor owned marked text could clear the composition, and a field-editor Return command could invoke the browser action while marked text remained. These are native text-client integration findings, separate from the user's physical IME trace in the webpage.

Both fields now leave marked text untouched during SwiftUI value synchronization and return composing commands to AppKit. Ten regression tests cover marked range, text and selection preservation, real native change notifications updating the binding, Return/Escape/candidate arrows during composition, and exactly one browser action on Return after committed text. No application-wide input event filtering was added.

## Build and automated checks

- Full serial suite: 289 tests across 43 suites; 284 passed, five existing password event-loop cases skipped, zero failures.
- Final focused compatibility rerun after the Zoom guard assertion: 19 passed. Native text composition: 10 passed.
- Release build 1.1.5 (45) completed; strict application signature verification passed.
- Installed Zoom Slides composition-confirmation acceptance passed by direct user testing, as recorded below. The automated results alone are not treated as that proof.

## Installation and live editing checks

Installed `/Applications/Nous Browser.app` version 1.1.5 (45) after a normal application quit. The main executable and bundled MCP helper match the packaged build byte for byte; strict signature validation passed. Session files were backed up after quitting and were identical to their backups immediately after restart, before creating a separate QA window.

A separate synthetic-content Zoom Slides presentation was created for acceptance (no edits to existing work documents). On the installed build, native UI checks confirmed:

- Ordinary Return produced one new line, and Shift-Return produced one additional line.
- Command-Left and Command-Right moved within the active text, without navigating away from the editor.
- Command-Z removed the test character, and Command-Shift-Z restored it.
- Select-all, deletion and pasting synthetic text worked in the Slides text box.

On 2026-10-27 the user completed the installed-app test with their actual Chinese input method and explicitly confirmed: Return commits the composing English without a newline; the subsequent ordinary Return inserts the newline. The test requested composing `hello` and then `abc`, confirming each with Return so they remain on the same line, followed by a separate Return. This closes the reported extra-newline acceptance case.

Automated typing did not activate the system IME candidate state and is not counted as that proof. Space-to-confirm Chinese candidates and broader input-method coverage were not independently validated here. Local evidence: `.build/ime45-slides-ordinary-input.png`, `.build/ime45-slides-ready.png`, plus the user's explicit acceptance in this task.
