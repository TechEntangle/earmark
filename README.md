# Earmark

Private memory for the Omi pendant. Earmark records what the pendant hears, transcribes it,
works out who said what, and turns conversations into notes, tasks and a daily brief. Everything
runs on your own devices: no Omi cloud, no third-party AI service unless you choose one.

| Folder | What it is |
|---|---|
| `mac/` | The Earmark service for macOS (Apple silicon): pendant over Bluetooth, local speech-to-text (Parakeet / Whisper on MLX), speaker identification (TitaNet + pyannote segmentation, ONNX), local notes model (Qwen via MLX), web UI at http://127.0.0.1:8765, phone access over Tailscale with device pairing. |
| `mobile/` | The Earmark app for iPhone and Android (Flutter). Holds the pendant connection all day, records, and syncs with the Mac over your private Tailscale link. *In progress.* |

## Mac service

```
cd mac
bash install.sh
```

Builds `Earmark.app`, installs the Python environment and starts the service. Models download
once on first use. Data lives in `~/Earmark` (database, audio, notes) and is never part of this repo.

Tests: `cd mac && bash run_tests.sh` (unit tests plus Playwright end-to-end tests against a
simulated pendant).

## Privacy model

* Audio, transcripts, voices and notes stay on the Mac (and, with the app, on your phone).
* The web UI is open only to the Mac's own browser. Phones must be paired with a one-time code;
  device tokens are stored as hashes and can be revoked.
* Remote access uses Tailscale `serve` (your tailnet only), never public exposure.

## Third-party code

See `THIRD_PARTY_NOTICES.md`.
