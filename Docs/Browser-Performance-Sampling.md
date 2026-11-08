# macOS process-tree performance sampling

`Scripts/sample-browser-processes.cpp` samples one explicit browser root PID and its discovered descendants. Renderer, GPU, and network helper CPU/memory are included because the sampler follows the process tree, without filtering on process names. It never reads process arguments, URLs, page content, credentials, file contents, or browser profiles. It uses public unprivileged process-accounting APIs and refuses a root PID owned by another user.

## Build and run

From the repository root:

```sh
mkdir -p .build
xcrun clang++ -std=c++20 -O2 -Wall -Wextra -Werror \
  Scripts/sample-browser-processes.cpp -o .build/sample-browser-processes
.build/sample-browser-processes --self-test
```

Choose the intended browser application's PID in Activity Monitor. Start sampling before the workload. Substitute that number for `12345`:

```sh
.build/sample-browser-processes --root-pid 12345 \
  --duration 60 --interval 0.5 \
  --output .build/browser-sample.jsonl
```

The output must be a new file; it is created with mode `0600`. Omitting `--output` writes JSON Lines to stdout. There is no `sudo`, entitlement change, permission request, browser automation, or process control. The sampler does not close or pause the target app. Only `--self-test` creates its own brief test processes.

Analyze already collected runs without attaching to a browser:

```sh
python3 Scripts/analyze-browser-samples.py --self-test
python3 Scripts/analyze-browser-samples.py \
  --run nous-idle=.build/performance/nous-idle.jsonl \
  --run chrome-idle=.build/performance/chrome-idle.jsonl
```

Optional `--skip-seconds` and `--duration` select the same elapsed window in
each file; only whole intervals inside it are used. Missing/null CPU intervals
are excluded and reported, never averaged as zero. Output includes time-weighted
CPU, sample distributions for memory/system load, wakeup/I/O rates, coverage and
report completion. It prints JSON to stdout and makes no files or process calls.
Labels do not establish matched workloads, and the analyzer gives no automatic
performance verdict. A truncated report remains explicitly incomplete.

## Read the measurements

| Field | Meaning |
| --- | --- |
| `cpu_percent_one_core` | CPU time delta / measured elapsed time × 100. One fully used logical core is 100%; a whole browser can exceed 100%. This differs from `system_cpu_busy_percent`, which uses 100% for the whole machine. |
| `cpu_user_delta_ns`, `cpu_system_delta_ns` | Converted per-process CPU increments. `interval_ns` in each process row is that process's observation interval. |
| `physical_footprint_bytes`, `rss_bytes` | Current kernel-accounted footprint and resident bytes; aggregate fields sum readable, live processes. RSS shared pages can be counted more than once. Neither sum is a unique physical-memory map. |
| `disk_read_delta_bytes`, `disk_write_delta_bytes` | Kernel process disk-I/O increments, not network traffic. Each row also includes cumulative disk and logical-write counters. |
| `pageins_delta`, `interrupt_wakeups_delta`, `package_idle_wakeups_delta` | Kernel counter increments. Pageins are counts, not bytes; wakeups are not an energy or fan-speed reading. |
| `system_load_average`, `system_cpu_busy_percent` | Whole-machine load and CPU contention, including unrelated builds/apps. |
| `collection_duration_ns` | Time spent collecting each sample; useful when evaluating sampler overhead. |

CPU values from `proc_pid_rusage` must **not** be treated as nanoseconds directly. Apple's [task accounting implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c) supplies Mach-time metrics; [rusage filling](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) copies them into the user/system counters. The sampler converts with `mach_timebase_info`, using an overflow-safe intermediate. Metadata records the actual timebase. The self-test compares these converted increments with independent `CLOCK_PROCESS_CPUTIME_ID` measurements; it does not assume that a busy worker gets a full core on a contended machine.

