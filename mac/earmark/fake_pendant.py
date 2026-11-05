"""A simulated Omi pendant with the same interface as pendant.Pendant.

Enabled with EARMARK_FAKE_PENDANT=1. Used by the end-to-end tests and for trying the UI
without hardware. It behaves like stock firmware in the ways Earmark depends on:
  * an offline ring of 444-byte records (4-byte BE timestamp + packed Opus)
  * a live Opus stream at 50 frames/s while subscribed
  * button notifications, LED dim ratio, mic gain, clock
Test hooks (tap, take out of range, add offline audio) are exposed through /api/_fake/*.
"""
from __future__ import annotations

import asyncio
import math
import os
import struct
import time
import wave
from pathlib import Path
from typing import Callable, Optional

from . import pipeline as PL           # patches libopus lookup before opuslib is imported
from .pendant import RECORD, RingInfo, BTN_DOUBLE

SR = 16000
FRAME = 320                              # 20 ms


def _source_pcm() -> bytes:
    """Speech-like test audio: EARMARK_FAKE_AUDIO (16 kHz mono WAV) or a warbling tone."""
    p = os.environ.get("EARMARK_FAKE_AUDIO")
    if p and Path(p).exists():
        with wave.open(p, "rb") as w:
            return w.readframes(w.getnframes())
    out = bytearray()
    for n in range(SR * 4):
        env = 0.5 + 0.5 * math.sin(2 * math.pi * 0.5 * n / SR)
        out += struct.pack("<h", int(9000 * env * math.sin(2 * math.pi * (220 + 60 * math.sin(n / 4000)) * n / SR)))
    return bytes(out)


class _Fake:
    def __init__(self):
        self.present = True
        self.led = 100
        self.mic = 4
        self.clock_set_at: Optional[int] = None
        self.ring = bytearray()
        self.read_seq = 0
        self.write_seq = 0
        self.dropped = 0
        self.button_cb: Optional[Callable[[int], None]] = None
        self.buzzes: list = []                       # every vibration pattern played, for tests
        self.connected = False
        self.pcm = _source_pcm()
        import opuslib, threading
        # one encoder per stream: an Opus encoder must never be used from two threads at once
        self._streams = {"live": [opuslib.Encoder(SR, 1, opuslib.APPLICATION_VOIP), 0, threading.Lock()],
                         "offline": [opuslib.Encoder(SR, 1, opuslib.APPLICATION_VOIP), 0, threading.Lock()]}
        if len(self.pcm) < FRAME * 2:
            self.pcm = self.pcm.ljust(FRAME * 2, b"\0")

    def next_frame(self, stream: str = "live") -> bytes:
        st = self._streams[stream]
        with st[2]:
            need = FRAME * 2
            if st[1] + need > len(self.pcm):
                st[1] = 0
            chunk = self.pcm[st[1]:st[1] + need]
            st[1] += need
            return st[0].encode(chunk, FRAME)

    def add_offline(self, seconds: int, ended_ago: int = 60):
        """Append `seconds` of audio to the ring as if recorded while disconnected."""
        t0 = int(time.time()) - ended_ago - seconds
        payload, frames_in_rec, ts = b"", 0, t0
        for i in range(seconds * 50):
            f = self.next_frame("offline")
            if len(payload) + 1 + len(f) > 440:
                self.ring += struct.pack(">I", ts) + payload.ljust(440, b"\0")
                self.write_seq += 1
                payload = b""
                ts = t0 + i // 50
            payload += bytes([len(f)]) + f
        if payload:
            self.ring += struct.pack(">I", ts) + payload.ljust(440, b"\0")
            self.write_seq += 1


FAKE: Optional[_Fake] = None


def fake() -> _Fake:
    global FAKE
    if FAKE is None:
        FAKE = _Fake()
        secs = int(os.environ.get("EARMARK_FAKE_OFFLINE_SECONDS", "0"))
        if secs:
            FAKE.add_offline(secs)
    return FAKE


class FakeDevice:
    name = "Omi"
    address = "FA:KE:00:00:00:01"


async def scan(timeout: float = 8.0):
    await asyncio.sleep(0.2)
    return FakeDevice() if fake().present else None


def open_pendant(device) -> "FakePendant":
    return FakePendant()


class _FakeClient:
    @property
    def is_connected(self) -> bool:
        f = fake()
        return f.connected and f.present


class FakePendant:
    def __init__(self):
        self.client = _FakeClient()
        self._live_task: Optional[asyncio.Task] = None

    async def __aenter__(self):
        f = fake()
        if not f.present:
            raise RuntimeError("device not found")
        f.connected = True
        return self

    async def __aexit__(self, *exc):
        await self.stop_live()
        fake().connected = False
        fake().button_cb = None

    @property
    def connected(self) -> bool:
        return self.client.is_connected

    async def battery(self):
        return 87

    async def firmware(self):
        return "3.0.21-sim"

    async def ring_status(self):
        f = fake()
        return {"used_bytes": len(f.ring), "unread_packets": f.write_seq - f.read_seq,
                "free_bytes": 512_000_000, "rtc_valid": f.clock_set_at is not None}

    async def ring_info(self):
        f = fake()
        return RingInfo(f.read_seq, f.write_seq, 1_000_000, f.dropped, RECORD)

    async def ring_read(self, start: int, count: int, progress=None):
        f = fake()
        await asyncio.sleep(0.05)
        end = min(f.write_seq, start + count)
        return bytes(f.ring[start * RECORD:end * RECORD]), end

    async def ring_advance(self, seq: int):
        fake().read_seq = seq

    async def sync_clock(self):
        fake().clock_set_at = int(time.time())
        return True

    async def get_led(self):
        return fake().led

    async def set_led(self, pct: int):
        fake().led = max(0, min(100, int(pct)))
        return True

    async def get_mic_gain(self):
        return fake().mic

    async def set_mic_gain(self, level: int):
        fake().mic = max(0, min(8, int(level)))
        return True

    async def buzz(self, pattern):
        fake().buzzes.append([c for c, _ in pattern])
        return True

    async def on_button(self, cb):
        fake().button_cb = cb
        return True

    async def codec(self):
        return 21

    async def start_live(self, on_opus_frame):
        async def pump():
            f = fake()
            nxt = time.monotonic()
            while self.connected:
                on_opus_frame(f.next_frame())
                nxt += 0.02
                await asyncio.sleep(max(0, nxt - time.monotonic()))
        self._live_task = asyncio.create_task(pump())

    async def stop_live(self):
        if self._live_task:
            self._live_task.cancel()
            self._live_task = None


def tap(kind: int = BTN_DOUBLE):
    cb = fake().button_cb
    if cb:
        cb(kind)
        return True
    return False
