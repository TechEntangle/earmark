#!/bin/bash
# Called by Build Helper from the mobile folder: "build" (compile check) or "install".
# Install upgrades the app in place (devicectl), so its data and the speech model are kept.
FLUTTER="$HOME/development/flutter/bin/flutter"
[ -x "$FLUTTER" ] || FLUTTER="$(command -v flutter)"
export PATH="$(dirname "$FLUTTER"):$PATH"
what="${1:-build}"
echo "started $(date '+%F %T') ($what)"
"$FLUTTER" pub get 2>&1 | tail -2
if [ "$what" = "install" ]; then
  "$FLUTTER" build ios --release 2>&1
  code=$?
  if [ $code -eq 0 ]; then
    dev="$("$FLUTTER" devices --machine 2>/dev/null | python3 -c 'import sys,json
d=[x for x in json.load(sys.stdin) if x.get("targetPlatform")=="ios" and not x.get("emulator")]
print(d[0]["id"] if d else "")')"
    if [ -n "$dev" ]; then
      echo "Installing on $dev (keeps the app's data)"
      xcrun devicectl device install app --device "$dev" build/ios/iphoneos/Runner.app 2>&1
      code=$?
    else
      echo "no iPhone found (unlocked, same Wi-Fi or cable?)"; code=9
    fi
  fi
else
  "$FLUTTER" build ios --release --no-codesign 2>&1
  code=$?
fi
echo "exit=$code"
echo "finished $(date '+%F %T')"
