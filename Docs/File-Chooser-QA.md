# Native upload chooser regression

## Implementation

`NousTab` must forward both `WebContentsDelegate::RunFileChooser` and
`EnumerateDirectory` to Chrome's `FileSelectHelper`, just like
`BrowserWebContentsDelegate`. The base content delegate immediately cancels both
requests. Leaving these overrides out silently cancels attachment/upload requests
routed through these delegates, even though the renderer handles the input correctly.

Use the standard helper arguments. Do not bypass its folder confirmation, frame
lifetime checks, user-activation checks, accept filters, or native dialog policy.
The existing Nous native window and modal-dialog host supply the parent window.

## Repeatable native check

Serve `Tests/Fixtures` on loopback, then open `/file_chooser.html` in Nous and Chrome.
Click through the real UI: setting `input.files` with DevTools bypasses the missing
delegate and is not a regression test for this bug. All fixture reads are local;
there is no upload request.

Use synthetic text files, a PNG, and a folder containing a file and a nested file.
Check attachment buttons (hidden input), visible single/multiple inputs,
`showPicker()`, a label-triggered input, a cross-origin iframe, and folder upload.
Verify actual `File` bytes, not just whether a dialog appears. Cancel a second
selection and check that the previous selection remains. Invalid file types must
not enable Open under the selected type filter. Folder upload must retain Chrome's
confirmation and relative paths.

## Observed on 2026-11-12

Built against Chromium 156.0.8078.80 on macOS, using the current 1.4.18 worktree.

| Scenario | Observed result |
| --- | --- |
| Installed version before fix | Attachment button immediately delivered `cancel`; no dialog |
| Same attachment fixture in Chrome | Native file dialog opened; cancel returned normally |
| Fixed attachment button | Native dialog opened; two files returned, 37 and 28 bytes read |
| Reopen then cancel | Existing two files retained |
| Image/video accept filter | Text selection left Open disabled; PNG enabled Open and returned 68 readable bytes |
| `showPicker()` | Native dialog opened; cancel delivered normally |
| Folder upload | Native folder chooser, then Chrome's two-file confirmation; nested relative paths returned |
| Cross-origin iframe / single input | Native dialog opened; one 18-byte file returned and read |
| Installed fix: Gmail / Compose / Attach files | Native Open sheet appeared; cancel returned to the empty compose window; test draft discarded |
| Installed fix: Zoom Slides / Import files / local files | Native Open sheet appeared; cancel returned to Slides |
| Installed fix: Zoom Canvas / Create / Import / local files | Native Open sheet appeared; cancel returned to the import dialog |

The label-triggered input and cancellation during navigation have fixture/source
coverage only; they are not claimed as completed native UI checks. Real-site checks
verified native picker presentation and cancellation using existing login sessions;
no file was uploaded to Gmail or Zoom. File delivery and readable bytes were checked
with the local fixture above.

The patched 1.4.18 app was installed at `/Applications/Nous Browser.app` after a
normal quit. Its framework SHA-256 matches the packaged candidate, and its code
signature passes deep strict verification. All three original work windows retained
their tab counts and selected tab IDs after restart. The dedicated test window was
closed; the original app is retained as a local recoverable backup. No Keychain
password prompt appeared during this update.
