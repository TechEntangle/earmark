#!/bin/bash
# Earmark: gets this Mac ready to build the Earmark phone app, then opens it in Xcode.
# Installs Flutter into ~/development/flutter if it isn't installed (about 2 GB, once).
# Everything it prints is also saved to phone_app_setup.txt next to this file.
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/phone_app_setup.txt"
exec > >(tee "$LOG") 2>&1
set -u
echo "== Earmark phone app setup  $(date)"

FL="$(command -v flutter || true)"
for c in "$HOME/development/flutter/bin/flutter" "$HOME/flutter/bin/flutter"; do [ -z "$FL" ] && [ -x "$c" ] && FL="$c"; done
if [ -z "$FL" ]; then
  echo "== Installing Flutter (stable) into ~/development/flutter"
  mkdir -p "$HOME/development"
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$HOME/development/flutter" || { echo "Could not download Flutter."; exit 1; }
  FL="$HOME/development/flutter/bin/flutter"
  if ! grep -q 'development/flutter/bin' "$HOME/.zprofile" 2>/dev/null; then
    echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> "$HOME/.zprofile"
    echo "   added Flutter to your PATH in ~/.zprofile (new Terminal windows will have it)"
  fi
fi
echo "== Flutter: $FL"
"$FL" config --no-analytics >/dev/null 2>&1
"$FL" --disable-analytics >/dev/null 2>&1
"$FL" config --enable-swift-package-manager >/dev/null 2>&1
"$FL" --version

echo "== Unpacking the app source into $HERE/mobile"
if [ -f "$HERE/earmark-mobile.tar.gz" ]; then
  tar -xzf "$HERE/earmark-mobile.tar.gz" -C "$HERE" && rm -f "$HERE/earmark-mobile.tar.gz"
fi
cd "$HERE/mobile" || { echo "App source missing."; exit 1; }

echo "== Getting packages"
"$FL" pub get || exit 1
echo "== Downloading iPhone build tools (first time only, a few minutes)"
"$FL" precache --ios
echo "== Xcode"
xcodebuild -version || echo "Xcode command line tools not set up: open Xcode once and accept the licence."
echo "== Checking the setup"
"$FL" doctor
echo "== Preparing the Xcode project"
"$FL" build ios --config-only --debug --no-codesign || echo "(Xcode will finish this when you press Run)"
open ios/Runner.xcworkspace
echo
echo "Xcode is opening. Next:"
echo "  1. In Xcode's left sidebar click 'Runner', then the 'Signing & Capabilities' tab."
echo "  2. Team: choose your Apple developer team."
echo "  3. At the top, choose your iPhone as the destination (connect it with a cable the first time)."
echo "  4. Press the Run button (triangle)."
echo "Done. You can close this window."
