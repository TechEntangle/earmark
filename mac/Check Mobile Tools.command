#!/bin/bash
# Earmark: lists the developer tools on this Mac for building the iPhone and Android app.
# Read-only: it installs and changes nothing. Results are saved next to this file.
OUT="$(cd "$(dirname "$0")" && pwd)/tools_check.txt"
{
  echo "== date"; date
  echo "== macOS"; sw_vers 2>&1; uname -m
  echo "== Xcode"; xcodebuild -version 2>&1; xcode-select -p 2>&1
  echo "== Xcode license/first launch"; /usr/bin/xcrun --find simctl 2>&1
  echo "== iOS simulators"; xcrun simctl list runtimes 2>&1 | head -12
  echo "== Flutter"; for f in "$(command -v flutter)" "$HOME/development/flutter/bin/flutter" "$HOME/flutter/bin/flutter" /opt/homebrew/bin/flutter /usr/local/bin/flutter; do [ -x "$f" ] && { echo "found: $f"; "$f" --version 2>&1 | head -4; break; }; done
  echo "== Dart"; command -v dart && dart --version 2>&1
  echo "== CocoaPods"; command -v pod && pod --version 2>&1
  echo "== Homebrew"; command -v brew || ls /opt/homebrew/bin/brew 2>&1
  echo "== Android Studio"; ls -d "/Applications/Android Studio.app" 2>&1; defaults read "/Applications/Android Studio.app/Contents/Info" CFBundleShortVersionString 2>&1
  echo "== Android SDK"; for d in "$ANDROID_HOME" "$HOME/Library/Android/sdk"; do [ -d "$d" ] && { echo "sdk: $d"; ls "$d"; ls "$d/platforms" "$d/build-tools" "$d/system-images" 2>&1 | head -20; "$d/emulator/emulator" -list-avds 2>&1; break; }; done
  echo "== Java"; /usr/libexec/java_home -V 2>&1 | head -6; java -version 2>&1 | head -3
  echo "== git"; git --version 2>&1
  echo "== disk free"; df -h "$HOME" | tail -1
  echo "== done"
} > "$OUT" 2>&1
echo "Saved to $OUT. You can close this window."
