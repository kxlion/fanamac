#!/bin/zsh
# Builds the downloadable release: build/FanaMac-<version>.dmg, with the app
# (force feedback plug-in included) and a shortcut to Applications.
#   ./release.sh
# Publish it with:
#   gh release create v<version> build/FanaMac-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

app/build.sh

APP=app/build/FanaMac.app
[[ -d "$APP/Contents/PlugIns/FanaMacFF.plugin" ]] || { echo "The plug-in is missing from $APP." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

DMG="build/FanaMac-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/FanaMac.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p build
hdiutil create -quiet -volname "FanaMac $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
echo "Built $DMG"
