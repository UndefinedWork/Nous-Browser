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

swift_flags=()
if [[ "$CHANNEL" == chromium-preview ]]; then
    swift_flags+=(-Xswiftc -DNOUS_CHROMIUM_PREVIEW)
fi
swift build --scratch-path "$CHROMIUM_DIR/swift" --configuration "$CONFIGURATION" --jobs "${NOUS_BUILD_JOBS:-4}" "${swift_flags[@]}"
BIN_DIR="$(swift build --scratch-path "$CHROMIUM_DIR/swift" --configuration "$CONFIGURATION" --show-bin-path)"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nous-browser-package.XXXXXX")"
# Each staged bundle is ~575 MB; never leave one behind.
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME"
CONTENTS="$STAGED_APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BIN_DIR/NousBrowser" "$CONTENTS/MacOS/NousBrowser"
cp "$BIN_DIR/NousBrowserMCP" "$CONTENTS/MacOS/NousBrowserMCP"

SPARKLE="$CHROMIUM_DIR/swift/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto --norsrc --noextattr "$SPARKLE" "$CONTENTS/Frameworks/Sparkle.framework"
# Chrome resolves its framework at Contents/Frameworks/NousCore.framework/
# Versions/<chrome version>/ and its helper apps inside that directory.
FRAMEWORK="$CONTENTS/Frameworks/NousCore.framework"
ditto --norsrc --noextattr "$NOUSCORE" "$FRAMEWORK"
cp Resources/AppIcon.png "$CONTENTS/Resources/NewTabLogo.png"
cp -R Resources/QuickLinkIcons "$CONTENTS/Resources/QuickLinkIcons"
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
        # Localized names win over Info.plist: Chromium's say "Chromium", which
        # macOS showed as a second app in Notifications settings.
        for strings in (contents / 'Resources').glob('*.lproj/InfoPlist.strings'):
            strings.write_text(f'CFBundleDisplayName = "{display}";\nCFBundleName = "{display}";\n', encoding='utf-16')
BRAND

# An explicit identity takes priority. For GitHub builds, prefer this team's
# Developer ID, then fall back to the historical local signing setup.
LOCAL_SIGNING="${NOUS_LOCAL_SIGNING_DIR:-$HOME/Library/Application Support/NousSigning}"
RCODESIGN="${NOUS_RCODESIGN:-$LOCAL_SIGNING/rcodesign}"
use_local_cert=0
if [[ -r "$LOCAL_SIGNING/identity.key" && -r "$LOCAL_SIGNING/identity.crt" && -x "$RCODESIGN" ]]; then
    use_local_cert=1
fi
SIGN_ID="${NOUS_SIGNING_IDENTITY:-}"
developer_id=""
if [[ "$SIGN_ID" != "-" && ( "$CHANNEL" == github || -n "$SIGN_ID" ) ]]; then
    team="$(/usr/libexec/PlistBuddy -c 'Print :NousStableStorageTeam' "$CONTENTS/Info.plist")"
    developer_id="$(/usr/bin/security find-identity -v -p codesigning |
        /usr/bin/awk -v team="$team" -v requested="$SIGN_ID" '
            /"Developer ID Application: / && index($0, "(" team ")\"") &&
            index(tolower($0), tolower(requested)) && !found { print $2; found=1 }')"
fi
SIGN_ID="${SIGN_ID:-${developer_id:--}}"
print "Signing identity: ${SIGN_ID}"
sign=(/usr/bin/codesign --force --sign "$SIGN_ID")
runtime=()
if [[ -n "$developer_id" ]]; then
    sign+=(--timestamp)
    runtime=(--options runtime)
    # Sparkle's manually embedded distribution includes ad-hoc helpers. Sign
    # them inside out; only Downloader may need its upstream sandbox entitlement.
    sparkle_framework="$CONTENTS/Frameworks/Sparkle.framework"
    sparkle_version="$sparkle_framework/Versions/Current"
    "${sign[@]}" "${runtime[@]}" "$sparkle_version/XPCServices/Installer.xpc"
    "${sign[@]}" "${runtime[@]}" --preserve-metadata=entitlements "$sparkle_version/XPCServices/Downloader.xpc"
    "${sign[@]}" "${runtime[@]}" "$sparkle_version/Autoupdate"
    "${sign[@]}" "${runtime[@]}" "$sparkle_version/Updater.app"
    "${sign[@]}" "$sparkle_framework"
fi
VERSIONED="$(cd "$FRAMEWORK/Versions" && print -r -- *(/[1]))"
for HELPER in "$FRAMEWORK/Versions/$VERSIONED/Helpers/"*.app(N/); do
    ENTITLEMENTS="$PROJECT_DIR/Resources/Chromium/helper-entitlements.plist"
    if [[ "$HELPER" == *"GPU).app" || "$HELPER" == *"Renderer).app" || ( -z "$developer_id" && "$HELPER" == *"Helper.app" ) ]]; then
        ENTITLEMENTS="$PROJECT_DIR/Resources/Chromium/jit-entitlements.plist"
    fi
    "${sign[@]}" "${runtime[@]}" --entitlements "$ENTITLEMENTS" "$HELPER"
done
for TOOL in "$FRAMEWORK/Versions/$VERSIONED/Helpers/"*(N.); do
    "${sign[@]}" "${runtime[@]}" "$TOOL"
done
for LIBRARY in "$FRAMEWORK/Versions/$VERSIONED/Libraries/"*.dylib(N); do
    "${sign[@]}" "$LIBRARY"
done
"${sign[@]}" "$FRAMEWORK"
"${sign[@]}" "${runtime[@]}" "$CONTENTS/MacOS/NousBrowserMCP"
"${sign[@]}" "${runtime[@]}" --entitlements Resources/Chromium/main-entitlements.plist "$STAGED_APP"
# Screen Recording (and other privacy) permissions follow the app's
# designated requirement. Ad-hoc, that is the build's code hash, so every
# update asked again. A self-signed local certificate (a key file, never a
# keychain item) gives every build the same requirement:
#   identifier "com.cellier.nous-browser" and certificate root = H"<cert>".
# Only the outer app is re-signed; nested code keeps the signatures above.
if [[ "$SIGN_ID" == "-" && "$use_local_cert" == 1 ]]; then
    "$RCODESIGN" sign --exclude '**' \
        --entitlements-xml-file Resources/Chromium/main-entitlements.plist \
        --pem-file "$LOCAL_SIGNING/identity.key" --pem-file "$LOCAL_SIGNING/identity.crt" \
        "$STAGED_APP" >/dev/null
    print "Signed with the local certificate: $(codesign -d -r- "$STAGED_APP" 2>&1 | tail -1)"
elif [[ "$SIGN_ID" == "-" ]]; then
    print -u2 "Ad-hoc signature for local testing. To package a release, configure the Nous release signing identity."
fi
codesign --verify --deep --strict "$STAGED_APP"

# Replace only the ignored build output; never the installed app or its data.
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
print "Built Nous Browser (NousCore $VERSIONED): $APP_DIR"
du -sh "$APP_DIR"