The public [`libproc` wrapper](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c) takes child-list buffer sizes in bytes but returns a PID count. All recursive discovery uses that count. Identity is PID + BSD birth time + Mach process-start time, checked before/after reading counters. A previously identified child remains tracked after reparenting; reuse of its PID is excluded unless the new generation is independently discovered under a verified tracked parent.

## Coverage and comparison limits

- Polling can miss children that are created and exit between polls, or become orphaned before their first discovery. Helpers launched outside the root's descendant tree, including OS services, are not attributed. The tool cannot promise complete process attribution from a PID alone.
- Newly discovered processes start with a baseline. Their earlier CPU is deliberately excluded. Final CPU after an unreadable exit can also be missing. The summary's CPU total is therefore an observed lower bound.
- Events record discovery, reparenting, PID reuse, inaccessible reads, enumeration races and exits. When a process disappears, the report distinguishes readable final counters from missing final counters. No failure is silently converted into zero CPU.
- `observed_interval_complete` means no **known** gap, new baseline or enumeration failure in that sample; it does not certify that no short-lived process was missed. Aggregate CPU percent is `null` when a known gap occurs. Per-process valid rates use their own timestamps. After a missed read, `cpu_delta_ns_observed` and I/O deltas can span multiple sample intervals; use each process's `interval_ns` and `coverage_gap` rather than treating that total as one interval's rate. The run summary does not double-count recovered deltas.
- A process scan is not an atomic system snapshot. Aggregate rates are an approximation with slightly different process observation endpoints. Compare sustained windows, inspect collection time, and exclude startup/discovery/transient gaps. Do not average `null` samples as zero.
- GPU-process CPU is included; GPU utilization, power, temperature, fans, network bytes, input latency and rendering smoothness require separate measurements. Process accounting alone cannot establish UX performance parity.
- Compare Nous and Chrome using the same machine, displayed content, tabs, viewport, foreground/background actions, warm-up, extension/profile conditions and measurement duration. Capture an idle baseline and repeat the workload. Record the browser builds and test steps separately, without page contents in this report.
- **Do not draw browser-performance conclusions during the ongoing Chromium source build.** Whole-machine contention invalidates a controlled Nous-versus-Chrome comparison. The synthetic self-test verifies the sampler, not either browser's speed.

## Chromium app-layer audit: candidates, not measured causes

Read-only source/log review on 2026-11-07 found the following paths worth checking. Line numbers refer to that working-tree snapshot; they are evidence locations, not proof of workload frequency or cost. No performance-path changes or additional polling were introduced for this review.

| Candidate | Exact evidence | Smallest useful verification |
| --- | --- | --- |
| SwiftUI/native focus or layout reentry | `Sources/NousBrowser/WebViewDeck.swift:14` calls `show` from `updateNSView`; `:44–50` resends lifecycle state for every tab; `:68` changes visibility only when necessary; `:77–78` can synchronously call `makeFirstResponder`. `Sources/NousBrowser/ChromiumPageView.swift:153–155` enters CEF focus from `becomeFirstResponder`. | First sample the host during actual input. If layout/focus stacks dominate, a later narrowly scoped diagnostic can count `updateNSView`/`show`/focus/layout calls, nesting depth and durations without page data. Only then A/B deferring the explicit deck focus request, retaining current-selection/window-ownership checks. |
| Native state events repeatedly saving the full window session | `Sources/NousChromium/NousChromium.mm:917–943` emits state for loading, title and main-frame address changes. `Sources/NousBrowser/ChromiumBrowserTab.swift:174–191` calls `scheduleSave()` for every state event, even when persisted fields are unchanged. `Sources/NousBrowser/BrowserModel.swift:633–639` debounces for 350 ms; `:607–627` then creates/encodes the full tab session and atomically writes it on the main actor. | Look for host JSON/file-write stacks and correlated write counters. If present, measure event counts, actual title/URL changes, saves and save duration. A dynamic editor title could amplify this path; its frequency in Zoom Slides has **not** been measured. No title strings need to be logged. |
| Continued password discovery during structural editor updates | `Sources/NousBrowser/BrowserPasswordAutofill.swift:550–585` observes subtree structure and `type`/`form`, queuing added element subtrees. `:515–547` limits each discovery slice to 256 nodes/3 ms, but sustained subtree replacement can keep more slices pending. Candidate-form observation at `:496–513` includes text/style/class inside forms containing password inputs. | Separate plain text/style changes from large subtree replacement in a synthetic fixture; count processed nodes, discovery callback time and backlog. Then establish which mutation pattern the real editor produces before changing anything. Keep fill-time origin, token, visibility and field checks intact. |
| DevTools event transport despite early filtering | `Sources/NousChromium/NousChromium.mm:1398–1403` enables Page/Runtime for each browser. `:663–671` ignores unrelated console/exception events before JSON parsing, but receives their event buffers. | Only if renderer/host samples implicate DevTools, count ignored event categories and byte totals. No console payloads or document contents should be collected. Context/binding tracking is required for the isolated-world security boundary; do not disable it as an unmeasured shortcut. |

