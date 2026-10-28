# 1.1.7 image clipboard compatibility

Date: 2026-10-28. Version 1.1.7 (47), macOS 26, Apple Silicon.

## Reproduction and cause

The reported Google Images result showed the Claude Duet icon. Its official source is an SVG, 1300 × 1300, published at `https://assets.claude.com/9273e22b909074c1c2d42ca3514a239623f8af40.svg` and linked from the Claude Duet article.

With the previous native Copy Image action, copying this SVG left the pasteboard change count unchanged. A second, simple SVG reproduced the same result. Pasting therefore retained a previous image or produced no new image. Ordinary PNG copying changed the pasteboard normally. This establishes a copy failure for the tested SVGs, rather than a receiving-app rejection.

## Change

Copy Image first invokes the original WebKit action with its original target and represented object. If it has not changed the clipboard after a short delay, Nous obtains the clicked image through the page's WebKit session and writes alpha-preserving PNG and TIFF representations. SVG rasterization uses explicit sRGB and bounded dimensions.

The fallback is cancelled when the page changes, its view is invalidated, a newer copy starts, or another clipboard write takes place. Only the Copy Image item is wrapped; Copy Link, Copy Subject and ordinary Copy retain their existing actions. Failures use localized messages. There is no success toast.

Downloads use a private temporary directory and are bounded by time, input size and decoded pixel limits; files are cleaned up after success, failure or cancellation.

## Automated and build verification

- `swift test --no-parallel`: 318 tests across 46 suites, 313 passed, five existing password-event-loop tests skipped, zero failures. Log: `.build/copy-image47/all-tests.log`.
- Targeted clipboard/menu coverage: 36 tests passed. Coverage includes SVG and raster decoding, dimensions, alpha and pixel values, PNG/TIFF output, MIME and size rejection, native action forwarding, original sender preservation, clipboard/page invalidation, and competing copy attempts.
- Release build and strict code signature verification passed. Log: `.build/copy-image47/release-build.log`.
- The installed and built main executables match: SHA-256 `5368d6a16d345d20c0bf3f9821f1190b62ea60a4279f61e5dc79ce7294535496`.

## Installed application acceptance

All final checks used `/Applications/Nous Browser.app`, version 1.1.7 (47). Copy was triggered through the actual native right-click menu, and paste through Command-V.

| Check | Observed result |
| --- | --- |
| Copy the official Claude Duet SVG | Clipboard contains 1300 × 1300 PNG (89,849 bytes) and TIFF (91,806 bytes). |
| Paste into a local contenteditable fixture | Correct Claude Duet icon appears; the paste event receives an image file. |
| Paste into Zoom Slides | Correct image appears as an editable image object in a dedicated QA presentation. After reloading the presentation, the image remains. |
| Paste into native Zoom self-chat draft | Correct image preview appears in the unsent draft. The draft was then cleared and its empty state verified; no message was sent. |
| Copy ordinary PNG after installing the fix | Native clipboard output remains available, including a TIFF with the original 1254 × 1254 dimensions. |

Local evidence: `.build/copy-image47/installed-slides-paste.jpg` and `.build/copy-image47/installed-zoom-paste.jpg`. The dedicated presentation is named **Nous 1.1.7 — 图片复制验收** and was retained for inspection.

## Cleanup and scope

The QA browser window, separate QA application and local fixture server were closed. The two original work windows remain; all ten original tab IDs, their order and each selected tab match the pre-install session backup.

This validates the reported SVG and both named paste destinations. It does not claim live coverage of every image format, third-party clipboard consumer, cross-origin iframe, or authenticated image endpoint. Existing unit tests and the real UI checks are recorded separately above. This turn installed the local build; no 1.1.7 GitHub release was published.
