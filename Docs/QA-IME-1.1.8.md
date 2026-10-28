# 1.1.8 Zoom Slides canvas IME Return

Date: 2026-10-28. Development machine: macOS 26.7.2 (25G320), Apple Silicon.

## Report and evidence

The user reported that Return again committed Latin text from the Chinese input method and added an unwanted newline in a Zoom Slides canvas text object. The expected contract is unchanged: Return confirms an active composition; the next independent Return inserts a newline.

Version 1.1.5 enabled the site's Safari identity branch. That earlier release was accepted through a real canvas title-box test, so this recurrence is not described as an entirely untested canvas implementation. The latest work window remains on an already-covered `slides.zoom.us` origin.

The public editor and detector bundles referenced in [1.1.5 QA](QA-IME-1.1.5.md) were fetched again; their hashes match the recorded versions. The editor records composition-end time before synchronous text updates, flush and reposition calls. Its key handler then relies on a Safari-specific 50 ms grace period and does not check the confirming event's `keyCode === 229` or `isComposing`. Synchronous work lasting more than 50 ms can therefore exhaust that protection. A real WebKit fixture with a 100 ms composition-end callback reproduced this weakness. The precise event timing of the user's latest screenshot was not captured; the complexity-dependent explanation remains a source-supported hypothesis, not a measured trace of their document.

[WebKit issue 324380](https://bugs.webkit.org/show_bug.cgi?id=324380) describes composition-end arriving before its confirming Enter with `isComposing=false`. Its later diagnostic discussion also identifies the need to cover the physical key sequence through keyup without cancelling native default behavior. The earlier local Nous IME trace had the same Enter-229/key-up-13 sequence.

## Change

An isolated-world, document-start listener applies only to HTTPS `slides.zoom.us`, `slides.zoom.com` and `present.zoom.us`, with the default HTTPS port and no URL credentials. It operates on editable targets, including the canvas's hidden textarea and open Shadow DOM text controls.

A Return bearing the input-method marker (`keyCode === 229` or `isComposing`) is prevented from reaching the site's extra keyboard command handlers. Matching keypress, held repeats and keyup belong to the same physical confirmation. The listener never calls `preventDefault`, never changes text, and leaves composition, beforeinput and input events untouched. It clears its state at release, focus loss, pagehide or the next independent keydown. No elapsed-time gate is used. The existing site identity and native address/Find input handling remain in place.

## Automated evidence

Eight targeted real-WKWebView tests pass. They install the actual isolated-world script and exercise page-world event handlers, rather than testing only a copied predicate:

- A delayed composition-confirmation sequence causes a newline without the guard, and no newline with it. The following ordinary Return still reaches the editor.
- All three keyboard phases retain `defaultPrevented=false` while the composing confirmation is withheld from page handlers.
- Composition data and beforeinput/input events remain delivered and uncancelled.
- Space-to-confirm followed immediately by ordinary Enter is permitted.
- Held repeats, missing release, changed targets, focus loss and pagehide do not suppress a later independent Return.
- Ordinary shortcuts, candidate arrows, noneditable controls, contenteditable and Shadow DOM targets are covered.
- Origin boundaries and inherited-configuration idempotence are covered.

These are synthetic DOM event tests in real WebKit. They establish event propagation and command suppression, not a physical input method's commit behavior. Log: `.build/ime48-compatibility-tests.log`.

## Installed acceptance

`swift test --no-parallel` passed after integration: 326 tests across 47 suites, 321 passed and five pre-existing password-event-loop cases skipped, zero failures. Log: `.build/ime48-all-tests-final.log`. An earlier integration run exposed the expected script-count assertion changing from two to three; that assertion now also explicitly checks there is exactly one IME listener, and the full suite was rerun successfully.

The release build completed, then version 1.1.8 (48) was installed at `/Applications/Nous Browser.app` after a normal application quit. The existing Slides work document showed **Synced from cloud** before quitting. The installed executable matches the built executable: SHA-256 `07cd7acad68329a58149b3b8e1c4015184c504f9126105e48d71e8c42cbbcc05`. Strict signature verification passed. Log: `.build/ime48-release-build.log`.

On the installed build, an independent canvas text object in the QA presentation accepted ordinary typing, select-all/deletion, Return and Shift-Return. The visible result was three separate lines (`normal`, `next`, `third`); the text was cleared to leave an empty active editing target for the user's physical IME check.

On 2026-10-28 the user completed the physical Chinese input method check in the separate QA presentation's canvas text object and explicitly confirmed: **confirming the composition does not insert a newline; the next independent Return does**. The requested sequence was composing `hello` and `abc`, confirming each with Return so they remain on one line, then pressing a separate Return. This is direct user acceptance in installed 1.1.8 (48), separate from the synthetic event tests above.

Before cleanup the QA document showed **Saved to cloud**. The user had added work tabs to the QA window, so only the verified QA tab was closed; the window and its work tabs were retained. No existing work document was edited for this test.
