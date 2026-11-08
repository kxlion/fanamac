#!/bin/zsh
# Builds FanaMac.app without Xcode: swiftc + a hand-made bundle.
#   ./build.sh          build the app into build/FanaMac.app
#   ./build.sh test     run the hardware-free tests
#   ./build.sh cli      build the command-line tool into build/fanamac
set -euo pipefail
cd "$(dirname "$0")"

# The Command Line Tools ship a newer default SDK than their compiler; pin the one that matches.
SDK="${FANAMAC_SDK:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | head -1)}"
[[ -z "$SDK" ]] && SDK="$(xcrun --show-sdk-path)"
SWIFTC=(swiftc -sdk "$SDK" -target arm64-apple-macos14)
mkdir -p .build

if [[ "${1:-}" == "test" ]]; then
  "${SWIFTC[@]}" Sources/FanaMacCore/*.swift Sources/FanaMacCLI/Record.swift Tests/FanaMacCoreTests/main.swift -o .build/tests
  exec .build/tests
fi

if [[ "${1:-}" == "cli" ]]; then
  mkdir -p build
  "${SWIFTC[@]}" -O -module-name fanamac Sources/FanaMacCore/*.swift Sources/FanaMacCLI/*.swift \
    Sources/FanaMac/{Wheelbase,NativeForce,ForceOutput,Recorder}.swift -o build/fanamac
  echo "Built build/fanamac"
  exit 0
fi

# While FanaMac runs, the base's HID entry points at the plug-in inside this app:
# deleting it would cut the wheel's inputs for whatever opens the base next.
if pgrep -xq FanaMac; then
  echo "Quit FanaMac before building." >&2
  exit 1
fi

APP=build/FanaMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

"${SWIFTC[@]}" -O -parse-as-library -module-name FanaMac \
  Sources/FanaMacCore/*.swift Sources/FanaMac/*.swift -o "$APP/Contents/MacOS/FanaMac"

if [[ ! -f .build/AppIcon.icns || Icon/make_icon.swift -nt .build/AppIcon.icns ]]; then
  rm -rf .build/AppIcon.iconset
  "${SWIFTC[@]}" Icon/make_icon.swift -o .build/make_icon
  .build/make_icon .build/AppIcon.iconset
  iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Your own images: drop wheelbase.png (and others) into Images/.
find Images -maxdepth 1 -name '*.png' -exec cp {} "$APP/Contents/Resources/" \; 2>/dev/null || true

# The base's force feedback plug-in for macOS (build it first: ../ffplugin/build.sh).
if [[ -d ../ffplugin/build/FanaMacFF.plugin ]]; then
  mkdir -p "$APP/Contents/PlugIns"
  cp -R ../ffplugin/build/FanaMacFF.plugin "$APP/Contents/PlugIns/"
else
  echo "No force feedback plug-in in this build: run ../ffplugin/build.sh first."
fi

# Fanatec's recommended settings per game (see docs/PRESETS.md).
cp Presets/*.json "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FanaMac</string>
  <key>CFBundleDisplayName</key><string>FanaMac</string>
  <key>CFBundleIdentifier</key><string>app.fanamac.FanaMac</string>
  <key>CFBundleExecutable</key><string>FanaMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
