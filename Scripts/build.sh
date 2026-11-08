#!/bin/zsh
set -euo pipefail
# Chromium is the only shipping engine. Output remains in the build directory;
# replacing an installed application is a separate, verified operation.
PROJECT_DIR="${0:A:h:h}"
exec zsh "$PROJECT_DIR/Scripts/build-chromium.sh" "$@"
