# Earmark for iPhone and Android

The phone holds the Omi pendant all day, records to its own storage (crash-safe), and sends
the audio to Earmark on your Mac over your private Tailscale link. The Mac transcribes,
identifies speakers and writes notes and tasks; the app shows Today, Tasks and Conversations.

```
pendant ──BLE──► phone: record (chunks on disk) ──Tailscale HTTPS──► Mac: transcribe, notes, tasks
                  ▲ taps: earmark / pause, vibrations                    │
                  └──────────── heartbeat: settings, pause ◄─────────────┘
```

* While the app holds the pendant, the Mac steps back (shown as "on iPhone" in the Mac header).
  Turn off **Settings → Hold the pendant** in the app to give it back to the Mac.
* Nothing goes anywhere but your Mac: no accounts, no analytics, no cloud.

## Pair with the Mac

1. Tailscale on, on the phone and the Mac.
2. Mac: Earmark → Settings → Phone → **Turn on phone access**, then **Pair a phone**.
3. App: enter the Mac address (e.g. `your-mac.tailnet.ts.net`) and the 6-digit code.

## Run on iPhone (Xcode)

One-time: install Flutter (`brew install --cask flutter`) and CocoaPods (`brew install cocoapods`).

```
cd mobile
flutter pub get
open ios/Runner.xcworkspace
```

In Xcode: select **Runner** → *Signing & Capabilities* → choose your **Team** (bundle id
`app.earmark`; if Xcode says it is not available, change it to something of your own such as
`com.yourname.earmark`). Plug in or select your iPhone and press **Run**. For TestFlight:
Product → Archive.

Or double-click **Set Up Phone App** in the Mac's Earmark folder: it installs Flutter if needed
(no Homebrew required), prepares the project and opens Xcode.

## Run on Android

Emulator: double-click **Try Android App** in the Mac's Earmark folder (needs Android Studio
installed once), or by hand (Android Studio → Device Manager → a Pixel with Android 14+):

```
cd mobile
flutter run            # or: adb install build/app/outputs/flutter-apk/app-debug.apk
```

On the emulator the Mac is at `10.0.2.2:8765`. The emulator has no Bluetooth, so it shows
"Looking for the pendant"; pairing, Today, Tasks and Conversations work. Use a real phone for
the pendant.

## Tests

```
flutter test                                  # protocol, recording store, API, screens
# against a running Mac service (simulated pendant):
EARMARK_TEST_SERVER=http://127.0.0.1:8765 EARMARK_TEST_FRAMES=frames.bin flutter test test_e2e
```

## Code map

| File | What it does |
|---|---|
| `lib/pendant/protocol.dart` | Omi BLE UUIDs, Opus frame reassembly, button decoding, tap pairing, vibration patterns |
| `lib/pendant/pendant_service.dart` | Finds, connects, reconnects (background-safe), streams frames, battery, buttons, haptics |
| `lib/recorder/chunk_store.dart` | Writes every frame to disk as it arrives; 30 s chunks; never reuses sequence numbers |
| `lib/core/api.dart` | Mac API client (bearer token); upload format matches `mac/earmark/appsync.py` |
| `lib/app_controller.dart` | Recording, pause/earmark, upload queue, heartbeat, pause sync with the Mac |
| `lib/ui/*` | Pair, Pendant (now), Today, Tasks, Conversations, Settings |

Bluetooth library: `flutter_reactive_ble` (BSD-3). Fonts: Geist and Newsreader (OFL).
Protocol reference: Omi by Based Hardware (MIT), see `assets/OMI_LICENSE.txt`.
