# Nous Browser 1.1.11 (51): regional Slides compatibility

## Confirmed coverage defect

The user reproduced IME Return committing Latin text and inserting an unwanted
newline in the slide canvas on `dg01slides.zoom.us`. Version 1.1.10's identity
policy and isolated-world IME guard independently allowed only `slides.zoom.us`,
`slides.zoom.com`, and `present.zoom.us`. Both excluded the actual regional host.
Earlier native acceptance on the main host did not establish regional coverage.

The fix centralizes the exact host set in `ZoomSlidesCompatibility`. It covers
the 27 entries published in `SLIDES_HOSTS` at https://dg01slides.zoom.us/ on
2026-10-28 plus the existing public `.com` alias. Unrelated Zoom services,
lookalike domains, non-HTTPS URLs, credentials, and nonstandard ports remain
excluded by the navigation identity policy. No broad wildcard or new IME timing
heuristic was added. Future published host changes still require reviewing this
explicit list.

## Automated evidence

- Before the fix, the real-WebKit event fixture passed on the main host and
  failed on `dg01slides`, `eu02slides`, and `sg01present` (9 failed assertions).
- After the fix, all 28 tests in `BrowserTextInputCompatibilityTests` and
  `BrowserUserAgentTests` passed.
- The tests exercise every allowed host in WebKit, confirm no page newline on
  the composition-confirming Return, and verify the subsequent ordinary Return
  remains available. They also cover composition events, Space/candidate keys,
  held keys, missing keyup, focus changes, contenteditable and shadow textarea.
- These synthetic DOM events are regression evidence, not native IME evidence.

## Native acceptance, 2026-10-28

With user authorization, quit the installed 1.1.10 normally after observing
“Saved to cloud”, then ran a separate 1.1.11 diagnostic bundle with the same
application identity. Original installed bundle was not overwritten. The five
tabs and logged-in regional Slides document were restored.

The user confirmed in the real slide canvas:

- IME confirmation keeps `helloabc` on one line; another Return inserts a newline.
- Dropping the PNG into the canvas now inserts the picture.

Temporary, local-only passive diagnostics observed trusted drop events containing
an `image/png` file of 328,767 bytes and a `video/mp4` file of 4,095,508 bytes.
The page canceled the default drop navigation in both cases. PNG insertion is
user-confirmed; video insertion/upload completion has not been explicitly
confirmed. No names, paths, file contents, credentials, or page text were logged.
The diagnostics were removed from source before preparing the release build.

## Scope and limits

The browser still delegates genuine file drags to WebKit and the website's own
drop handler. There is no Zoom-specific uploader, synthetic File injection, or
upload outside the website. The generic local PNG fixture already worked before
this change. The observed Slides success follows the identity correction and
app restart together; it does not by itself isolate every possible drag failure
or prove arbitrary file-type support on every website.

## Release-build handoff

Built the optimized 1.1.11 (51) bundle at `.build/release51/Nous Browser.app`,
verified its signature, and confirmed the diagnostic marker is absent from its
executable and the diagnostic flag is absent from its Info.plist. Normally quit
the diagnostic process after “Saved to cloud” and launched this clean bundle;
the regional document restored with “Synced from cloud”. The original installed
1.1.10 bundle remains untouched.

DMG and ZIP contents were unpacked/mounted and verified by the packaging script.
The updater feed was signed locally. These assets have not been published to
GitHub as part of this acceptance run.

- DMG SHA-256: `8c29de0ae24a387b4ae86761068f80e0dfc0786905c45a449134355671520a23`
- ZIP SHA-256: `28173c433b8cae23c2a17e5e53010d88d5a6421a8299f9f99f444757b3bae1c5`
