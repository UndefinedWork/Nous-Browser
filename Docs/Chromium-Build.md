# Build Nous Browser with Chromium (NousCore)

## Chromium integration

Nous Browser embeds Chromium the way Dia/Arc do (see
[Dia-Architecture-Research.md](Dia-Architecture-Research.md)): Chromium's full
`//chrome` layer and the Nous embedding layer `//nous` are compiled into one
renamed Chrome framework, **`NousCore.framework`**. The Swift app links it and
imports its Objective-C API as the `NousCore` Clang module. CEF is no longer
used. Architecture, API and patch details: [Engine/README.md](../Engine/README.md).

Target: Apple Silicon, macOS 26+, Chromium 156.0.8078.80.

## Inputs

| Input | Default |
| --- | --- |
| Chromium checkout | `~/Library/Caches/NousCEF/156.0.8078.80-arm64-codecs/chromium/src` (`NOUS_CHROMIUM_SRC`) |
| depot_tools | `…/156.0.8078.80-arm64-codecs/depot_tools` (`NOUS_DEPOT_TOOLS`) |
| GN args | `Engine/args.gn` (`nous_core = true`, `enable_cef = false`) |
| Chromium patches | `Engine/patches/apply_chromium_patches.py` (idempotent exact-text edits) |

The checkout still contains `//cef` from the former engine; the patch script
guards the few CEF patches that otherwise break `enable_cef = false` builds.

## Signing

GitHub builds look for the Nous team's Developer ID Application identity in
the keychain. The build signs the embedded Chromium and Sparkle code with
the same identity and requests secure timestamps. If the Developer ID is
unavailable, the original `identity.key`, `identity.crt` and `rcodesign` in
`~/Library/Application Support/NousSigning/` can sign the outer app with
the legacy certificate. Use `NOUS_SIGNING_IDENTITY` to select a keychain
identity explicitly. Local builds can run ad hoc. Release packaging verifies the publisher, and GitHub checks that
both versions satisfy each other's designated requirements once a stable
signing identity has been established.

## Build

```sh
zsh Scripts/build-nouscore.sh        # → .build/nouscore/sdk/NousCore.framework
zsh Scripts/build.sh                 # engine (incremental) + Swift + package → build/Nous Browser.app
NOUS_SKIP_ENGINE_BUILD=1 zsh Scripts/build.sh   # Swift-only changes
NOUS_DISTRIBUTION_CHANNEL=chromium-preview zsh Scripts/build.sh   # isolated preview bundle
```

A first engine build compiles about 80k steps (several hours on 12 jobs);
later changes to `//nous` are incremental and relink the framework. Packaging
rebrands Chromium's helper apps (name, icon, bundle id) as Nous and signs
the bundle with the configured identity.

## Website data

All builds of one distribution share a single Chromium profile
(`~/Library/Application Support/Nous Browser/Chromium/Local/GitHub`). Ad-hoc
signed builds cannot share a keychain item (macOS ties it to one build's code
hash), so Chromium's Safe Storage secret is derived from a random key kept in
`~/Library/Application Support/Nous Browser/Secrets/storage.key` (0600, folder
0700) and handed to OSCrypt through a `//nous` keychain override; no keychain
item is read or created. On first launch of a team-signed build, existing
local profiles and password vaults continue to use their original keys.
New team-signed installations use the team keychain.

## Acceptance

`ChromiumSmokeCheck` is compiled only for the `chromium-preview` bundle. Run it with
`NOUS_CHROMIUM_SMOKE_REPORT` set, against `Tests/Fixtures/chromium_test_server.py`.
Last full run (1.3.0): 16 passed, 3 manual-only skipped (trusted popup click, password
fill, Finder drop/IME). The suite also checks the private-window and extension menu
commands, isolation from regular browsing, and clearing website storage after the
last private window closes. Verify Chrome Web Store installation in the regular
profile with the real permission prompt. Extensions that depend on Chrome’s
native `Browser` or `TabStripModel`, including native side panels, still have
compatibility gaps. Developer ID signing, notarization, Memory Saver
auto-discard and Chrome performance parity remain unverified.
