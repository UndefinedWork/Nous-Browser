#!/bin/zsh
# Unit tests. NousCore's install name is app-relative (@executable_path), which
# does not exist under the test runner, so the test bundle is pointed at the
# SDK copy through its rpath before running.
set -euo pipefail
cd "${0:A:h:h}"
swift build --build-tests
BUNDLE=".build/out/Products/Debug/NousBrowserTests.xctest/Contents/MacOS/NousBrowserTests"
CURRENT=$(otool -L "$BUNDLE" | awk '/NousCore.framework/ {print $1; exit}')
if [[ "$CURRENT" == @executable_path/* ]]; then
    install_name_tool -change "$CURRENT" "@rpath/${CURRENT#@executable_path/../Frameworks/}" "$BUNDLE" 2>/dev/null
    codesign -f -s - "$BUNDLE" 2>/dev/null
fi
swift test --skip-build "$@"
