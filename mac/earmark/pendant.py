"""BLE client for the Omi CV1 pendant (stock firmware 3.0.20+).

Services used (all present in stock firmware):
  * ring storage  30295780-…  offline recordings written to NAND while no app is connected
  * live audio    19B10000-…  Opus stream while connected (codec 20 or 21 = Opus, 20 ms frames)
  * settings      19B10010-…  LED dim ratio (0-100), mic gain (0-8)
  * time sync     19B10030-…  write u32 LE epoch; unset clock makes the LED blink red and
                              the firmware discard offline audio
  * button        23BA7924-…  notifies int32 LE event: 1 tap, 2 double tap, 3 long, 4 down, 5 up

Firmware behaviour that matters (omi/firmware/omi/src/lib/core/transport.c, pusher()):
  connected + subscribed to audio  -> streamed live
  not connected                    -> written to the offline ring
  connected but NOT subscribed     -> dropped
so Earmark either stays subscribed while connected, or keeps connections short.

Protocol reference: BasedHardware/omi  app/lib/services/devices/ring_protocol.dart,
omi/firmware/omi/src/lib/core/{storage,transport,button}.c.
"""
from __future__ import annotations

import asyncio
import struct
import time
from dataclasses import dataclass
from typing import Callable, Optional

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

DEVICE_NAME = "Omi"

AUDIO_DATA = "19b10001-e8f2-537e-4f6c-d104768a1214"
CODEC_TYPE = "19b10002-e8f2-537e-4f6c-d104768a1214"
BATTERY = "00002a19-0000-1000-8000-00805f9b34fb"
FW_REV = "00002a26-0000-1000-8000-00805f9b34fb"
RING_CTRL = "30295781-4301-eabd-2904-2849adfeae43"
RING_STAT = "30295782-4301-eabd-2904-2849adfeae43"
DIM_RATIO = "19b10011-e8f2-537e-4f6c-d104768a1214"
MIC_GAIN = "19b10012-e8f2-537e-4f6c-d104768a1214"
TIME_WRITE = "19b10031-e8f2-537e-4f6c-d104768a1214"
TIME_READ = "19b10032-e8f2-537e-4f6c-d104768a1214"
BUTTON = "23ba7925-0000-1000-7450-346eac492e92"
HAPTIC = "cab1ab96-2ea5-4f4d-bb56-874b72cfc984"     # write 1 byte: 1=100 ms, 2=300 ms, 3=500 ms
# vibration patterns: (strength code, pause after in ms)
BUZZ_RECORDING = [(1, 180), (1, 180), (1, 0)]       # three short: recording
BUZZ_PAUSED = [(3, 0)]                              # one long: paused
BUZZ_EARMARK = [(2, 0)]                             # one medium: moment earmarked
OPUS_CODECS = (20, 21)
BTN_TAP, BTN_DOUBLE, BTN_LONG, BTN_DOWN, BTN_UP = 1, 2, 3, 4, 5
# The firmware only reports a double tap when the second press lands within 300 ms of the
# first; a relaxed double tap arrives as two single taps. Earmark treats two single taps
# within this window as a double tap, and waits this long before acting on a single tap.
TAP_PAIR_WINDOW_S = 1.0

CMD_STOP, CMD_INFO, CMD_READ, CMD_ADVANCE, CMD_CLEAR = 0x03, 0x10, 0x11, 0x12, 0x13
N_ACK, N_INFO, N_DATA, N_DONE, N_BEGIN = 0x01, 0x02, 0x03, 0x04, 0x05
RECORD = 444                 # 4-byte BE unix timestamp + 440-byte packed Opus payload
OPUS_BYTES_PER_SEC = 4000    # rough, for progress estimates

STATUS_TEXT = {6: "invalid command", 9: "storage not ready", 10: "sequence out of range"}


@dataclass
class RingInfo:
    read_seq: int
    write_seq: int
    capacity: int
    dropped: int
    packet_size: int

    @property
    def unread(self) -> int:
        return max(0, self.write_seq - self.read_seq)

    @property
    def unread_seconds(self) -> float:
        return self.unread * 440 / OPUS_BYTES_PER_SEC


class PendantError(RuntimeError):
    pass


async def scan(timeout: float = 8.0) -> Optional[BLEDevice]:
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or ad.local_name or "") == DEVICE_NAME, timeout=timeout)


def open_pendant(device) -> "Pendant":
    return Pendant(device)