The current `.build/chromium/runtime-lifecycle20-custom.log` contains **78 AttributeGraph cycle messages in three contiguous groups of 26**, starting at lines 17, 151 and 193. The first follows AX enablement; the others occur around source-page closure/download completion events and subsequent native layout. This is a bounded log observation, **not evidence of a continuous loop**, not proof that AX caused the cycles, and not an explanation of fan noise. The native focus/layout path remains a hypothesis until a correlated trace establishes causality.

Several previously identified costs are already bounded or absent in Chromium:

- `ChromiumBrowserTab.swift:72–74` does not attach the WebKit scrollbar DOM/shadow observer. `BrowserWindowManager.swift:487–491` excludes the old five-minute hibernation monitor under `NOUS_CHROMIUM`.
- `BrowserPasswordAutofill.swift:590–600` disconnects discovery/candidate observers for hidden/pagehide documents. A page without password fields has no document-wide text/style/class observer; `:370–382` deduplicates outgoing candidate metadata. `ChromiumPasswordAutofill.swift:62–87` refreshes on navigation/URL change, without recurring evaluation polling.
- `ChromiumPageView.swift:66–73` coalesces adjacent same-generation state/progress events and delivers asynchronously. This does not prove zero layout reentry through AppKit's synchronous focus path.
- Deck lifecycle calls are redundant at the host boundary, but the pinned Chromium `components/performance_manager/decorators/page_live_state_decorator.cc:261–285` setters early-return for unchanged auto-discardable/active/pinned values. `decorators_utils.h:23–40` calls them directly. Do **not** describe this as an established performance-manager task or notification storm.
- `NBMessagePumpScheduler.mm:127` retains a 33 ms fallback, with coalesced scheduling and a reentry guard. Earlier lifecycle10 measurements reported roughly 30 calls/s and pump thread CPU between 0.036% and 1.231% of one core across the observed idle-fixture windows. Those historical fixture observations do not establish current Zoom cost, but they do not support the earlier constant-10-ms-busy-wait hypothesis either. Do not bypass required CEF pumping.
- `NousChromium.mm:1212–1218` assigns child frames during native layout; `BrowserShell.swift:54–77,157` uses native material and page/window clipping. Whether these increase resizing or compositing cost requires measurements. A SwiftUI update is not itself evidence that the web document is reloaded or fully rerasterized.

## Controlled Zoom Slides comparison

Use the existing process sampler first. Do not add a permanent polling loop or change rendering/background policies before identifying a measured bottleneck.

