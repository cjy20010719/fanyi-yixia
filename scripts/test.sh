#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p dist/tests
frameworks=(-framework Cocoa -framework ApplicationServices -framework Vision -framework Carbon -framework NaturalLanguage -framework ServiceManagement -framework ScreenCaptureKit -framework CoreImage -framework AVFAudio -F "$PWD/Vendor/Sparkle" -framework Sparkle -Wl,-rpath,"$PWD/Vendor/Sparkle")
for test in youdao-reliability translation-throttle selection-translation compatibility input-return input-auto interaction login-startup window-switcher capture-interaction capture-snapshot capture-color capture-render status-menu menu-tracking shortcuts shortcut-integration appearance-preview bubble-styles menu-dismiss; do
  clang -fobjc-arc -fblocks -O1 -mmacosx-version-min=13.0 -Wno-deprecated-declarations "${frameworks[@]}" "tests/$test.m" -o "dist/tests/$test"
  "dist/tests/$test"
done
python3 scripts/verify-release.py --source-only
