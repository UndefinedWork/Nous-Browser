#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CHROMIUM_DIR="$PROJECT_DIR/.build/chromium"
CHANNEL="${NOUS_DISTRIBUTION_CHANNEL:-github}"
[[ "$CHANNEL" == github || "$CHANNEL" == chromium-preview ]] || { print -u2 'Unsupported distribution channel.'; exit 1; }
APP_NAME='Nous Browser.app'
if [[ "$CHANNEL" == chromium-preview ]]; then APP_NAME='Nous Browser Chromium.app'; fi
APP_DIR="${NOUS_CHROMIUM_APP_DIR:-${NOUS_BUILD_APP_DIR:-$PROJECT_DIR/build/$APP_NAME}}"
# A candidate may be staged separately while an older preview is still running.
# Keep every output inside the ignored build tree; never allow /Applications.
python3 - "$PROJECT_DIR" "$APP_DIR" <<'CHECK_OUTPUT'
from pathlib import Path
import sys
root=Path(sys.argv[1]).resolve(); output=Path(sys.argv[2]).resolve()
if not any(parent in output.parents for parent in (root / '.build', root / 'build')) or output.suffix != '.app':
    raise SystemExit('Build output must be an app inside the repository build or .build directory.')
output.parent.mkdir(parents=True, exist_ok=True)
CHECK_OUTPUT
CONFIGURATION="${CONFIGURATION:-release}"
cd "$PROJECT_DIR"
# Engine: Chromium //chrome + //nous as NousCore.framework (Dia's ArcCore model).
SDK_DIR="${NOUS_CORE_SDK_DIR:-$PROJECT_DIR/.build/nouscore/sdk}"
if [[ "${NOUS_SKIP_ENGINE_BUILD:-0}" != 1 ]]; then
    zsh "$PROJECT_DIR/Scripts/build-nouscore.sh"
fi
NOUSCORE="$SDK_DIR/NousCore.framework"
[[ -d "$NOUSCORE" ]] || { print -u2 "NousCore.framework not found in $SDK_DIR"; exit 1; }
export NOUS_CORE_SDK_DIR="$SDK_DIR"

swift build --scratch-path "$CHROMIUM_DIR/swift" --configuration "$CONFIGURATION" --jobs "${NOUS_BUILD_JOBS:-4}"
BIN_DIR="$(swift build --scratch-path "$CHROMIUM_DIR/swift" --configuration "$CONFIGURATION" --show-bin-path)"
STAGING_DIR="$(mktemp -d "$CHROMIUM_DIR/package.XXXXXX")"
# Each staged bundle is ~575 MB; never leave one behind.
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME"
CONTENTS="$STAGED_APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BIN_DIR/NousBrowser" "$CONTENTS/MacOS/NousBrowser"
cp "$BIN_DIR/NousBrowserMCP" "$CONTENTS/MacOS/NousBrowserMCP"

