# External application links — 2026-11-13

## Scope and findings

NousCore 156.0.8078.80, app 1.4.18 (74). This is separate from the file chooser and website permission fixes.

Chrome attaches `ExternalProtocolObserver` through `TabFeatures`, not `TabHelpers`. Nous attaches the latter but did not create the former. An external protocol attempt consumes Chrome’s process-wide anti-flood allowance; without the observer, later real page interactions never rearm it. This explains why a first attempt can work while a subsequent retry appears inert.

The fix gives each Nous `WebContents` a standard Chrome observer. The observer is removed before releasing its WebContents. Chrome still decides whether to block, prompt, remember a decision, or launch. No website/scheme whitelist, unconditional allowance, direct OS launch, or authentication callback replay is introduced.

A second path, `OpenURLFromTab` with a new browsing context, previously forwarded only a URL to the Swift host, which accepts web URLs and dropped external protocols. For a verified live top-document initiator and a user gesture, external schemes now keep the original `OpenURLParams` through Chrome navigation. Web-registered protocols, internal schemes, sandboxed subframes, and unknown initiators are not routed through this path. Removing this branch in an intermediate comparison build reproduced the missing `target=_blank` confirmation; it is necessary independently of the observer fix.

Chrome’s post-launch empty-tab cleanup normally looks for a Chrome TabStripModel. Nous owns its own tab strip, so an embedder notification now runs only after Chrome dispatches an approved external launch. It closes only a Nous-owned initial-navigation tab with another live tab in the same window, asynchronously and with a fresh check. Cancelled or blocked requests never trigger that notification.

## Native regression evidence

Local fixture: `Tests/Fixtures/external_protocol.html`, served only at `127.0.0.1:18883`. A temporary local receiver accepts only the synthetic `nous-protocol-qa://fixture/...` URLs and records receipt locally. Its data contains no authentication payloads.

| Check | Observation |
| --- | --- |
| Pre-fix: first real mouse click, Cancel, then second real mouse click | First confirmation visible; after Cancel, second click logged but no confirmation (01:48 UTC). |
| Fixed: Cancel and click again | Correct-origin Chrome confirmation reappeared. |
| Fixed: valid link after unregistered scheme | Confirmation reappeared; accepted link reached receiver. |
| Fixed: receiver running / receiver quit | Both warm delivery and cold launch produced exactly one recorded URL. |
| Fixed: external `target=_blank` | Correct-origin native confirmation; acceptance delivered `/new-tab`. Source document remained intact. |
| Fixed: `window.open` from a click | Child tab held the native confirmation; selecting it exposed the dialog and acceptance delivered `/window-open`. Do not mistake a background tab’s pending dialog for lost navigation. |
| Single click requests twice | Only first request prompted; delayed second request did not launch or prompt again. Receiver count unchanged after Cancel. |
| Unregistered and denied (`applescript:` with no script) schemes | No application launch. |
| Sandboxed iframe, same-frame and `_blank` links | No app/dialog/tab created from either restricted link. |
| Ordinary HTTPS `_blank` | Example Domain loaded in a new tab. |

Protocol tests must use real pointer/keyboard input. An accessibility “press link” action produced a trusted DOM click but did not deliver the same native interaction observer notification; it is not a valid substitute for this anti-flood regression.

## Empty auxiliary-tab cleanup

On the final cleanup implementation, the fixture began with six tabs. Clicking `window.open` created a seventh tab; selecting it showed the native confirmation. Acceptance delivered exactly one `/window-open` URL (receiver count 5 to 6, 02:05 UTC) and returned the tab count to six. The source fixture and existing tabs remained.

## Boundaries

These checks verify the browser’s protocol confirmation and OS handoff, not a successful GlobalProtect VPN connection. The earlier GlobalProtect callback had expired. No old SAML callback or credential was replayed. A real end-to-end login requires a fresh authentication initiated by the user.

No remembered external-app grant was created during QA. Production installation and cleanup verification are recorded below.

## Final combined build

The `release-check` preview includes all three changes. Final native check: `target=_blank` produced Chrome’s confirmation, Cancel left the receiver count unchanged, returning to the source and clicking again prompted again. Accept delivered `/new-tab` exactly once (receiver count 6 to 7) and removed only that accepted auxiliary tab. Existing source and cancelled tabs remained. The preview and receiver were normally quit.

The production package is `.build/external-protocol-qa/release/Nous Browser.app`, signed with the existing local certificate without a Keychain interaction. Strict deep signature validation passed. After explicit restart approval, this package was installed at `/Applications/Nous Browser.app` on 2026-11-13 at 10:12:51 local time. The previous app is preserved as `previous-installed.bundle` under `.build/external-protocol-qa/backups/20261113-101251`. No GitHub publication is part of this task.

Artifact equivalence: preview and production engines have UUID `4C4C4432-5555-3144-A1B9-03F3E4A5DD8A`; all 39 code/data sections match by SHA-256 excluding signature bytes. Both app bundles passed deep strict signature validation.

## Installed-app acceptance

The installed framework SHA-256 matches the validated package: `923a428b4308a163b5c77e41406e6cff899cc82792afd4c4123d7dce60866c69`. A normal quit and relaunch restored all 139 tab entries across the original three windows (88 / 26 / 25), with identical stable tab IDs and selected tabs. The original authenticated Zoom Canvas document loaded and reported synced from cloud. No Keychain password prompt appeared.

In a separate temporary window of the installed app, a real pointer click showed the correct-origin confirmation. Escape cancelled it; a second real click showed the confirmation again. Accepting cold-launched the local receiver, which recorded exactly one matching `/same-tab` URL (count 7 to 8, 02:17 UTC).

The temporary window was closed, the original active window and expanded sidebar were restored, and the three original windows / 139 tabs were rechecked. The test receiver was normally quit and its exact test bundle unregistered; the loopback fixture server was stopped.
