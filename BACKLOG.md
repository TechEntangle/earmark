# Earmark backlog

The pendant and the iPhone are the main pair; everything runs on your own devices. The Mac is the
backup and does the heavy lifting (other languages, full Whisper). Newest decisions at the top of
each section. Status: **now** (being built), **next**, **later**, **idea**, **done**.

## Now
- **Custom vocabulary**: names and terms you use (colleagues, products, acronyms) so they're spelled
  right, on the phone and the Mac.
- **Mac app, stage 2**: the engine's jobs move into the app one by one (pendant over Bluetooth,
  Parakeet / WhisperKit, Apple's model for notes), then Python is retired.

## Next
- **Pendant firmware updates from Earmark** (the firmware accepts updates over Bluetooth); careful:
  battery check, verified images only.
- **Ask, version 2**: Ask calls tools (conversations by date/person, open tasks, people, calendar)
  instead of only retrieving passages; follow-up questions; Ask over Mac-only conversations too.
- **Bring Mac voices to the phone**: re-learn from conversations already named on the Mac.

- **Edit conversations**: rename, delete, star, merge two, fix a transcript line or its speaker.
- **Ask from the pendant**: press, ask a question out loud, hear the answer in your AirPods.

## Later
- **Commitments tracker**: who owes me what, what I owe whom, gentle nudges when overdue.
- **Meeting prep**: before a calendar meeting, a brief from past conversations with those people.
- **Follow-up drafts**: after a meeting, a ready email/message with decisions and actions.
- **People pages**: voice, topics, promises both ways, things they mentioned (projects, dates).
- **Today on the phone**: morning brief from the phone's own data (highlights, open tasks, people).
- **Overnight work while charging**: redo notes with more context, build the index, tidy speakers,
  write the morning brief (background processing, no daytime battery).
- **Privacy rules**: auto-pause by place (home, rooms, the bank floor) or schedule, with an indicator.
- **Decode the pendant's own memory on the phone** (audio recorded while away from the phone).
- **Two-way task sync** between phone and Mac; the Mac reuses the phone's notes instead of its own.
- **Lock-screen widget / Live Activity**: recording state, battery, last earmark.
- **Earmark → instant summary** of the last two minutes.
- **Hinglish / mixed speech**: send pieces with a noticeable share of another language to the Mac.
- **Calls**: Mac calls (Teams inside AVD), iPhone calls over AirPods (platform limits apply).
- **Battery**: hourly sync / sync on demand; sleep and wake by gesture (firmware permitting).
- **Android build**: pendant, recording, Mac sync and the UI work as is (Flutter); the on-device
  parts need Android twins: Parakeet via sherpa-onnx, a small on-device model (Gemma via MediaPipe
  or Gemini Nano where offered) or the cloud key for notes/Ask, Google Tasks/Calendar for reminders.
- **TestFlight** distribution instead of installing from Xcode.

- **Memories about you**: facts and preferences learnt from conversations, each linked to its source.
- **Daily recap at night** and **goals** (daily/monthly) that notes and Ask take into account.
- **Share and export**: a conversation's audio, transcript or summary; export everything as JSON.
- **Folders / categories** for conversations, set automatically.
- **Calendar events** pulled from conversations ("let's meet Thursday at 3").
- **Pendant care**: battery history, low-battery and fully-charged alerts, mic gain, LED, firmware updates.
- **Quick actions and widgets**: long-press app icon (Ask, Earmark, Pause), home-screen widgets.

## Ideas (to discuss)
- Media detection: skip stretches that are a video/podcast playing, not people talking.
- Weekly reflection: time in meetings, recurring themes, people seen most.

## Omi app comparison (6 Nov 2026, Omi app 1.0.586)
Where Earmark is already ahead: audio, transcripts, notes and tasks never leave your devices (Omi's
summaries, memories and chat run on Omi's servers; its fully local mode is still behind a flag); no
monthly caps or subscription (Omi Pro is $29.99/month; free has 5 h cloud recording and 30 questions);
Mac backup with full Whisper for Marathi/Hindi/Urdu/Arabic; crash-safe recording with handoff.
Where Omi is ahead: speaker naming and people (building now), Ask with tools and citations (next),
conversation editing, custom vocabulary, memories, daily recap, goals, Reminders/Calendar, sharing and
export, widgets/Siri, pendant care (OTA, battery history), integrations (we keep these optional/local).
Things not to copy: cloud processing, public share links, third-party app store with raw-audio access.

## Done
- **Earmark for Mac** (stage 1): a real Mac app (~/Applications/Earmark.app) over the engine: Today,
  Conversations (notes, tasks, who spoke, transcript, playback with speed), Tasks, Ask, People,
  Pendant, Settings; menu bar with state, pause/resume, earmark; starts the engine; open at login;
  notifications when notes are ready; keyboard shortcuts (⌘1–7, ⌘K Ask, ⇧⌘E earmark, ⇧⌘P pause).
- Siri, Shortcuts and the Action button on the iPhone: Earmark this moment, Pause / Resume, Ask
  Earmark, Show my tasks. Conversations in Spotlight.
- Full Settings on the iPhone, grouped; notes and Ask with your own OpenAI / Anthropic key (text
  only, never audio); conversation gap; how long audio is kept; storage used.
- Ask: finds passages by words when the sentence model is missing; "yesterday", "this week" etc.
- Playback: speed control; audio file written by AVAudioFile.
- Pendant page on the iPhone: everything the CV1 firmware exposes. Button actions (tap, double tap,
  press-and-hold: earmark / pause / nothing), vibration, light, microphone level, find my pendant,
  and model, firmware, hardware, charging, clock, own memory, health. Kept in step with the Mac.
- Tasks into Apple Reminders with due dates and alerts; ticking off there ticks off in Earmark.
- Pendant on the iPhone with crash-safe recording; Mac as backup with handoff ("Use this iPhone").
- Home screen: status chain (pendant, battery, holder, Mac), one action, latest conversations.
- English transcription on the iPhone (Parakeet); other languages detected and translated by the Mac.
- Conversations, notes and tasks on the iPhone (Apple's on-device model); spoken "remind me" tasks.
- Audio playback on the iPhone (30 days kept), tap a line to play from there.
- Comparison with the Omi app (see above).
- Ask on the iPhone: notes, tasks and transcript indexed on the phone (Apple sentence embedding +
  keyword match), answers from Apple's on-device model with the moments they came from.
- Voice recognition on the iPhone: who spoke when, voices named once and recognised after, "Me"
  suggested from the loudest voice, names in transcripts and notes; Voices list in Settings.
- Mac: speaker identification with voice signatures, line splitting at speaker changes, estate re-run,
  on-demand models, phone access over Tailscale, web app.
