"""The Earmark phone app's side of the Mac service.

The phone holds the pendant all day and records. It talks to the Mac over the private
Tailscale link with a paired-device bearer token:

  POST /api/app/pair        {code, name, platform}  -> {token}       (one-time 6-digit code)
  POST /api/app/heartbeat   phone + pendant state   -> Mac settings, pause state
  POST /api/app/audio       a chunk of Opus frames, with when they were recorded
  POST /api/app/event       earmark / pause / resume from the pendant button

Audio chunk wire format (application/octet-stream):
  repeated [u16 big-endian length][Opus frame], 20 ms per frame, 16 kHz mono
  headers: X-Earmark-Start (epoch seconds of the first frame, float), X-Earmark-Seq (int,
  increasing per device), X-Earmark-Codec (20 or 21)

Chunks are applied in order and exactly once per device (a repeated seq is acknowledged
and ignored), so the phone can retry freely after a network drop.
"""
from __future__ import annotations

import struct
import time
from pathlib import Path
from typing import Callable, Optional

from . import pipeline as PL

FRAME_S = 0.02
HOLD_TTL_S = 90          # a phone that said "I have the pendant" within this window keeps it


def parse_frames(body: bytes) -> list[bytes]:
    frames, i, n = [], 0, len(body)
    while i + 2 <= n:
        ln = struct.unpack_from(">H", body, i)[0]
        i += 2
        if ln == 0 or i + ln > n:
            raise ValueError("malformed audio chunk")
        frames.append(body[i:i + ln])
        i += ln
    if i != n:
        raise ValueError("malformed audio chunk")
    return frames


def pack_frames(frames: list[bytes]) -> bytes:
    return b"".join(struct.pack(">H", len(f)) + f for f in frames)


class PhoneCapture:
    """Builds sessions from uploaded chunks for one device, using the times the phone recorded them."""

    def __init__(self, wav_dir: Path, gap_s: int, on_session: Callable[[PL.DecodedSession], None]):
        self.wav_dir, self.gap_s, self.on_session = wav_dir, gap_s, on_session
        self.cap = PL.LiveCapture(wav_dir, gap_s=gap_s)
        self.last_upload = 0.0

    def add(self, start: float, frames: list[bytes]):
        self.last_upload = time.time()
        end = self.cap.end_time
        t = start
        if end is not None:
            gap = start - end
            if gap > self.gap_s:                       # a real break: the previous conversation is over
                self.finish()
            elif gap > FRAME_S:                        # a short break in recording: keep timing true
                self.cap.push_silence(gap)
            elif gap < -FRAME_S:                       # overlaps what we already have: skip the overlap
                skip = int(round(-gap / FRAME_S))
                frames = frames[skip:]
                t = start + skip * FRAME_S
        for k, f in enumerate(frames):
            self.cap.push(f, t + k * FRAME_S)
        self._collect()

    def idle_check(self, now: Optional[float] = None):
        """No upload for a while (phone out of range, app closed): close what is open."""
        now = now or time.time()
        if self.cap.fh is not None and now - self.last_upload > self.gap_s + 60:
            self.finish()

    def finish(self):
        self.cap.finish()
        self._collect()
        self.cap = PL.LiveCapture(self.wav_dir, gap_s=self.gap_s)

    @property
    def open_seconds(self) -> float:
        return self.cap.open_seconds

    def _collect(self):
        for s in self.cap.take_closed():
            self.on_session(s)
