#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
FRAMEWORKS_DIR="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks"
TESTING_PLUGIN="$DEVELOPER_DIR_PATH/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
HOST_DIR="$PROJECT_DIR/.build/password-autofill-integration"
APP_DIR="$HOST_DIR/Password Autofill Integration.app"

mkdir -p "$APP_DIR/Contents/MacOS"
# Reuse the actual cases and fixture; only their application-module import differs.
sed '/^@testable import NousBrowser$/d' "$PROJECT_DIR/Tests/NousBrowserTests/BrowserPasswordAutofillTests.swift" > "$HOST_DIR/BrowserPasswordAutofillTests.swift"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.cellier.nous-browser.autofill-integration-tests</string>
<key>CFBundleName</key><string>Password Autofill Integration</string>
<key>CFBundleExecutable</key><string>PasswordAutofillIntegration</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

xcrun swiftc -parse-as-library -swift-version 6 -D DEBUG \
    -sdk "$SDK_PATH" -target "$(uname -m)-apple-macos26.0" \
    -F "$FRAMEWORKS_DIR" -framework Testing \
    -load-plugin-library "$TESTING_PLUGIN" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS_DIR" \
    "$PROJECT_DIR/Sources/NousBrowser/BrowserPasswordAutofill.swift" \
    "$HOST_DIR/BrowserPasswordAutofillTests.swift" \
    "$PROJECT_DIR/Tests/Support/PasswordAutofillAppMain.swift" \
    -o "$APP_DIR/Contents/MacOS/PasswordAutofillIntegration"
codesign --force --sign - "$APP_DIR"
rm -f "$HOST_DIR/results.xml"
NOUS_BROWSER_PASSWORD_AUTOFILL_XUNIT="$HOST_DIR/results.xml" \
    "$APP_DIR/Contents/MacOS/PasswordAutofillIntegration" 2>&1 | tee "$HOST_DIR/results.log"
/usr/bin/python3 - "$HOST_DIR/results.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall('.//testcase')
failures = root.findall('.//failure') + root.findall('.//error')
skips = root.findall('.//skipped')
if len(cases) < 10 or failures or skips:
    raise SystemExit(f'Incomplete integration results: cases={len(cases)} failures={len(failures)} skipped={len(skips)}')
print(f'Verified integration xUnit: {len(cases)} cases, no failures or skips.')
PY
printf '%s\n' "Results: $HOST_DIR/results.log" "xUnit: $HOST_DIR/results.xml"
