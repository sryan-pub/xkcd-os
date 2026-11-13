#!/bin/sh
# Builds and runs scripts/checks against the app's own source files. Exits non-zero on failure.
#   scripts/run_checks.sh
set -eu
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/xkcd-checks"
xcrun swiftc -O \
    Shared/NightComic.swift \
    XKCDReader/Model/ComicUpscaler.swift \
    XKCDReader/Model/Explanation.swift \
    XKCDReader/Model/UserState.swift \
    scripts/checks/main.swift \
    -o "$OUT"
"$OUT"
