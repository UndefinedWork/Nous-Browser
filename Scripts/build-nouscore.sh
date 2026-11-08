#!/bin/zsh
# Builds NousCore.framework: Chromium's //chrome framework renamed, with the
# //nous embedding layer compiled in (the Dia/ArcCore model, no CEF).
#
# Inputs
#   NOUS_CHROMIUM_SRC   Chromium checkout (default: the pinned 156.0.8078.80 tree)
#   NOUS_CHROMIUM_OUT   GN output directory name (default: Nous_Release_arm64)
#   NOUS_BUILD_JOBS     compile jobs (default: 12)
# Output
#   .build/nouscore/sdk/NousCore.framework  (binary + Helpers + Headers + Modules)
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CACHE="$HOME/Library/Caches/NousCEF/156.0.8078.80-arm64-codecs"
SRC="${NOUS_CHROMIUM_SRC:-$CACHE/chromium/src}"
OUT_NAME="${NOUS_CHROMIUM_OUT:-Nous_Release_arm64}"
OUT="$SRC/out/$OUT_NAME"
DEPOT="${NOUS_DEPOT_TOOLS:-$CACHE/depot_tools}"
SDK="$PROJECT_DIR/.build/nouscore/sdk"
export PATH="$DEPOT:$PATH" DEPOT_TOOLS_UPDATE=0

[[ -f "$SRC/chrome/VERSION" ]] || { print -u2 "Chromium source not found: $SRC"; exit 1; }

# 1. //nous lives in this repository; Chromium sees it as a top-level dir.
ln -sfn "$PROJECT_DIR/Engine/nous" "$SRC/nous"

# 2. Chromium patches (idempotent exact-text edits; fails loudly on a roll).
python3 "$PROJECT_DIR/Engine/patches/apply_chromium_patches.py" "$SRC"

# 3. Configure.
mkdir -p "$OUT"
if [[ ! -f "$OUT/args.gn" ]]; then
    cp "$PROJECT_DIR/Engine/args.gn" "$OUT/args.gn"
fi
grep -q '^nous_core = true' "$OUT/args.gn" || { print -u2 "$OUT/args.gn must set nous_core = true"; exit 1; }
(cd "$SRC" && gn gen "out/$OUT_NAME" >/dev/null)

# 4. Build the framework (it bundles its own helper apps).
(cd "$SRC" && autoninja -C "out/$OUT_NAME" -j "${NOUS_BUILD_JOBS:-12}" chrome_framework)

# 5. Assemble a linkable SDK copy with the public headers and module map.
rm -rf "$SDK"
mkdir -p "$SDK"
ditto "$OUT/NousCore.framework" "$SDK/NousCore.framework"
VERSIONED="$SDK/NousCore.framework/Versions/Current"
mkdir -p "$VERSIONED/Headers" "$VERSIONED/Modules"
cp "$PROJECT_DIR"/Engine/nous/public/*.h "$VERSIONED/Headers/"
cp "$PROJECT_DIR/Engine/nous/public/module.modulemap" "$VERSIONED/Modules/"
ln -sfn Versions/Current/Headers "$SDK/NousCore.framework/Headers"
ln -sfn Versions/Current/Modules "$SDK/NousCore.framework/Modules"
print "NousCore SDK: $SDK/NousCore.framework ($(cat "$SRC/chrome/VERSION" | tr '\n' ' '))"
