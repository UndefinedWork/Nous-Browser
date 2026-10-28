#!/bin/zsh
set -euo pipefail
# Run after package-release.sh. Only the versioned ZIP is offered to Sparkle.
PROJECT_DIR="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
ARCHIVE="$PROJECT_DIR/dist/Nous-Browser-$VERSION-macOS-arm64.zip"
TOOLS="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"
[[ -f "$ARCHIVE" && -x "$TOOLS/generate_appcast" ]] || { print -u2 'Build and package the release first.'; exit 1; }
SIGNING_KEY="${NOUS_UPDATE_SIGNING_KEY:-$HOME/.local/share/NousBrowserRelease/update-signing-key}"
[[ -f "$SIGNING_KEY" ]] || { print -u2 'Update signing key is missing. See Docs/Updates.md.'; exit 1; }
xcrun swift "$PROJECT_DIR/Scripts/verify-update-key.swift" "$SIGNING_KEY" "$PROJECT_DIR/Resources/Info.plist"
STAGING="$(mktemp -d "$PROJECT_DIR/.build/update-feed.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp "$ARCHIVE" "$STAGING/"
"$TOOLS/generate_appcast" --ed-key-file "$SIGNING_KEY" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/UndefinedWork/Nous-Browser/releases/download/v$VERSION/" "$STAGING"
[[ -s "$STAGING/appcast.xml" ]] || { print -u2 'Signed feed was not produced.'; exit 1; }
cp "$STAGING/appcast.xml" "$PROJECT_DIR/dist/appcast.xml"
print 'Signed update feed: dist/appcast.xml (upload alongside the ZIP in the same stable GitHub Release)'