class Pendant:
    """One connected session with the pendant."""

    def __init__(self, device: BLEDevice):
        self.device = device
        self.client = BleakClient(device, timeout=20)
        self._q: asyncio.Queue[bytes] = asyncio.Queue()

    async def __aenter__(self):
        await self.client.connect()
        await self.client.start_notify(RING_CTRL, lambda _h, d: self._q.put_nowait(bytes(d)))
        return self

    async def __aexit__(self, *exc):
        try:
            await self.client.disconnect()
        except Exception:
            pass

    # ------------------------------------------------------------ device info
    async def battery(self) -> Optional[int]:
        try:
            return (await self.client.read_gatt_char(BATTERY))[0]
        except Exception:
            return None

    async def firmware(self) -> Optional[str]:
        try:
            return (await self.client.read_gatt_char(FW_REV)).decode(errors="ignore").strip("\x00")
        except Exception:
            return None

    # ------------------------------------------------------------ ring storage
    async def ring_status(self) -> dict:
        raw = await self.client.read_gatt_char(RING_STAT)
        used, unread, free, rtc = struct.unpack("<IIII", raw[:16])
        return {"used_bytes": used, "unread_packets": unread, "free_bytes": free, "rtc_valid": bool(rtc)}

    async def ring_info(self) -> RingInfo:
        self._drain_queue()
        await self.client.write_gatt_char(RING_CTRL, bytes([CMD_INFO]), response=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            m = await asyncio.wait_for(self._q.get(), 10)
            if m[0] == N_INFO and len(m) >= 31:
                r, w, cap, dropped, ps = struct.unpack(">QQIQH", m[1:31])
                return RingInfo(r, w, cap, dropped, ps)
            if m[0] == N_ACK and len(m) > 1 and m[1] != 0:
                raise PendantError(STATUS_TEXT.get(m[1], f"status {m[1]}"))
        raise PendantError("no INFO reply")

    async def ring_read(self, start: int, count: int,
                        progress: Optional[Callable[[int], None]] = None) -> tuple[bytes, int]:
        """Stream `count` records from `start`. Returns (bytes, next_seq)."""
        self._drain_queue()
        await self.client.write_gatt_char(
            RING_CTRL, bytes([CMD_READ]) + struct.pack(">QI", start, count), response=True)
        buf = bytearray()
        while True:
            try:
                m = await asyncio.wait_for(self._q.get(), 20)
            except asyncio.TimeoutError:
                raise PendantError(f"transfer stalled after {len(buf)} bytes")
            t = m[0]
            if t == N_DATA:
                buf += m[1:]
                if progress:
                    progress(len(buf))
            elif t == N_DONE:
                status, nxt = struct.unpack(">BQ", m[1:10])
                if status != 0:
                    raise PendantError("read failed: " + STATUS_TEXT.get(status, f"status {status}"))
                return bytes(buf), nxt
            elif t == N_ACK and len(m) > 1 and m[1] != 0:
                raise PendantError(STATUS_TEXT.get(m[1], f"status {m[1]}"))

    async def ring_advance(self, seq: int):
        await self.client.write_gatt_char(
            RING_CTRL, bytes([CMD_ADVANCE]) + struct.pack(">Q", seq), response=True)

    async def ring_stop(self):
        await self.client.write_gatt_char(RING_CTRL, bytes([CMD_STOP]), response=True)

    # ------------------------------------------------------------ settings / clock / button
    @property
    def connected(self) -> bool:
        return self.client.is_connected

    async def _read_u8(self, uuid: str) -> Optional[int]:
        try:
            return (await self.client.read_gatt_char(uuid))[0]
        except Exception:
            return None

    async def _write(self, uuid: str, data: bytes) -> bool:
        try:
            await self.client.write_gatt_char(uuid, data, response=True)
            return True
        except Exception:
            return False

    async def get_led(self) -> Optional[int]:
        return await self._read_u8(DIM_RATIO)

    async def set_led(self, pct: int) -> bool:
        return await self._write(DIM_RATIO, bytes([max(0, min(100, int(pct)))]))

    async def get_mic_gain(self) -> Optional[int]:
        return await self._read_u8(MIC_GAIN)

    async def set_mic_gain(self, level: int) -> bool:
        return await self._write(MIC_GAIN, bytes([max(0, min(8, int(level)))]))

    async def sync_clock(self) -> bool:
        return await self._write(TIME_WRITE, struct.pack("<I", int(time.time())))

    async def buzz(self, pattern) -> bool:
        """Play a vibration pattern; each pulse is one write, timed here."""
        ok = True
        for code, gap in pattern:
            ok = await self._write(HAPTIC, bytes([code])) and ok
            await asyncio.sleep({1: 0.1, 2: 0.3, 3: 0.5}.get(code, 0.1) + gap / 1000)
        return ok

    async def on_button(self, cb: Callable[[int], None]) -> bool:
        def _h(_h, data: bytearray):
            if len(data) >= 4:
                cb(struct.unpack_from("<i", bytes(data))[0])
        try:
            await self.client.start_notify(BUTTON, _h)
            return True
        except Exception:
            return False

    # ------------------------------------------------------------ live audio
    async def codec(self) -> int:
        return (await self.client.read_gatt_char(CODEC_TYPE))[0]

    async def start_live(self, on_opus_frame: Callable[[bytes], None]):
        """Subscribe to the live stream. Each notification is [pkt u16 LE][index u8][bytes];
        a frame longer than the MTU is split over several notifications with index 1, 2, ...
        A new frame always starts at index 0, so the buffer is flushed when one arrives."""
        buf = bytearray()

        def cb(_h, data: bytearray):
            nonlocal buf
            if len(data) <= 3:
                return
            if data[2] == 0 and buf:          # a new frame begins: the previous one is complete
                on_opus_frame(bytes(buf))
                buf = bytearray()
            buf += data[3:]

        def flush():
            nonlocal buf
            if buf:
                on_opus_frame(bytes(buf))
                buf = bytearray()
        self._live_flush = flush
        await self.client.start_notify(AUDIO_DATA, cb)

    async def stop_live(self):
        try:
            await self.client.stop_notify(AUDIO_DATA)
        except Exception:
            pass
        f = getattr(self, "_live_flush", None)
        if f:
            f()

    def _drain_queue(self):
        while not self._q.empty():
            self._q.get_nowait()


# ---------------------------------------------------------------- record parsing
def iter_records(raw: bytes):
    """Yield (unix_ts, [opus_frame, ...]) for each complete 444-byte record."""
    n = len(raw) - len(raw) % RECORD
    for off in range(0, n, RECORD):
        rec = raw[off:off + RECORD]
        ts = struct.unpack(">I", rec[:4])[0]
        payload, frames, i = rec[4:], [], 0
        while i < len(payload):
            size = payload[i]
            if size == 0 or i + 1 + size > len(payload):
                break
            frames.append(payload[i + 1:i + 1 + size])
            i += 1 + size
        yield ts, frames
