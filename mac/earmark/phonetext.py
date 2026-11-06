"""Transcripts made on the iPhone (Parakeet on the phone's Neural Engine).

The phone is the primary transcriber: it sends the text of every 30-second chunk just before
the chunk's audio. When a session from the phone is processed, its transcript is built from
those texts and the Mac's own speech model is only used where the phone had none (the Mac is
the backup). Speaker identification, notes and tasks then run on the Mac as usual.
"""
from __future__ import annotations

import re
from typing import Optional

SENTENCE_END = re.compile(r"[.?!…]['\")\]]*$")
MAX_SEGMENT_S = 30.0
PAUSE_S = 1.2


def segments_from_chunks(chunks: list[dict], session_start: float) -> list[dict]:
    """chunks: [{"start": epoch s, "seconds": s, "text": str, "words": [[s, e, word], ...]}] in order,
    word times relative to their chunk. Returns transcript segments (the Mac's format) with times
    relative to `session_start`, split at sentence ends and pauses."""
    words: list[list] = []
    for ch in chunks:
        base = float(ch["start"]) - session_start
        ws = ch.get("words") or []
        if ws:
            for w in ws:
                try:
                    a, b, t = float(w[0]), float(w[1]), str(w[2]).strip()
                except (TypeError, ValueError, IndexError):
                    continue
                if t:
                    words.append([round(base + a, 2), round(base + b, 2), t])
        elif (ch.get("text") or "").strip():
            # no word timings: spread the chunk's words evenly over it
            toks = ch["text"].split()
            step = max(0.05, float(ch.get("seconds") or 0) / max(1, len(toks)))
            words += [[round(base + i * step, 2), round(base + (i + 1) * step, 2), t] for i, t in enumerate(toks)]
    words.sort(key=lambda w: w[0])
    segs: list[dict] = []
    cur: list[list] = []

    def flush():
        if cur:
            segs.append({"start": cur[0][0], "end": cur[-1][1], "text": " ".join(w[2] for w in cur), "words": [list(w) for w in cur]})
            cur.clear()

    for w in words:
        if cur and (w[0] - cur[-1][1] > PAUSE_S or w[1] - cur[0][0] > MAX_SEGMENT_S):
            flush()
        cur.append(w)
        if SENTENCE_END.search(w[2]):
            flush()
    flush()
    return segs


def covered(chunks: list[dict], started_at: float, ended_at: float, need: float = 0.85) -> bool:
    """Whether the phone's chunks cover enough of the session to stand as its transcript."""
    span = max(0.0, ended_at - started_at)
    if span <= 0:
        return False
    have = 0.0
    for ch in chunks:
        a = max(started_at, float(ch["start"]))
        b = min(ended_at, float(ch["start"]) + float(ch.get("seconds") or 0))
        have += max(0.0, b - a)
    return have >= need * span


def transcript(chunks: list[dict], started_at: float, ended_at: float) -> Optional[dict]:
    """The session's transcript from the phone, or None when the Mac should transcribe it itself."""
    if not chunks or not covered(chunks, started_at, ended_at):
        return None
    segs = segments_from_chunks(chunks, started_at)
    # the phone checked each chunk's language (English by Parakeet, others translated into English by Whisper)
    checked = all(ch.get("engine") == "iphone-multi" for ch in chunks)
    langs = []
    for ch in chunks:
        lang = ch.get("language") or ""
        if lang and lang not in langs:
            langs.append(lang)
    langs = langs or ["en"]
    return {"language": ", ".join(langs), "languages": langs, "segments": segs, "text": "\n".join(s["text"] for s in segs),
            "engine": "iphone", "checked": checked}
