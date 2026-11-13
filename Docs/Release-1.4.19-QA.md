# Release 1.4.19 (75) — validation

Date: 2026-11-13. Chromium: 156.0.8078.80. Target: macOS 26.0+, arm64.

## Release scope

This release was prepared in an isolated worktree from the published baseline.
It includes the native file chooser, website permission prompt lifetime, and
external application link fixes, with their regression fixtures. Unrelated
incognito work in the development worktree is excluded.

Earlier native observations are documented in [File-Chooser-QA.md](File-Chooser-QA.md),
[Permission-Prompt-QA.md](Permission-Prompt-QA.md), and
[External-Protocol-QA.md](External-Protocol-QA.md). Those tests used the earlier
development build; the checks below record the separate 1.4.19 release candidate.

## Automated tests

- Full serial run passed: **343 tests in 63 suites**, comprising 334 browser
  tests in 59 suites and 9 MCP tests in 4 suites.
- The initial parallel run had one timing-sensitive failure in
  `defaultHoverWaitsAtLeastThreeHundredMilliseconds`: the expected tooltip was
  not presented by the check. The other tests completed. This failure is not
  counted as a passing run.
- The tooltip suite then passed independently, **6 tests in 1 suite**, followed
  by the complete serial pass above. No tooltip implementation or test was
  changed for the rerun. The parallel scheduling failure remains recorded.

Local evidence: `.build/release-1.4.19-tests.log`,
`.build/release-1.4.19-tooltip-retest.log`, and
`.build/release-1.4.19-tests-serial.log`.

## Engine, app, and packaging

- The curated NousCore engine build completed successfully. Both production
  and preview apps were built using that curated engine.
- The production app reports **1.4.19 (75)** and was signed with the existing
  local signing certificate.
- Release packaging verified the original, staged, DMG-mounted, and ZIP-extracted
  app bundles with deep strict code-signature checks. Packaged executable, MCP
  helper, and `Info.plist` hashes were checked against the source app; the MCP
  helper also passed its separate strict signature check.
- The DMG passed `hdiutil verify`; its payload was inspected through a read-only
  mount. The ZIP was extracted and its app verified.
- SHA-256 checksums were generated for both downloadable assets. Update signing
  confirmed that the signing key matches the app's embedded public key, then
  generated the signed `appcast.xml`.

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| `Nous-Browser-1.4.19-macOS-arm64.dmg` | 208414749 | `640e61932a36884035f1e3c42590279751e860f2d7eff8fdadd7835ffb2a3aff` |
| `Nous-Browser-1.4.19-macOS-arm64.zip` | 207387685 | `977d92c6425999cb9ee6a77df822720989fb2fb74f25ab5086cb3ee9b1f35782` |

Local evidence: `.build-engine-release.log`, `.build-app-release.log`,
`.build-preview-release.log`, `.build-package-release.log`, and `dist/SHA256SUMS.txt`.
These packaging checks do not establish Apple notarization or a completed
download/install through the public update feed.

## Native release-candidate checks

| Check | Result |
| --- | --- |
| Permission sheet hidden by switching tabs | Passed: the old sheet closed and a distinct replacement appeared on returning. |
| Answer replacement with Don't Allow | Passed: notification permission became `denied` and stayed `denied` after reload and reopening the same origin. |
| Attachment button | Passed: opened the native file picker; Cancel returned normally, and clicking the same button reopened the picker. The second picker was also cancelled. |
| External application link, Cancel and retry | Passed: a real pointer click opened the native confirmation; Cancel preserved the source page, and a second real click opened the confirmation again. |
| External application link, approved same-tab handoff | Passed: acceptance delivered the exact synthetic `same-tab?run=1794538036484` request to the local receiver as sequence 9. |
| External application link, `target=_blank` | Passed: a real pointer click opened the native confirmation; acceptance delivered the exact synthetic `new-tab?run=1794538067496` request as sequence 10. The receiver displayed that URL and a total of 10 recorded requests. |
| Source page and auxiliary-tab cleanup | Passed: the source remained selected and the total tab count was 3 before and after the accepted new-tab link, with no leftover auxiliary tab. |

Permission evidence: `.build/release-qa/permission.json`, with both
`oldSheetClosed` and `replacementSheetCreated` true. This check used a local
notification denial; it did not grant or access the clipboard, camera,
microphone, or location. The release-candidate file picker check confirms
presentation and reopening after cancellation; earlier readable-file and
real-site checks remain separately documented in File-Chooser-QA.md.

The preview and local receiver were normally quit after these checks; the
production app remained running. The external application checks used only a
synthetic local receiver, not a real VPN authentication callback. No fresh
GlobalProtect login is claimed here.
