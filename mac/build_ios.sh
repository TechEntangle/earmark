#!/bin/bash
# Called by Build Helper from the mobile folder:
#   build    compile check of the iPhone app
#   install  build and upgrade the app on the iPhone in place (devicectl): its data and the
#            speech model are kept (flutter install would uninstall first and wipe them)
#   mac      build the Mac app (build/macos/Build/Products/Release/Earmark.app)
FLUTTER="$HOME/development/flutter/bin/flutter"
[ -x "$FLUTTER" ] || FLUTTER="$(command -v flutter)"
export PATH="$(dirname "$FLUTTER"):$PATH"
what="${1:-build}"
echo "started $(date '+%F %T') ($what) [helper v3]"
sw_vers -productVersion 2>/dev/null | sed 's/^/macOS /'
"$FLUTTER" pub get 2>&1 | tail -2
if [ "$what" = "install" ]; then
  "$FLUTTER" build ios --release 2>&1
  code=$?
  if [ $code -eq 0 ]; then
    dev="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /(available|connected)/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')"
    [ -n "$dev" ] || dev="$("$FLUTTER" devices --machine 2>/dev/null | python3 -c 'import sys,json
d=[x for x in json.load(sys.stdin) if x.get("targetPlatform")=="ios" and not x.get("emulator")]
print(d[0]["id"] if d else "")')"
    if [ -n "$dev" ]; then
      echo "Installing on $dev (keeps the app's data)"
      xcrun devicectl device install app --device "$dev" build/ios/iphoneos/Runner.app 2>&1
      code=$?
    else
      xcrun devicectl list devices 2>&1 | tail -5
      echo "no iPhone found (unlocked, same Wi-Fi or cable?)"; code=9
    fi
  fi
elif [ "$what" = "mac" ]; then
  "$FLUTTER" build macos --release -t lib/mac/main_mac.dart 2>&1
  code=$?
else
  "$FLUTTER" build ios --release --no-codesign 2>&1
  code=$?
fi
echo "exit=$code"
echo "finished $(date '+%F %T')"
