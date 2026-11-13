# Website permission prompt lifetime

## Findings

The existing Allow action calls Chromium `PermissionPrompt::Delegate::Accept`,
not `AcceptThisTime`. Chromium persists that decision in its profile content
settings, with its usual origin scope. The permission manager already finalizes
requests; an extra finalization or a parallel Nous grant cache would be incorrect.

There was a separate, reproducible lifetime defect: `NousPermissionPrompt`
reported `kDestroyPromptButKeepRequestPending` but did not close its NSAlert when
Chromium destroyed that prompt. The old sheet and its manager-bound callback
survived hiding the requesting tab. It could obstruct creation of the replacement
prompt, and its callback was not bound to the original prompt's lifetime.

The prompt now owns its individual `NBPageDialog`, invalidates its own weak
callback token before destruction, and closes only that sheet. Destroying the UI
does not dismiss the still-pending Chromium request. Real user decisions retain
Chrome's existing persistence behavior. No origin sharing or automatic grants
were added.

This defect is established by the before/after test below. It is not evidence
that every reported repeat prompt after refresh has the same cause.

## Regression harness

Serve `Tests/Fixtures` at `http://127.0.0.1:18881`. The separate preview bundle can
run the existing smoke harness with:

```
NOUS_CHROMIUM_SMOKE_BASE_URL=http://127.0.0.1:18881
NOUS_CHROMIUM_SMOKE_REPORT=/absolute/path/report.json
NOUS_CHROMIUM_PERMISSION_LIFECYCLE=1
```

The harness is restricted to the preview identity and loopback fixture. Click
the fixture's notification permission button. The harness hides its tab and
returns to it, checking that the old sheet closes and a distinct replacement
appears. Answer the replacement sheet. It then checks permission status after
reload and opening the same origin in a new tab. No decisions are injected by
the harness. The fixture sends no notifications and reads no clipboard contents,
camera, microphone, or geolocation data.

## Observed on 2026-11-12

| Check | Result |
| --- | --- |
| Original engine with the same regression harness | Failed: old permission sheet survived hiding its tab |
| Patched engine | Old sheet closed; a distinct replacement sheet appeared |
| Answer replacement with Don't Allow | State became `denied`; remained `denied` after reload and a new tab |
| Different origin (`localhost` instead of `127.0.0.1`) | Notification state remained `prompt`; other permissions also remained `prompt` |
| Normal preview quit and relaunch | Original origin still `denied`, different origin still `prompt` |
| Existing production Zoom Slides clipboard permission, before this patch | Stored as allow; new-tab and reload/right-click checks did not repeat the prompt |

The granted camera, microphone, location and clipboard paths were reviewed in
source, not separately exercised with real resources. The native persistence
test above used a notification **denial**, not an Allow action. macOS system
permissions, private-session lifetime, screen-sharing selection and distinct
website origins retain Chromium/system behavior.

## Installed verification

On 2026-11-12, after the user confirmed the documents were saved and Nous could
restart, the patched 1.4.18 (74) bundle replaced `/Applications/Nous Browser.app`.
The previous bundle was backed up under `.build/permission-qa/backups/20261112-201231/`
as a ZIP and a `.bundle` (not another registered `.app`). The installed bundle
passed strict deep signature verification; its engine hash matched the candidate.
The production candidate and tested preview also had matching engine code/data
sections. No Keychain password prompt appeared.

All three original windows, their selected tab IDs, and their tab counts
(87, 26, 25) were restored. A temporary window opened the existing Zoom Slides
document on `dg01slides.zoom.us`. Right-clicking the selected slide thumbnail
showed the normal menu without another permission sheet, including after a
reload and after closing/reopening the document in a new tab. The pre-existing
clipboard permission remained Allow. No document content was edited; the test
window was closed afterward.

This verifies reuse of the existing real-site clipboard grant in those flows.
It does not establish a new camera/microphone/location Allow decision or rule out
every intermittent repeated-prompt report. The source-reviewed persistence and
the independently reproduced stale-sheet defect remain separate findings.
