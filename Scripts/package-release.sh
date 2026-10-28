#!/bin/zsh
set -euo pipefail

# Package an already-built app. This script never builds, installs, or launches it.
PROJECT_DIR="${0:A:h:h}"
APP_NAME="Nous Browser.app"
APP_DIR="$PROJECT_DIR/build/$APP_NAME"
SOURCE_INFO="$PROJECT_DIR/Resources/Info.plist"
DIST_DIR="$PROJECT_DIR/dist"

fail() { print -u2 -- "Release packaging failed: $*"; exit 1; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }

[[ -d "$APP_DIR" ]] || fail "Build the app first: $APP_DIR"
[[ -f "$SOURCE_INFO" ]] || fail "Missing project Info.plist."

INFO_PATH="$APP_DIR/Contents/Info.plist"
VERSION="$(plist_value "$INFO_PATH" CFBundleShortVersionString)"
BUILD_NUMBER="$(plist_value "$INFO_PATH" CFBundleVersion)"
EXECUTABLE_NAME="$(plist_value "$INFO_PATH" CFBundleExecutable)"
MINIMUM_MACOS="$(plist_value "$INFO_PATH" LSMinimumSystemVersion)"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
MCP_EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/NousBrowserMCP"

# Match the current source metadata so a stale build cannot become a new release.
# The payload is copied exclusively from the app bundle, never from user folders.
/usr/bin/python3 - "$APP_DIR" "$SOURCE_INFO" <<'PY'
import os
from pathlib import Path
import plistlib
import re
import stat
import sys

app = Path(sys.argv[1])
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
with Path(sys.argv[2]).open('rb') as stream:
    expected = plistlib.load(stream)
for key in ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleShortVersionString',
            'CFBundleVersion', 'LSMinimumSystemVersion'):
    if not info.get(key) or info[key] != expected.get(key):
        raise SystemExit(f'Stale or invalid app metadata: {key}')
if info['CFBundleIdentifier'] != 'com.cellier.nous-browser' or info.get('CFBundlePackageType') != 'APPL':
    raise SystemExit('Unexpected application identity.')
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9.]+)?', info['CFBundleShortVersionString']):
    raise SystemExit('Version is not safe for a release asset filename.')
executable = info['CFBundleExecutable']
if executable != 'NousBrowser':
    raise SystemExit('Unexpected executable name.')
binary = app / 'Contents/MacOS' / executable
if not binary.is_file() or not os.access(binary, os.X_OK) or binary.stat().st_mode & stat.S_IWOTH:
    raise SystemExit('The app executable is missing, not executable, or world-writable.')
helper = app / 'Contents/MacOS/NousBrowserMCP'
if not helper.is_file() or not os.access(helper, os.X_OK) or helper.stat().st_mode & stat.S_IWOTH:
    raise SystemExit('The MCP helper is missing, not executable, or world-writable.')
for path in app.rglob('*'):
    relative = path.relative_to(app)
    if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
        raise SystemExit(f'App bundle contains an external symlink: {relative}')
    # These are runtime/user-data locations or accidental development artifacts,
    # none of which belong to this application's build output.
    if set(relative.parts) & {'.git', '.env', '.DS_Store', 'Preferences', 'Cookies',
                              'WebKit', 'Local Storage', 'Application Support', 'Login Data'}:
        raise SystemExit(f'Unexpected non-application content: {relative}')
    if path.suffix.lower() in {'.sqlite', '.sqlite3', '.db', '.keychain', '.keychain-db', '.csv'}:
        raise SystemExit(f'Unexpected data file in app bundle: {relative}')
print(f"App metadata: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), "
      f"macOS {info['LSMinimumSystemVersion']} or later")
PY

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
SIGNATURE_DETAILS="$(/usr/bin/codesign --display --verbose=4 "$APP_DIR" 2>&1)"
print -r -- "$SIGNATURE_DETAILS"
if [[ "$SIGNATURE_DETAILS" == *"Signature=adhoc"* ]]; then
    print -u2 -- "Distribution notice: ad hoc signed; not Developer ID signed or notarized."
    print -u2 -- "Internet downloads may be blocked by Gatekeeper on first open."
fi

ARCHITECTURES="$(/usr/bin/lipo -archs "$EXECUTABLE_PATH" | /usr/bin/tr ' ' '\n' | /usr/bin/sort | /usr/bin/xargs)"
case "$ARCHITECTURES" in
    arm64) ARCHITECTURE_LABEL="arm64" ;;
    x86_64) ARCHITECTURE_LABEL="x86_64" ;;
    'arm64 x86_64') ARCHITECTURE_LABEL="universal" ;;
    *) fail "Unsupported executable architectures: $ARCHITECTURES" ;;
esac
/usr/bin/file "$EXECUTABLE_PATH"
print -- "Actual architectures: $ARCHITECTURES"

