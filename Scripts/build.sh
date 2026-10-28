#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_CONFIGURATION="${CONFIGURATION:-release}"
APP_DIR="$PROJECT_DIR/build/Nous Browser.app"

cd "$PROJECT_DIR"
swift build --configuration "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build --configuration "$BUILD_CONFIGURATION" --show-bin-path)"

STAGING_DIR="$(mktemp -d "$PROJECT_DIR/.build/app-package.XXXXXX")"
STAGED_APP_DIR="$STAGING_DIR/Nous Browser.app"
PREVIOUS_APP_DIR="$STAGING_DIR/Nous Browser.previous.app"
ICON_WORK_DIR="$STAGING_DIR/app-icon"

mkdir -p "$STAGED_APP_DIR/Contents/MacOS" "$STAGED_APP_DIR/Contents/Resources" "$ICON_WORK_DIR" "$PROJECT_DIR/build"
mkdir -p "$STAGED_APP_DIR/Contents/Frameworks"
# Preserve Sparkle's signed nested helpers and framework symlinks.
SPARKLE_FRAMEWORK="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { print -u2 "Sparkle framework missing"; exit 1; }
ditto "$SPARKLE_FRAMEWORK" "$STAGED_APP_DIR/Contents/Frameworks/Sparkle.framework"
cp "$BIN_DIR/NousBrowser" "$STAGED_APP_DIR/Contents/MacOS/NousBrowser"
cp "$BIN_DIR/NousBrowserMCP" "$STAGED_APP_DIR/Contents/MacOS/NousBrowserMCP"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP_DIR/Contents/Info.plist"
for LOCALIZATION_DIR in "$PROJECT_DIR"/Resources/Localization/*.lproj(N/); do
    cp -R "$LOCALIZATION_DIR" "$STAGED_APP_DIR/Contents/Resources/"
done
cp "$PROJECT_DIR/Resources/AppIcon.png" "$STAGED_APP_DIR/Contents/Resources/NewTabLogo.png"
cp -R "$PROJECT_DIR/Resources/Fonts" "$STAGED_APP_DIR/Contents/Resources/Fonts"
cp "$PROJECT_DIR/Resources/ThirdPartyNotices.txt" "$STAGED_APP_DIR/Contents/Resources/ThirdPartyNotices.txt"
xcrun swift "$PROJECT_DIR/Scripts/make-icon.swift" "$ICON_WORK_DIR"
iconutil -c icns "$ICON_WORK_DIR/AppIcon.iconset" -o "$STAGED_APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$STAGED_APP_DIR/Contents/MacOS/NousBrowserMCP"
codesign --force --sign - "$STAGED_APP_DIR"
codesign --verify --deep --strict "$STAGED_APP_DIR"

# Swap the complete signed bundle in one filesystem operation. The previous
# bundle stays intact in staging, including any executable still running from it.
xcrun swift - "$STAGED_APP_DIR" "$APP_DIR" "$PREVIOUS_APP_DIR" <<'SWIFT'
import Darwin
import Foundation

let staged = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
let previous = CommandLine.arguments[3]
let manager = FileManager.default
if manager.fileExists(atPath: output) {
    guard renamex_np(staged, output, UInt32(RENAME_SWAP)) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    try manager.moveItem(atPath: staged, toPath: previous)
    print("Previous app preserved: \(previous)")
} else {
    try manager.moveItem(atPath: staged, toPath: output)
}
SWIFT

printf '%s\n' "Built: $APP_DIR"
