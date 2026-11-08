#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
zsh scripts/fetch-sparkle.sh
APP="${YI_APP_PATH:-$PWD/dist/翻译一下.app}"
sparkle_path="$PWD/Vendor/Sparkle"
sdk_path="${YI_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
architectures=(${=YI_ARCHS:-arm64 x86_64})
architecture_flags=()
for architecture in "${architectures[@]}"; do
  case "$architecture" in
    arm64|x86_64) architecture_flags+=(-arch "$architecture") ;;
    *) print -u2 "Unsupported architecture: $architecture"; exit 1 ;;
  esac
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
ditto "$sparkle_path/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Wno-unused-parameter -Wno-incompatible-pointer-types "${architecture_flags[@]}" -mmacosx-version-min=13.0 -isysroot "$sdk_path" Sources/main.m -o "$APP/Contents/MacOS/翻译一下" -framework Cocoa -framework ApplicationServices -framework Vision -framework Carbon -framework NaturalLanguage -framework ServiceManagement -framework ScreenCaptureKit -framework CoreImage -framework AVFAudio -F "$sparkle_path" -framework Sparkle -Wl,-rpath,@executable_path/../Frameworks
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
codesign --force --sign - --identifier local.chenshanglong.Translate "$APP"
echo "$APP"
