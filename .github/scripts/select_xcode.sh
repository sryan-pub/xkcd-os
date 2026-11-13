#!/bin/bash
# Selects the newest Xcode on a GitHub macOS runner.
#   .github/scripts/select_xcode.sh stable   newest release
#   .github/scripts/select_xcode.sh beta     newest beta, or the newest release if the image has no beta
# The runner images name betas and release candidates like Xcode_27_beta_3.app.
set -euo pipefail
want="${1:-stable}"

list=""
for app in /Applications/Xcode*.app; do
    [ -L "$app" ] && continue
    [ -f "$app/Contents/version.plist" ] || continue
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/version.plist")
    case "$(basename "$app" | tr '[:upper:]' '[:lower:]')" in
        *beta* | *release_candidate* | *_rc*) kind=beta ;;
        *) kind=stable ;;
    esac
    list+="$version $kind $app"$'\n'
done
echo "Xcodes on this image:"
printf '%s' "$list" | sort -V

pick=$(printf '%s' "$list" | grep " $want " | sort -V | tail -1 || true)
if [ -z "$pick" ] && [ "$want" = beta ]; then
    pick=$(printf '%s' "$list" | sort -V | tail -1)
    echo "::notice::No Xcode beta on this image, using the newest release instead."
fi
[ -n "$pick" ] || { echo "::error::No $want Xcode found"; exit 1; }

app="${pick#* * }"
sudo xcode-select -s "$app"
xcodebuild -version
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "Xcode: $(xcodebuild -version | tr '\n' ' ')" >> "$GITHUB_STEP_SUMMARY"
fi