ASSET_BASENAME="Nous-Browser-$VERSION-macOS-$ARCHITECTURE_LABEL"
EXECUTABLE_SHA="$(/usr/bin/shasum -a 256 "$EXECUTABLE_PATH" | /usr/bin/awk '{print $1}')"
MCP_EXECUTABLE_SHA="$(/usr/bin/shasum -a 256 "$MCP_EXECUTABLE_PATH" | /usr/bin/awk '{print $1}')"
[[ "$(/usr/bin/lipo -archs "$MCP_EXECUTABLE_PATH" | /usr/bin/tr ' ' '\n' | /usr/bin/sort | /usr/bin/xargs)" == "$ARCHITECTURES" ]] || fail "MCP helper architectures do not match the app."
/usr/bin/codesign --verify --strict "$MCP_EXECUTABLE_PATH"
INFO_SHA="$(/usr/bin/shasum -a 256 "$INFO_PATH" | /usr/bin/awk '{print $1}')"
mkdir -p "$PROJECT_DIR/.build" "$DIST_DIR"
WORK_DIR="$(/usr/bin/mktemp -d "$PROJECT_DIR/.build/release-package.XXXXXX")"
PAYLOAD_DIR="$WORK_DIR/dmg-content"
MOUNT_DIR="$WORK_DIR/mounted"
MOUNTED=0

cleanup() {
    if (( MOUNTED )); then
        if ! /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet; then
            print -u2 -- "Could not detach release verification image; preserved $WORK_DIR"
            return
        fi
    fi
    /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_packaged_app() {
    local candidate="$1"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$candidate"
    [[ "$(/usr/bin/lipo -archs "$candidate/Contents/MacOS/$EXECUTABLE_NAME" | /usr/bin/tr ' ' '\n' | /usr/bin/sort | /usr/bin/xargs)" == "$ARCHITECTURES" ]] || fail "Packaged architectures changed."
    [[ "$(/usr/bin/shasum -a 256 "$candidate/Contents/MacOS/$EXECUTABLE_NAME" | /usr/bin/awk '{print $1}')" == "$EXECUTABLE_SHA" ]] || fail "Packaged executable changed."
    [[ "$(/usr/bin/shasum -a 256 "$candidate/Contents/MacOS/NousBrowserMCP" | /usr/bin/awk '{print $1}')" == "$MCP_EXECUTABLE_SHA" ]] || fail "Packaged MCP helper changed."
    /usr/bin/codesign --verify --strict "$candidate/Contents/MacOS/NousBrowserMCP"
    [[ "$(/usr/bin/shasum -a 256 "$candidate/Contents/Info.plist" | /usr/bin/awk '{print $1}')" == "$INFO_SHA" ]] || fail "Packaged metadata changed."
}

mkdir -p "$PAYLOAD_DIR" "$MOUNT_DIR"
# Omit extended filesystem metadata and resource forks from this developer build.
# The original bundle is never modified, and its code signature must still verify.
/usr/bin/ditto --noextattr --norsrc "$APP_DIR" "$PAYLOAD_DIR/$APP_NAME"
verify_packaged_app "$PAYLOAD_DIR/$APP_NAME"
/bin/ln -s /Applications "$PAYLOAD_DIR/Applications"

/usr/bin/hdiutil create -volname "Nous Browser $VERSION" \
    -srcfolder "$PAYLOAD_DIR" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
    "$WORK_DIR/$ASSET_BASENAME.dmg"
/usr/bin/hdiutil verify "$WORK_DIR/$ASSET_BASENAME.dmg"
MOUNTED=1
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" \
    "$WORK_DIR/$ASSET_BASENAME.dmg" > "$WORK_DIR/mount.log"

/usr/bin/python3 - "$MOUNT_DIR" "$APP_NAME" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1])
expected = {sys.argv[2], 'Applications'}
# HFS+ may add its own private directory; it is not installation payload.
filesystem_metadata = {'.fseventsd', '.Trashes', '.HFS+ Private Directory Data\r'}
actual = {item.name for item in root.iterdir()} - filesystem_metadata
if actual != expected or os.readlink(root / 'Applications') != '/Applications':
    raise SystemExit(f'Unexpected disk-image payload: {sorted(actual)}')
print('Verified read-only DMG: app bundle and /Applications shortcut only.')
PY
verify_packaged_app "$MOUNT_DIR/$APP_NAME"
/usr/bin/hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0

/usr/bin/ditto -c -k --keepParent --noextattr --norsrc \
    "$PAYLOAD_DIR/$APP_NAME" "$WORK_DIR/$ASSET_BASENAME.zip"
mkdir -p "$WORK_DIR/zip-verification"
/usr/bin/ditto -x -k "$WORK_DIR/$ASSET_BASENAME.zip" "$WORK_DIR/zip-verification"
[[ "$(/bin/ls -A "$WORK_DIR/zip-verification")" == "$APP_NAME" ]] || fail "Unexpected ZIP payload."
verify_packaged_app "$WORK_DIR/zip-verification/$APP_NAME"

(
    cd "$WORK_DIR"
    /usr/bin/shasum -a 256 "$ASSET_BASENAME.dmg" "$ASSET_BASENAME.zip" > SHA256SUMS.txt
)
for asset in "$ASSET_BASENAME.dmg" "$ASSET_BASENAME.zip" SHA256SUMS.txt; do
    /bin/chmod 644 "$WORK_DIR/$asset"
    /bin/mv -f "$WORK_DIR/$asset" "$DIST_DIR/$asset"
done

print -- "Release assets: version $VERSION ($BUILD_NUMBER), macOS $MINIMUM_MACOS+, $ARCHITECTURES"
for asset in "$ASSET_BASENAME.dmg" "$ASSET_BASENAME.zip" SHA256SUMS.txt; do
    /usr/bin/stat -f '%N — %z bytes' "$DIST_DIR/$asset"
done
/bin/cat "$DIST_DIR/SHA256SUMS.txt"

# Every release also carries its authenticated updater feed.
zsh "$PROJECT_DIR/Scripts/generate-update-feed.sh"