1. **Remove build contention.** Wait until Chromium/Ninja/clang/linking, app packaging and heavy test jobs have finished. Let the machine settle, record whole-machine CPU/load and power mode, and discard a run if unrelated load changes substantially. The optimized CEF build and an unoptimized preview are different configurations; record the exact app/SDK build and optimization mode. Do not compare a compiling Nous run with an otherwise idle Chrome run.
2. **Match accessibility state.** `NousChromium.mm:259–268` enables AX only when enhanced/manual accessibility or VoiceOver requests it, with an unchanged-state guard. CUA can request enhanced accessibility; closing a test step is not proof that the OS has cleared that request. Record effective state and run Chrome/Nous with equivalent assistive-tool conditions. Avoid UI automation/AX inspection during the measured interval; do not disable a user's required accessibility service to improve numbers. A run with unknown/different AX state is not a controlled comparison.
3. **Match the workload.** Use the same authorized test document/slide, page zoom, viewport, display/scaling/refresh rate, number of tabs/windows and visible/background selection. Keep account/session, extensions, media, network warm-up, power mode and measurement durations comparable. Do not alter or discard unsaved user work to manufacture an idle baseline. Record the procedure separately from the content.
4. **Measure distinct phases.** After both pages finish warming up, collect a 60-second idle baseline, a 60-second repeatable typing/editing phase, a separate 60-second pan/zoom phase, and a 60-second background phase with the same unrelated tab selected. Restore the same starting test state before each repeat. Alternate browser order and repeat at least three times; label exact phase boundaries without logging typed content. Keep the one-time startup/navigation cost separate.
5. **Locate the hot process before collecting stacks.** Compare complete sustained intervals, per-process CPU/footprint and write/wakeup counters, alongside system load. If the main app is hot, sample it; if a renderer or GPU helper is hot, sample that verified PID separately. WindowServer and GPU utilization/power are outside this process-tree report and need separately labeled observations. Preserve missing/incomplete samples instead of treating them as zero.

For one short diagnostic during a repeat of the problematic phase, use macOS `sample` with an explicit verified PID. This example records five seconds at a 10 ms interval; it does not launch UI or change browser settings:

```sh
(umask 077; /usr/bin/sample 12345 5 10 -file .build/nous-host-stack-sample.txt)
```

Use a new output name, and replace `12345` with the current intended process. The local `sample(1)` manual documents that each sample briefly suspends the process to collect stacks. Therefore this is an **instrumented diagnostic run**, not an unperturbed latency or smoothness comparison. Keep stack reports local, review paths/metadata before sharing, and do not use `sudo` or bypass a denied attachment. Do not infer CPU cost from sleeping/waiting stacks alone; correlate with the process-accounting interval. A brief sample may miss intermittent work or lack symbols, so absence of a function is not proof that its path is free.

Only after these measurements should a candidate receive a one-change A/B test. Keep correctness checks for IME, focus, hidden-page scheduling, password safety and unsaved documents. Synthetic fixture improvements validate that specific path; **they do not prove improved Zoom Slides performance or Chrome parity**.

## Synthetic validation

The self-test creates a short CPU worker, then a root/child/grandchild tree and an unrelated sibling. It checks CPU-clock agreement, exact tree membership, sibling exclusion, continued observation after the grandchild is reparented, and observed exits. It does not inspect an existing user process.

On the development Apple Silicon Mac, the test passed with timebase `125/3`, approximately `200.030 ms` converted process CPU versus `200.005 ms` POSIX CPU (`1.00013` ratio), the exact three-process tree, one reparenting and three observed exits. These are sampler-correctness results only. Run `--self-test` again on the machine being measured; a failed or severely delayed self-test must be investigated before interpreting reports.

## Exploratory idle observation — 2026-11-07

This is **one low-idle-load observation per browser, not a controlled performance
win, Chrome parity result, or Zoom Slides editing measurement**. Both complete
raw JSONL reports and their summaries were reread. Each collection lasted about
90 seconds; the first 30 seconds were excluded. The remaining 119 whole
intervals per browser had no recorded sampling omissions, enumeration failures,
process exits or known coverage gaps. Polling's unobserved-process limitation
still applies.