SPARKLE="$CHROMIUM_DIR/swift/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE" "$CONTENTS/Frameworks/Sparkle.framework"
# Chrome resolves its framework at Contents/Frameworks/NousCore.framework/
# Versions/<chrome version>/ and its helper apps inside that directory.
FRAMEWORK="$CONTENTS/Frameworks/NousCore.framework"
ditto "$NOUSCORE" "$FRAMEWORK"
cp Resources/AppIcon.png "$CONTENTS/Resources/NewTabLogo.png"
cp -R Resources/Fonts "$CONTENTS/Resources/Fonts"
cp Resources/ThirdPartyNotices.txt "$CONTENTS/Resources/ThirdPartyNotices.txt"
for LOCALIZATION_DIR in "$PROJECT_DIR"/Resources/Localization/*.lproj(N/); do
    cp -R "$LOCALIZATION_DIR" "$CONTENTS/Resources/"
done
mkdir -p "$STAGING_DIR/icon"
xcrun swift Scripts/make-icon.swift "$STAGING_DIR/icon"
iconutil -c icns "$STAGING_DIR/icon/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"

python3 - "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist" "$CHANNEL" <<'PYINFO'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
info.pop('NousSupportsEngineSwitching', None)
if sys.argv[3] == 'chromium-preview':
    info.update(CFBundleIdentifier='com.cellier.nous-browser.chromium-preview',
                CFBundleName='Nous Browser Chromium', CFBundleDisplayName='Nous Browser Chromium',
                NousDistributionChannel='chromium-preview', SUEnableAutomaticChecks=False)
    for key in ['CFBundleDocumentTypes', 'CFBundleURLTypes', 'SUFeedURL']:
        info.pop(key, None)
assert info['NousCredentialStorage'] == 'local-key'
with open(sys.argv[2], 'wb') as f: plistlib.dump(info, f)
PYINFO

# Brand Chromium's helper apps as Nous (Dia's helpers likewise say Dia/Arc).
# macOS shows these names/icons for notifications, permissions and Activity
# Monitor. Executable names stay: Chromium launches helpers by them.
python3 - "$FRAMEWORK" "$CONTENTS/Info.plist" "$CONTENTS/Resources/AppIcon.icns" <<'BRAND'
import pathlib, plistlib, re, shutil, sys
framework, host_plist, icon = map(pathlib.Path, sys.argv[1:])
host = plistlib.loads(host_plist.read_bytes())
display = host.get('CFBundleDisplayName') or host['CFBundleName']
base = host['CFBundleIdentifier']
versions = [p for p in (framework / 'Versions').iterdir() if p.is_dir() and not p.is_symlink()]
for version in versions:
    resources = version / 'Resources'
    info = resources / 'Info.plist'
    data = plistlib.loads(info.read_bytes())
    data['CFBundleIdentifier'] = base + '.framework'
    info.write_bytes(plistlib.dumps(data))
    if (resources / 'app.icns').exists():
        shutil.copyfile(icon, resources / 'app.icns')
    for helper in (version / 'Helpers').glob('*.app'):
        contents = helper / 'Contents'
        data = plistlib.loads((contents / 'Info.plist').read_bytes())
        role = re.search(r'\((.*)\)', helper.stem)
        role = role.group(1) if role else ''
        data['CFBundleDisplayName'] = display
        data['CFBundleName'] = f'{display} Helper' + (f' ({role})' if role else '')
        suffix = re.sub(r'[^a-z0-9]+', '-', role.lower()).strip('-')
        data['CFBundleIdentifier'] = base + '.helper' + (f'.{suffix}' if suffix else '')
        data['CFBundleIconFile'] = 'app.icns'
        data.pop('CFBundleIconName', None)
        (contents / 'Resources').mkdir(exist_ok=True)
        (contents / 'Resources' / 'Assets.car').unlink(missing_ok=True)
        shutil.copyfile(icon, contents / 'Resources' / 'app.icns')
        (contents / 'Info.plist').write_bytes(plistlib.dumps(data))
BRAND

# Signing identity. A build signed by the NousStableStorageTeam team keeps one
# keychain partition across updates, so website logins survive (see
# NousStableSigning.swift); set NOUS_SIGNING_IDENTITY to that team's identity.
# Not Developer ID signed or notarized: for this Mac, not for distribution.
# Default is ad-hoc: a team identity is used only when explicitly named, so a
# build never touches a signing key (or its keychain password) by surprise.
SIGN_ID="${NOUS_SIGNING_IDENTITY:--}"
print "Signing identity: ${SIGN_ID}"
VERSIONED="$(cd "$FRAMEWORK/Versions" && print -r -- *(/[1]))"
for HELPER in "$FRAMEWORK/Versions/$VERSIONED/Helpers/"*.app(N/); do
    ENTITLEMENTS="$PROJECT_DIR/Resources/Chromium/helper-entitlements.plist"
    if [[ "$HELPER" == *"(GPU).app" || "$HELPER" == *"(Renderer).app" || "$HELPER" == *"Helper.app" ]]; then
        ENTITLEMENTS="$PROJECT_DIR/Resources/Chromium/jit-entitlements.plist"
    fi
    codesign --force --timestamp=none --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$HELPER"
done
for TOOL in "$FRAMEWORK/Versions/$VERSIONED/Helpers/"*(N.); do
    codesign --force --timestamp=none --sign "$SIGN_ID" "$TOOL"
done
for LIBRARY in "$FRAMEWORK/Versions/$VERSIONED/Libraries/"*.dylib(N); do
    codesign --force --timestamp=none --sign "$SIGN_ID" "$LIBRARY"
done
codesign --force --timestamp=none --sign "$SIGN_ID" "$FRAMEWORK"
codesign --force --timestamp=none --sign "$SIGN_ID" "$CONTENTS/MacOS/NousBrowserMCP"
codesign --force --timestamp=none --sign "$SIGN_ID" --entitlements Resources/Chromium/main-entitlements.plist "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

# Replace only the ignored build output; never the installed app or its data.
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
print "Built Nous Browser (NousCore $VERSIONED): $APP_DIR"
du -sh "$APP_DIR"
