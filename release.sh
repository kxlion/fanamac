#!/bin/zsh
# Builds the downloadable release: build/FanaMac-<version>.dmg, with the app
# (force feedback plug-in included) and a shortcut to Applications.
#   ./release.sh
# The version is the one line of the VERSION file. Publish with:
#   gh release create v<version> build/FanaMac-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(<VERSION)"
# A published version is never built again: raise VERSION first.
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
  echo "v$VERSION is already tagged. Raise the number in VERSION." >&2
  exit 1
fi

app/build.sh

APP=app/build/FanaMac.app
[[ -d "$APP/Contents/PlugIns/FanaMacFF.plugin" ]] || { echo "The plug-in is missing from $APP." >&2; exit 1; }

DMG="build/FanaMac-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/FanaMac.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p build
hdiutil create -quiet -volname "FanaMac $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
echo "Built $DMG"
