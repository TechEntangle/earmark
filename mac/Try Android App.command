#!/bin/bash
# Earmark: starts an Android emulator on this Mac and installs the Earmark app in it.
# Needs Android Studio (free, from developer.android.com/studio) for Java and the SDK.
# The first run downloads the emulator and an Android 16 system image (about 2 GB, once).
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/android_try.txt"
exec > >(tee "$LOG") 2>&1
echo "== Earmark Android app  $(date)"
APK="$HERE/Earmark-Android.apk"
[ -f "$APK" ] || { echo "Earmark-Android.apk is missing next to this script."; exit 1; }

STUDIO="/Applications/Android Studio.app"
if [ -z "${JAVA_HOME:-}" ] && [ -d "$STUDIO/Contents/jbr/Contents/Home" ]; then export JAVA_HOME="$STUDIO/Contents/jbr/Contents/Home"; fi
if [ -z "${JAVA_HOME:-}" ] && ! /usr/libexec/java_home >/dev/null 2>&1; then
  echo "Android Studio is not installed. Install it from https://developer.android.com/studio,"
  echo "open it once (it sets up the Android SDK), then run this again."
  open "https://developer.android.com/studio"
  exit 1
fi
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
mkdir -p "$SDK"
SM="$SDK/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$SM" ]; then
  echo "== Installing Android command-line tools"
  TMP="$(mktemp -d)"
  curl -sSL -o "$TMP/ct.zip" https://dl.google.com/android/repository/commandlinetools-mac-13114758_latest.zip || exit 1
  unzip -q "$TMP/ct.zip" -d "$TMP" && mkdir -p "$SDK/cmdline-tools" && mv "$TMP/cmdline-tools" "$SDK/cmdline-tools/latest"
fi
IMG="system-images;android-36;google_apis;arm64-v8a"
echo "== Installing the emulator and an Android system image (first time only)"
yes | "$SM" --sdk_root="$SDK" --licenses >/dev/null 2>&1
"$SM" --sdk_root="$SDK" "platform-tools" "emulator" "$IMG" | tail -2
AVD="$SDK/cmdline-tools/latest/bin/avdmanager"
if ! "$SDK/emulator/emulator" -list-avds | grep -q "^Earmark_Pixel$"; then
  echo "== Creating the emulator 'Earmark_Pixel'"
  echo no | "$AVD" create avd -n Earmark_Pixel -k "$IMG" -d pixel_8 --force
fi
ADB="$SDK/platform-tools/adb"
if ! "$ADB" devices | grep -q emulator; then
  echo "== Starting the emulator"
  nohup "$SDK/emulator/emulator" -avd Earmark_Pixel -no-snapshot-save >/dev/null 2>&1 &
  "$ADB" wait-for-device
  until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
fi
echo "== Installing Earmark"
"$ADB" install -r "$APK" && "$ADB" shell monkey -p app.earmark -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
echo
echo "Earmark is open in the emulator. To pair it with this Mac:"
echo "  Mac address:  10.0.2.2:8765   (the emulator's name for this Mac)"
echo "  Code:         Earmark on the Mac > Settings > Phone > Pair a phone"
echo "The emulator has no Bluetooth, so it will keep looking for the pendant; Today, Tasks and"
echo "Conversations work. Use a real phone for the pendant."
echo "Done. You can close this window."
