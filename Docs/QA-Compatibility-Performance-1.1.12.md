# 1.1.12 (52): uniform identity and editor script overhead

## Root cause and scope

The previous browser sent the system's embedded WKWebView identity to most
websites, and changed `customUserAgent` only for enumerated Google and Zoom
endpoints. This left Slack, authentication endpoints, and future sites with a
different identity. Changing that identity during a redirect/response also
cannot retroactively change the request the server already evaluated.

The new policy sets one desktop WebKit identity in the configuration **before
creating the view**. It applies to every site, request, frame, and inherited
popup. There is no domain list, navigation-time resolver, UA-changing script,
warning suppression, or Chromium impersonation. The isolated Zoom IME guard is
retained independently.

`Version/26.4` on macOS 26.4+ (26.0 on older supported systems) is the tested
Safari compatibility floor, not the installed Safari application's version.
Safari can ship a different engine from system WKWebView. The frozen
`Safari/605.1.15` token follows WebKit's macOS UA convention; it is not the age
of the actual engine. Future capability floors require testing when platform
support changes, in this single central policy rather than per-site patches.

References:
- [WebKit macOS UA source](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/mac/UserAgentMac.mm)
- [Slack browser requirements](https://slack.com/help/articles/115002037526-System-requirements-for-using-Slack)

## Compatibility evidence

- Installed 1.1.11 visibly showed Slack's unsupported-browser page at
  `https://slack.com/signin`.
- A public HTTP comparison using the old embedded UA returned status 403 with
  that message. The uniform desktop WebKit UA returned status 200 and the
  normal `Login | Slack` page. No credentials or cookies were used.
- 18 targeted tests passed: identity, existing IME regressions, fullscreen and
  popup policy. A real loopback HTTP server verified the first request, a
  cross-host 302 chain, iframe, worker, fetch, document-start navigator and
  appVersion. Actual BrowserTab tests cover history, reload, popup navigation
  and recreation after hibernation.

## Measured injected-script work

These are deterministic real-WebKit fixtures, not whole-browser CPU savings.

| Representative editor workload | Before | After |
| --- | ---: | ---: |
| 12 mutation bursts, 60 non-login forms: form collection scans | 12 | 0 |
| Same workload: form element collection reads | 720 | 0 |
| Moving a 601-element subtree 40 times: shadow-root checks | 24,040 | 601 |

Password detection indexes password fields, skips unrelated editor updates,
and defers background detection until visible. Security checks still run
immediately before filling. All 13 AppKit-hosted autofill tests passed without
skips, including dynamic fields, hidden-page recovery and unsafe form changes.

Scrollbar policy coalesces duplicate subtree work and yields in bounded
256-node / approximately 3 ms chunks. Four real-WebKit tests cover dynamic
shadow roots, iframes, continued scrolling and stylesheet restoration.

The explicit serial full run completed the 320-case browser suite and the
8-case automation suite without failures. The 11 autofill cases skipped in the command-line host are covered by
the separate 13-case AppKit run. An initial concurrent run overloaded two
existing timing-sensitive tests; both their separate suites (31 tests) and
the serial full run passed. No timing-test implementation was changed.

## Limits and live acceptance

The earlier CPU samples were not matched workloads. These changes remove
reproduced extra work, but do not establish that every cause of the user's fan
noise or editor latency is resolved. Shared system processes and page workloads
must be distinguished in a controlled live comparison. No aggressive tab
unloading, document data clearing, or webpage content changes were introduced.

After the user confirmed it was safe to restart, installed and launched the
optimized signed 1.1.12 (52) app from `/Applications/Nous Browser.app`.
The original window and all six original tab IDs were preserved. The previous
signed 1.1.11 bundle is retained locally for rollback. Cookies and website data
were not cleared.

Installed-app acceptance, 2026-10-30:
- Slack sign-in displays the ordinary email/Google/Microsoft/Apple login page.
  An authenticated Slack workspace session was not exercised.
- Gmail's authenticated inbox loads without an unsupported-version banner.
- The existing Google Docs document, the user's previously reported Slides
  presentation, and the existing Sheets QA workbook load their editors without
  that banner. Slides and Sheets were also checked visually; spreadsheet text
  was clear in the captured view. No document content was edited.
- The original Zoom Canvas document and the existing QBR Zoom Slides document
  restored their authenticated sessions and displayed “Synced from cloud”.
  Returned to the originally active Canvas tab after checking Slides.
- Closed the separate acceptance window and its six temporary tabs afterward;
  the user's original window and tabs remain.

These are live recognition/load checks, not a full feature certification or
matched sustained editing benchmark. Existing native IME behavior was covered
by automated regression, not newly claimed as manually retested.

Local ignored evidence: `.build/compatibility-20261030/`,
`.build/password-autofill-integration/`, `.build/scrollbar-performance/`.

## Follow-up runtime sampling, 2026-10-30

Kept the installed build and six original tabs. Read-only navigation in the
existing 26-slide QBR document exercised slides 4–10, then returned to slide 4
and the originally selected Canvas tab. No document content was changed.

Two 30-second windows use cumulative `ps` CPU-seconds deltas, with 100% meaning
one CPU core. Nous WebKit ownership was identified from its launchd PID domain,
not by assuming every WebKit process belongs to Nous.

| Window | Nous total | Main app | Active Slides web process | GPU process |
| --- | ---: | ---: | ---: | ---: |
| Includes 12 automated slide selections | 26.57% | 3.78% | 18.74% | 3.52% |
| Editor left idle after navigation | 11.13% | 2.45% | 7.72% | 0.83% |

The active web process physical footprint was approximately 1.2 GiB, the
background Canvas process approximately 616 MiB. This short sample is not a
memory-leak diagnosis. The app's main thread was mostly waiting during the
separate eight-second stack sample, with intermittent WebKit layer updates;
it did not establish a new Nous-specific sustained hotspot.

BTLEServer independently averaged approximately 98% of one CPU core. Shared
WindowServer averaged 77–87%, and unrelated Chrome processes were also active.
No system services were changed. These figures prevent attributing all fan
noise to Nous, but do not absolve the browser's own workload.

This is navigation/idle profiling with UI-automation overhead, not sustained
typing, a pre/post optimization benchmark, or an equal-workload Chrome
comparison. Performance acceptance remains incomplete. Background live-page
retention and repeated SPA favicon/session work remain audit candidates, not
confirmed causes. No speculative unloading or new production changes were made.

Evidence: `.build/performance-20261030/*-verified.json` and stack samples.
The initial two JSON captures are explicitly marked invalid for CPU because
raw Mach ticks were treated as nanoseconds; their CPU values must not be used.
The verified reruns use `ps` CPU seconds instead.
