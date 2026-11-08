#!/bin/zsh
# Builds build/FanaMacFF.plugin, the CSL DD's force feedback plug-in for macOS.
# Both architectures: native games run arm64, CrossOver's Wine runs x86_64.
# app/build.sh copies it into FanaMac.app/Contents/PlugIns.
set -euo pipefail
cd "$(dirname "$0")"
SDK="${FANAMAC_SDK:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | head -1)}"
[[ -z "$SDK" ]] && SDK="$(xcrun --show-sdk-path)"

# ./build.sh test: the force calculation tests, on the Mac.
if [[ "${1:-}" == "test" ]]; then
  mkdir -p build
  cc -isysroot "$SDK" -Wall -Wextra -Isrc tests/test_ffcalc.c src/ffcalc.c -lm -o build/test_ffcalc
  exec build/test_ffcalc
fi

P=build/FanaMacFF.plugin
rm -rf build
mkdir -p "$P/Contents/MacOS"
cp Info.plist "$P/Contents/"
cc -isysroot "$SDK" -O2 -Wall -Wextra -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  src/plugin.c src/ffcalc.c src/hidfilter.c \
  -framework CoreFoundation -framework IOKit -o "$P/Contents/MacOS/FanaMacFF"
codesign --force --sign - "$P" >/dev/null
echo "Built $P"