| Observed metric | Nous candidate24 | Installed Chrome |
| --- | ---: | ---: |
| Host / engine | Release PGO2 + ThinLTO-O2 / Chromium 156.0.8078.80 | Chrome 157.0.8103.38 |
| Root PID / observed process count | 59180 / 6 | 60135 / 10 |
| Analyzed complete interval time | 59.997 s | 60.052 s |
| CPU, time-weighted, 100% = one logical core | 0.3622% | 0.1092% |
| Summed physical footprint, sample mean | 308.93 MiB | 418.87 MiB |
| Process-accounting interrupt wakeups / s | 32.35 | 5.16 |
| System CPU busy, sample mean | 17.89% | 14.99% |
| Sampler collection time, sample mean | 0.786 ms | 1.317 ms |

The operator used the same foreground, single-tab local URL,
`http://127.0.0.1:18869/chromium_lifecycle.html?name=PerfIdle`, at different times;
the other browser was exited for each run. There were no engine/app builds
during collection. Accessibility was enabled. These conditions were **not**
otherwise matched: Nous had earlier navigation/discard experiments and may
have retained BFCache/history; Chrome used an existing user profile with the
ChatGPT extension permitted on localhost, Translate UI, and an earlier brief
Manage Profiles window. Window dimensions were not matched. Nous used its
compact native sidebar. The differing engine versions, profile history,
extension state and system background load prevent causal or winner claims.
No account or public document mutation was part of this fixture.

Evidence (ignored, local-only):
`.build/performance/nous24-idle-01.jsonl`,
`.build/performance/chrome157-idle-01.jsonl`,
`.build/performance/idle-exploratory-analysis.json`, and
`.build/performance/idle-exploratory-conditions.json`. The separate
`idle-exploratory-process-distribution.json` in that directory preserves each
process generation's CPU/wakeup deltas and raw-report SHA-256 values.
Reproduce the existing report analysis without new sampling:

```sh
python3 Scripts/analyze-browser-samples.py --skip-seconds 30 \
  --run nous24-idle-01=.build/performance/nous24-idle-01.jsonl \
  --run chrome157-idle-01=.build/performance/chrome157-idle-01.jsonl
```

### Wakeup follow-up: a specific hypothesis, not an established cause

Per-process deltas in the same retained intervals attribute 1,831 of Nous's
1,941 interrupt wakeups to host PID 59180: **30.52 host wakeups/s** and
**0.3485% host CPU**. The five descendants together account for the remaining
110 wakeups and about 0.0137% CPU. Chrome's root accounts for 89 of 310
wakeups, or 1.48/s. These figures locate the Nous signal in the host; they do
not identify the thread or timer responsible and do not measure package
power, fan speed or input responsiveness.

The leading code-level hypothesis is the external CEF message pump's 33 ms
fallback. `Sources/NousChromium/NBMessagePumpScheduler.mm:67` caps requested
delays at 33 ms; `:102–104` arms a main-queue one-shot timer; `:127` schedules
another 33 ms timer after work. `NousChromium.mm` connects that work to
`CefDoMessageLoopWork()`. A roughly 30/s host wakeup cadence is consistent
with that path. The local PerfIdle fixture itself has no recurring timer or
rAF loop. Nevertheless, accounting counters cannot prove a one-to-one timer
cause; AX, AppKit/CEF work and other host sources remain possible contributors.

The pinned [CEF external-pump example](https://github.com/chromiumembedded/cef/blob/cf671c072925b27823a61181152f4f288e8e4306/tests/shared/browser/main_message_loop_external_pump.cc)
also uses `1000 / 30` as its maximum delay and rearms fallback work when no
timer is pending. Thus the correlation is not evidence that required pumping
may simply be removed. Confirm event attribution in a separately labeled,
instrumented run before considering any change; retain native input, dialogs,
timers, media, background scheduling and shutdown regression coverage. No
product scheduling or rendering code was changed for this analysis.
