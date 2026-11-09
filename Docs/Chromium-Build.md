# Build Nous Browser with Chromium (NousCore)

## Current source — 1.4.12 (68), 2026-11-09

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

Nested code is ad-hoc signed. When `~/Library/Application Support/NousSigning/`
holds `identity.key`, `identity.crt` and `rcodesign`, the build re-signs the
outer app with that self-signed certificate (no keychain involved), giving it
the designated requirement `identifier "com.cellier.nous-browser" and
certificate root = H"…"`. macOS privacy permissions (Screen Recording) follow
that requirement, so they survive updates. Without those files the app stays
ad-hoc and the permission is asked again after every update.
`NOUS_SIGNING_IDENTITY` still selects a team identity instead.

## Build

```sh
zsh Scripts/build-nouscore.sh        # → .build/nouscore/sdk/NousCore.framework
zsh Scripts/build.sh                 # engine (incremental) + Swift + package → build/Nous Browser.app
NOUS_SKIP_ENGINE_BUILD=1 zsh Scripts/build.sh   # Swift-only changes
NOUS_DISTRIBUTION_CHANNEL=chromium-preview zsh Scripts/build.sh   # isolated preview bundle
```

A first engine build compiles about 80k steps (several hours on 12 jobs);
later changes to `//nous` are incremental and relink the framework. Packaging
rebrands Chromium's helper apps (name, icon, bundle id) as Nous and ad-hoc
signs the bundle. It does not install, notarize or publish.

## Website data

All builds of one distribution share a single Chromium profile
(`~/Library/Application Support/Nous Browser/Chromium/Local/GitHub`). Ad-hoc
signed builds cannot share a keychain item (macOS ties it to one build's code
hash), so Chromium's Safe Storage secret is derived from a random key kept in
`~/Library/Application Support/Nous Browser/Secrets/storage.key` (0600, folder
0700) and handed to OSCrypt through a `//nous` keychain override; no keychain
item is read or created. Updates therefore keep website sign-ins and saved
passwords. Team-signed builds keep the secret in the keychain instead.

## Acceptance

`ChromiumSmokeCheck` runs only in the `chromium-preview` bundle with
`NOUS_CHROMIUM_SMOKE_REPORT` set, against `Tests/Fixtures/chromium_test_server.py`.
Last full run (1.3.0): 16 passed, 3 manual-only skipped (trusted popup click, password
fill, Finder drop/IME). Not yet established: Developer ID signing/notarization,
Memory Saver auto-discard and extensions (need Chrome `Browser`/`TabStripModel`
integration), Chrome performance parity.
