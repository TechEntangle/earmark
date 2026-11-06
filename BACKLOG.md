# Earmark backlog

The pendant and the iPhone are the main pair; everything runs on your own devices. The Mac is the
backup and does the heavy lifting (other languages, full Whisper). Newest decisions at the top of
each section. Status: **now** (being built), **next**, **later**, **idea**, **done**.

## Now
- **Voice recognition on the iPhone**: who spoke when (FluidAudio diarizer), voices named once and
  recognised after; "Me" suggested from the loudest voice; names flow into notes and task owners.
- **Compare with the Omi app**: feature inventory and gaps.

## Next
- **Ask**: questions over everything heard, answered on the phone with links to the exact moment.
  On-device embeddings and a local index (keyword + meaning), Apple's on-device model answers.
  Ask should call tools (conversations, tasks, people, calendar), not only retrieve.
- **Siri, Shortcuts, Spotlight** (App Intents): "Hey Siri, ask Earmark…", Earmark this moment,
  open tasks; conversations findable in iPhone search; Action button to earmark.
- **Tasks into Apple Reminders** with due dates and real alerts ("remind me at 5 pm").
- **Bring Mac voices to the phone**: re-learn from conversations already named on the Mac.

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
- **Android build** of the same app (emulator first).
- **TestFlight** distribution instead of installing from Xcode.

## Ideas (to discuss)
- Media detection: skip stretches that are a video/podcast playing, not people talking.
- Weekly reflection: time in meetings, recurring themes, people seen most.

## Done
- Pendant on the iPhone with crash-safe recording; Mac as backup with handoff ("Use this iPhone").
- Home screen: status chain (pendant, battery, holder, Mac), one action, latest conversations.
- English transcription on the iPhone (Parakeet); other languages detected and translated by the Mac.
- Conversations, notes and tasks on the iPhone (Apple's on-device model); spoken "remind me" tasks.
- Audio playback on the iPhone (30 days kept), tap a line to play from there.
- Mac: speaker identification with voice signatures, line splitting at speaker changes, estate re-run,
  on-demand models, phone access over Tailscale, web app.
