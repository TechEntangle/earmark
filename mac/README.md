# Earmark

Your Omi pendant, your notes, your Mac. Earmark pulls recordings off the pendant over
Bluetooth, transcribes them with a local Whisper model, writes notes with a local
Ollama model, and shows everything in a small web UI. Nothing is sent to Omi's cloud
or anyone else's.

## Install (macOS, Apple silicon)

```
cd earmark
bash install.sh
```

The installer creates a Python environment, builds `Earmark.app` on your Desktop
and adds it to your login items. Double-click the app: it starts the service and
opens http://127.0.0.1:8765.

First run: macOS asks to allow Bluetooth for Earmark — allow it. Whisper and
Ollama models download once and are cached locally.

## Daily use

1. Wear the pendant with the Omi app closed. It records to its own flash.
2. Come within Bluetooth range of the Mac. Earmark notices, syncs, transcribes,
   and writes notes. Watch the band at the top of the UI.
3. Read, search, rename, replay, or delete sessions in the UI.

Notes are plain markdown in `~/Earmark/notes/`, audio in `~/Earmark/audio/`.
Point Obsidian, Notion or anything else at the notes folder.

Record live (while connected) with the button in the UI.

## Settings

Gear icon, top right: auto-sync, polling interval, Whisper size, language,
Ollama model and address, session split gap.

## Notes

- Keep the pendant still near the Mac until a sync finishes. Stock firmware
  advances its read pointer while transmitting; a mid-transfer walk-away can lose
  a few seconds of audio.
- Stock firmware doesn't require Bluetooth pairing to read the buffer. Anyone in
  radio range with this protocol could pull your recordings. Fine at home; think
  about it elsewhere.
- Logs: `~/Earmark/service.log`. Stop the service: `pkill -f earmark.app`.

## Credits

Protocol per BasedHardware/omi (ring storage, firmware 3.0.20+).
