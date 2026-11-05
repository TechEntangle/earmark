#!/bin/bash
# Earmark installer for macOS. Run once:  bash install.sh
set -e
export NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Desktop/Earmark.app"

say_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

say_ "1/5  Finding a native (Apple silicon) Python"
PY=""
for c in /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 \
         /Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13 \
         /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11 \
         /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3; do
  if [ -x "$c" ] && arch -arm64 "$c" -c 'import platform,sys; sys.exit(0 if platform.machine()=="arm64" and sys.version_info>=(3,10) else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
if [ -z "$PY" ]; then
  echo "No native Python found; fetching a standalone one with uv (no Xcode or Homebrew needed)"
  if ! command -v uv >/dev/null && [ ! -x "$HOME/.local/bin/uv" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
  "$UV" python install 3.12 --quiet
  PY="$("$UV" python find 3.12)"
fi
echo "Using $PY"

say_ "2/5  Installing Python packages (first time takes a few minutes)"
rm -rf "$DIR/.venv"
arch -arm64 "$PY" -m venv "$DIR/.venv"
arch -arm64 "$DIR/.venv/bin/python" -m pip install --upgrade pip
arch -arm64 "$DIR/.venv/bin/python" -m pip install --progress-bar on -r "$DIR/requirements.txt"
arch -arm64 "$DIR/.venv/bin/python" -c 'import platform; assert platform.machine()=="arm64", "venv is not arm64"'
arch -arm64 "$DIR/.venv/bin/python" -c 'import fastapi, bleak, opuslib' 2>/dev/null || true
chmod +x "$DIR/run.sh"

say_ "3/5  Building the app icon"
ICONSET="$(mktemp -d)/Earmark.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$DIR/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$DIR/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DIR/Earmark.icns"
cp "$DIR/icon.png" "$DIR/earmark/static/icon.png"

say_ "4/5  Creating Earmark.app on your Desktop"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Earmark.icns" "$APP/Contents/Resources/Earmark.icns"
cat > "$APP/Contents/Info.plist" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Earmark</string>
  <key>CFBundleDisplayName</key><string>Earmark</string>
  <key>CFBundleIdentifier</key><string>local.earmark.launcher</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Earmark</string>
  <key>CFBundleIconFile</key><string>Earmark</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Earmark talks to your Omi pendant over Bluetooth.</string>
</dict></plist>
EOF2
cat > "$APP/Contents/MacOS/Earmark" <<EOF2
#!/bin/bash
osascript -e 'display notification "Starting… this takes a few seconds" with title "Earmark"' >/dev/null 2>&1
if /bin/bash "$DIR/run.sh"; then
  open "http://127.0.0.1:8765"
else
  ERR="\$(tail -n 4 "$DIR/service.log" 2>/dev/null | tr '"' "'" | cut -c1-500)"
  osascript -e "display dialog \"Earmark could not start.\n\n\$ERR\n\nFull log: $DIR/service.log\" buttons {\"OK\"} with icon stop"
fi
EOF2
chmod +x "$APP/Contents/MacOS/Earmark"
touch "$APP"

say_ "5/5  Starting Earmark at login"
# The service is started by Earmark.app (not launchd) so macOS attributes the
# Bluetooth permission to the app and shows a proper prompt.
mkdir -p "$HOME/Earmark"
echo "  (To start Earmark at login: System Settings > General > Login Items > + > Desktop/Earmark.app)"

say_ "Done"
cat <<EOF
  Double-click Earmark.app on your Desktop. It starts the service in the
  background and opens http://127.0.0.1:8765. It will also start at login.

  First run: macOS asks to allow Bluetooth for Earmark. Allow it, or the
  pendant can't be found. If you missed the prompt: System Settings > Privacy
  & Security > Bluetooth.

  Close the Omi app before syncing; the pendant only talks to one app at a time.
  Logs: ~/Earmark/service.log
EOF
