"""Earmark service: pendant connection + transcription + local web UI.

    python -m earmark.app            # serves http://127.0.0.1:8765

How audio reaches the Mac (see pendant.py for the firmware behaviour behind this):
  * pendant in range  -> Earmark stays connected and records the live stream (LED blue).
                         Double-tap on the pendant pauses/resumes; paused = LED off.
  * out of range      -> the pendant records to its own memory (LED red). On the next
                         connection Earmark drains that memory first, then goes live.
"""
from __future__ import annotations

import asyncio
import json
import os
import sqlite3
import sys
import time
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional

from concurrent.futures import ThreadPoolExecutor

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from . import pipeline as PL
from . import intel as IN
from . import speakers as SPK
from . import phone as PH
from . import appsync as AS

FAKE = os.environ.get("EARMARK_FAKE_PENDANT") == "1"
if FAKE:
    from . import fake_pendant as PEND
else:
    from . import pendant as PEND
from .pendant import (BTN_DOUBLE, BTN_TAP, BUZZ_EARMARK, BUZZ_PAUSED, BUZZ_RECORDING, OPUS_CODECS, RECORD,
                      TAP_PAIR_WINDOW_S)

PORT = int(os.environ.get("EARMARK_PORT", "8765"))
HOME = Path(os.environ.get("EARMARK_HOME", Path.home() / "Earmark"))
RAW_DIR, WAV_DIR, NOTES_DIR = HOME / "raw", HOME / "audio", HOME / "notes"
MODELS_DIR = HOME / "models"
# MLX (speech model + local notes model) ties loaded models to the thread that created them,
# so every MLX call runs on this one thread.
MLX = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
DB_PATH = HOME / "earmark.sqlite"
CONFIG_PATH = HOME / "config.json"
STATIC = Path(__file__).parent / "static"

DEFAULT_CONFIG = {
    "auto_sync": True,            # look for the pendant and connect automatically
    "stay_connected": True,       # record the live stream while in range (vs. short syncs)
    "poll_seconds": 20,           # how often to look for the pendant when it isn't connected
    "engine": "auto",             # auto | parakeet-v2 | parakeet-v3 | whisper
    "translate": True,            # auto: translate non-English speech to English
    "translate_model": "large-v3",
    "whisper_model": "small",     # engine=whisper
    "language": "",               # engine=whisper; blank = detect
    "ollama_host": "http://127.0.0.1:11434",
    "ollama_model": "",
    "session_gap_seconds": 90,
    "batch_records": 256,
    "led_brightness": 100,        # 0-100, written to the pendant on connect
    "mic_gain": -1,               # 0-8, -1 = leave the pendant's setting alone
    "double_tap_pause": True,
    "single_tap_earmark": True,   # single tap marks the moment as important
    "haptics": True,              # vibrate to confirm pause / resume / earmark
    "min_speech_seconds": 3,
    "intel_provider": "local",    # local | ollama | openai | anthropic | off
    "local_model": IN.DEFAULT_LOCAL,
    "openai_key": "",
    "openai_model": "gpt-4.1-mini",
    "anthropic_key": "",
    "anthropic_model": "claude-haiku-5-5",
    "identify_speakers": True,    # split conversations by voice and recognise people you have named
    "lan_access": False,          # also listen on this Mac's Wi-Fi address (phones must still be paired)      # sessions with less speech than this are deleted as noise
}


# ---------------------------------------------------------------- config + db
def load_config() -> dict:
    cfg = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.exists():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text()))
        except Exception:
            pass
    return cfg


def migrate_config():
    """One-time upgrades of an existing config.json."""
    raw = {}
    if CONFIG_PATH.exists():
        try:
            raw = json.loads(CONFIG_PATH.read_text())
        except Exception:
            raw = {}
    if raw.get("_v", 0) < 2:
        if raw.get("engine") in (None, "parakeet-v2"):   # old default -> auto (English + translation)
            raw["engine"] = "auto"
        if raw.get("poll_seconds") == 45:
            raw["poll_seconds"] = 20
        raw["_v"] = 2
        cfg = dict(DEFAULT_CONFIG)
        cfg.update(raw)
        save_config(cfg)


def save_config(cfg: dict):
    HOME.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))


def db() -> sqlite3.Connection:
    c = sqlite3.connect(DB_PATH)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    for d in (RAW_DIR, WAV_DIR, NOTES_DIR):
        d.mkdir(parents=True, exist_ok=True)
    with db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS sessions(
            id INTEGER PRIMARY KEY,
            started_at INTEGER NOT NULL,
            ended_at INTEGER NOT NULL,
            duration_s REAL NOT NULL,
            source TEXT NOT NULL,
            wav_path TEXT NOT NULL,
            note_path TEXT,
            title TEXT,
            language TEXT,
            transcript_json TEXT,
            summary_md TEXT,
            status TEXT NOT NULL DEFAULT 'queued',
            error TEXT,
            created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS tasks(
            id INTEGER PRIMARY KEY,
            text TEXT NOT NULL,
            owner TEXT NOT NULL DEFAULT 'me',
            due TEXT,
            due_text TEXT,
            status TEXT NOT NULL DEFAULT 'open',      -- open | done | dismissed
            suggested_done INTEGER NOT NULL DEFAULT 0,
            done_evidence TEXT,
            done_session INTEGER,
            session_id INTEGER,
            quote TEXT,
            t REAL,
            mentions INTEGER NOT NULL DEFAULT 1,
            origin TEXT NOT NULL DEFAULT 'auto',      -- auto | manual
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            completed_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS earmarks(
            id INTEGER PRIMARY KEY,
            at REAL NOT NULL,                         -- unix time of the tap
            session_id INTEGER,
            created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS devices(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            created_at INTEGER NOT NULL,
            last_seen INTEGER,
            revoked INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS people(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            is_me INTEGER NOT NULL DEFAULT 0,
            vec_sum TEXT,                             -- weighted sum of confirmed voice signatures
            weight REAL NOT NULL DEFAULT 0,           -- seconds of confirmed speech behind it
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS days(
            day TEXT PRIMARY KEY,
            brief_json TEXT,
            status TEXT NOT NULL DEFAULT 'stale',     -- stale | ready | error
            error TEXT,
            updated_at INTEGER
        );
        """)
        cols = {r[1] for r in c.execute("PRAGMA table_info(sessions)")}
        for col, ddl in (("notes_json", "TEXT"), ("kind", "TEXT"), ("intel_status", "TEXT"), ("intel_error", "TEXT"),
                         ("spk_status", "TEXT"), ("spk_json", "TEXT"), ("spk_error", "TEXT"), ("words_status", "TEXT")):
            if col not in cols:
                c.execute(f"ALTER TABLE sessions ADD COLUMN {col} {ddl}")
        c.execute("UPDATE sessions SET status='queued' WHERE status='transcribing'")
        c.execute("UPDATE sessions SET status='queued', error=NULL WHERE status='error' AND error LIKE '%Stream(%'")
        c.execute("UPDATE sessions SET intel_status='pending' WHERE status='done' AND intel_status IS NULL")
        c.execute("UPDATE sessions SET intel_status='pending' WHERE intel_status='working'")
        c.execute("UPDATE sessions SET spk_status='pending' WHERE spk_status='working'")
        c.execute("UPDATE sessions SET spk_status='pending', spk_error=NULL WHERE spk_status='error'")   # retry once per start
        c.execute("UPDATE sessions SET words_status='pending' WHERE words_status='working'")
        # one-time: speaker turns inside lines need word timings. Older transcripts are transcribed again
        # (notes and tasks are kept), newer ones only have their speakers worked out again.
        done = c.execute("SELECT v FROM kv WHERE k='estate_words_v1'").fetchone()
        if not done:
            for r in c.execute("SELECT id, transcript_json FROM sessions WHERE status='done'").fetchall():
                has_words = '"words"' in (r["transcript_json"] or "")
                c.execute("UPDATE sessions SET words_status=? , spk_status=CASE WHEN ? THEN 'pending' ELSE spk_status END WHERE id=?",
                          ("done" if has_words else "pending", has_words, r["id"]))
            c.execute("INSERT OR REPLACE INTO kv(k, v) VALUES('estate_words_v1', '1')")
        c.execute("UPDATE sessions SET spk_status='pending' WHERE status='done' AND spk_status IS NULL")


def kv_get(k: str, default=None):
    try:
        with db() as c:
            r = c.execute("SELECT v FROM kv WHERE k=?", (k,)).fetchone()
    except sqlite3.OperationalError:
        return default
    return json.loads(r["v"]) if r else default


def kv_set(k: str, v):
    with db() as c:
        c.execute("INSERT OR REPLACE INTO kv VALUES(?,?)", (k, json.dumps(v)))


# ---------------------------------------------------------------- state
class State:
    def __init__(self):
        # pendant side
        self.listening_lan = False    # bound to the Wi-Fi address as well as 127.0.0.1
        self.phase = "idle"           # idle | searching | connecting | syncing | recording | paused
        self.detail = ""
        self.progress = 0.0
        self.pendant = {"visible": None, "connected": False, "seen_at": None, "battery": None,
                        "firmware": None, "led": None, "mic_gain": None, "rtc_valid": None}
        self.paused: bool = bool(kv_get("paused", False))
        self.capture: Optional[PL.LiveCapture] = None
        self.app_caps: dict = {}               # device id -> appsync.PhoneCapture (uploads from the phone app)
        self.app_state: dict = {}              # device id -> last heartbeat
        self.pd = None                         # the connected pendant, for vibrations
        self.loop: Optional[asyncio.AbstractEventLoop] = None
        self.tap_pending: Optional[tuple] = None   # (monotonic time, wall time, timer handle)
        self.last_earmark: Optional[float] = None
        self.last_sync_at: Optional[int] = kv_get("last_sync_at")
        # signals
        self.wake = asyncio.Event()           # look for the pendant now
        self.settings_changed = asyncio.Event()
        self.pause_changed = asyncio.Event()
        self.work = asyncio.Event()           # wakes the processing loop
        # processing side
        self.proc_phase = "idle"
        self.proc_detail = ""
        self.proc_pct: Optional[int] = None
        self.downloading = False
        self.proc_sid: Optional[int] = None
        self.log: deque = deque(maxlen=200)

    def say(self, msg: str, level: str = "info"):
        self.log.appendleft({"t": int(time.time()), "level": level, "msg": msg})
        print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)

    def set(self, phase: str, detail: str = "", progress: float = 0.0):
        self.phase, self.detail, self.progress = phase, detail, progress


init_db()
S = State()


def buzz(pattern):
    """Vibrate the pendant, if it is connected and vibration is on. Safe from any thread."""
    pd, loop = S.pd, S.loop
    if pd is None or loop is None or not load_config()["haptics"]:
        return
    loop.call_soon_threadsafe(lambda: loop.create_task(pd.buzz(pattern)))


def handle_button(ev: int):
    """Runs on the event loop. A firmware double tap pauses/resumes. A single tap earmarks the
    moment, but only after TAP_PAIR_WINDOW_S: a second single tap in that window means the
    person double-tapped a little slowly, so it pauses/resumes instead."""
    cfg = load_config()
    now = time.monotonic()
    if ev == BTN_DOUBLE:
        _cancel_tap()
        if cfg["double_tap_pause"]:
            set_paused(not S.paused, "double-tap on the pendant")
        return
    if ev != BTN_TAP:
        return
    if S.tap_pending and now - S.tap_pending[0] <= TAP_PAIR_WINDOW_S:
        _cancel_tap()
        if cfg["double_tap_pause"]:
            set_paused(not S.paused, "double-tap on the pendant")
        return
    if not cfg["single_tap_earmark"]:
        return
    wall = time.time()
    handle = asyncio.get_running_loop().call_later(TAP_PAIR_WINDOW_S, _commit_earmark, wall)
    S.tap_pending = (now, wall, handle)


def _cancel_tap():
    if S.tap_pending:
        S.tap_pending[2].cancel()
        S.tap_pending = None


def _commit_earmark(at: float):
    S.tap_pending = None
    if S.paused:
        buzz(BUZZ_PAUSED)                      # remind: nothing is being recorded
        S.say("Tap ignored: recording is paused", "warn")
        return
    with db() as c:
        c.execute("INSERT INTO earmarks(at, created_at) VALUES(?, ?)", (at, int(time.time())))
    S.last_earmark = at
    buzz(BUZZ_EARMARK)
    S.say(f"Earmarked the moment at {datetime.fromtimestamp(at):%H:%M:%S}")


def _earmark_offsets(sid: int, started_at: float) -> list:
    with db() as c:
        return [round(r[0] - started_at, 1) for r in c.execute("SELECT at FROM earmarks WHERE session_id=? ORDER BY at", (sid,))]


def _attach_earmarks(sid: int, started_at: float, ended_at: float):
    with db() as c:
        c.execute("UPDATE earmarks SET session_id=? WHERE session_id IS NULL AND at BETWEEN ? AND ?",
                  (sid, started_at - 5, ended_at + 15))


def set_paused(paused: bool, why: str):
    if paused == S.paused:
        return
    S.paused = paused
    kv_set("paused", paused)
    S.pause_changed.set()
    if not _phone_holder():
        buzz(BUZZ_PAUSED if paused else BUZZ_RECORDING)
    S.say(("Recording paused" if paused else "Recording resumed") + f" ({why})")


# ---------------------------------------------------------------- phone app holding the pendant
def _phone_holder() -> Optional[dict]:
    """The phone app that has the pendant right now (heartbeat within HOLD_TTL_S), if any."""
    now = time.time()
    best = None
    for st in S.app_state.values():
        if st.get("holds_pendant") and now - st["at"] < AS.HOLD_TTL_S:
            if best is None or st["at"] > best["at"]:
                best = st
    return best


def _phone_wants_pendant() -> bool:
    now = time.time()
    return any((st.get("holds_pendant") or st.get("wants_pendant")) and now - st["at"] < AS.HOLD_TTL_S
               for st in S.app_state.values())


def _phone_status_into_state(st: dict):
    S.pendant.update(connected=bool(st.get("pendant_connected")), visible=True, via=st.get("device_name"),
                     seen_at=int(st["at"]))
    if st.get("battery") is not None:
        S.pendant["battery"] = st["battery"]
        kv_set("battery", {"pct": st["battery"], "at": int(st["at"])})
    phase = st.get("state") or "recording"
    if S.paused and phase == "recording":
        phase = "paused"
    S.set(phase if phase in ("recording", "paused", "searching", "connecting") else "idle",
          f"on {st.get('device_name') or 'your phone'}")


# ---------------------------------------------------------------- pendant connection
async def pendant_loop():
    await asyncio.sleep(1)
    await decode_pending(load_config())          # anything saved but not decoded last run
    for s in PL.recover_partials(WAV_DIR):       # live sessions interrupted by a crash
        add_session(s, "live")
        S.say(f"recovered an interrupted recording ({int(s.duration_s // 60)} min)")
    while True:
        cfg = load_config()
        holder = _phone_holder()
        if holder:
            _phone_status_into_state(holder)
            await _wait_wake(10)
            S.wake.clear()
            continue
        if S.pendant.get("via"):
            S.pendant.update(via=None, connected=False)
            S.set("idle")
        if not cfg["auto_sync"] and not S.wake.is_set():
            S.set("idle", "automatic connection is off")
            await _wait_wake(cfg["poll_seconds"])
            continue
        S.wake.clear()
        S.set("searching", "looking for the pendant")
        try:
            dev = await PEND.scan(8)
        except Exception as e:
            S.say(f"Bluetooth scan failed: {e}", "error")
            dev = None
        if not dev:
            if S.pendant["visible"] is not False:
                S.say("pendant not found: out of range, or connected to another app such as Omi "
                      "on your phone. Quit that app so Earmark can connect.", "warn")
            S.pendant.update(visible=False, connected=False)
            S.set("idle")
            await _wait_wake(cfg["poll_seconds"])
            continue
        if S.pendant["visible"] is False:
            S.say("pendant found")
        S.pendant["visible"] = True
        try:
            await connected_session(dev, cfg)
        except Exception as e:
            S.say(f"pendant connection ended: {e}", "warn")
        finally:
            S.pendant["connected"] = False
            S.pd = None
            _cancel_tap()
            if S.capture:
                S.capture.finish()
                _collect_live()
                S.capture = None
            S.set("idle")
        if not load_config()["stay_connected"]:
            await _wait_wake(cfg["poll_seconds"])
        else:
            await asyncio.sleep(2)


async def _wait_wake(seconds: float):
    try:
        await asyncio.wait_for(S.wake.wait(), seconds)
    except asyncio.TimeoutError:
        pass


async def connected_session(dev, cfg: dict):
    S.set("connecting", "connecting to the pendant")
    async with PEND.open_pendant(dev) as pd:
        S.pendant.update(connected=True, seen_at=int(time.time()), via=None)
        await _refresh_device_info(pd)
        if await pd.sync_clock():
            S.pendant["rtc_valid"] = True
        await _apply_device_settings(pd, cfg)

        await drain_ring(pd, cfg)
        await decode_pending(cfg)

        if not cfg["stay_connected"]:
            S.say("sync finished; disconnecting so the pendant keeps recording to its memory")
            return
        codec = await pd.codec()
        if codec not in OPUS_CODECS:
            S.say(f"pendant streams codec {codec}, which Earmark can't decode; using sync-only mode", "error")
            return

        loop = asyncio.get_running_loop()

        def on_button(ev: int):
            loop.call_soon_threadsafe(handle_button, ev)
        await pd.on_button(on_button)
        S.pd = pd

        cap = PL.LiveCapture(WAV_DIR, gap_s=int(cfg["session_gap_seconds"]))
        cap.set_paused(S.paused)
        S.capture = cap
        await pd.start_live(cap.push)
        S.say("connected: recording live" + (" (paused)" if S.paused else ""))
        last_info = time.monotonic()
        while pd.connected:
            cfg = load_config()
            if _phone_wants_pendant():
                S.say("your phone is taking over the pendant")
                break
            if not cfg["stay_connected"] or not cfg["auto_sync"]:
                S.say("live recording turned off in settings; disconnecting")
                break
            if S.settings_changed.is_set():
                S.settings_changed.clear()
                await _apply_device_settings(pd, cfg)
            if S.pause_changed.is_set():
                S.pause_changed.clear()
                cap.set_paused(S.paused)
                await _apply_device_settings(pd, cfg)
            _collect_live()
            if time.monotonic() - last_info > 120:
                await _refresh_device_info(pd, light=True)
                last_info = time.monotonic()
            S.pendant["seen_at"] = int(time.time())
            if S.paused:
                S.set("paused", "double-tap the pendant or press Resume to record")
            else:
                m, sec = divmod(int(cap.open_seconds), 60)
                S.set("recording", f"{m}:{sec:02d} in the current session" if cap.open_seconds >= 1 else "listening")
            await asyncio.sleep(1)
        S.pd = None
        _cancel_tap()
        await pd.stop_live()
        cap.finish()
        _collect_live()


def _collect_live():
    if S.capture:
        for s in S.capture.take_closed():
            add_session(s, "live")
            S.say(f"session saved ({int(s.duration_s // 60)} min {int(s.duration_s % 60)} s), queued for transcription")


async def _refresh_device_info(pd, light: bool = False):
    batt = await pd.battery()
    if batt is not None:
        S.pendant["battery"] = batt
        kv_set("battery", {"pct": batt, "at": int(time.time())})
    if not light:
        S.pendant["firmware"] = await pd.firmware()
        try:
            st = await pd.ring_status()
            S.pendant["rtc_valid"] = st["rtc_valid"]
        except Exception:
            pass


async def _apply_device_settings(pd, cfg: dict):
    want_led = 0 if S.paused else int(cfg["led_brightness"])
    if await pd.get_led() != want_led:
        await pd.set_led(want_led)
    S.pendant["led"] = await pd.get_led()
    if int(cfg["mic_gain"]) >= 0 and await pd.get_mic_gain() != int(cfg["mic_gain"]):
        await pd.set_mic_gain(int(cfg["mic_gain"]))
    S.pendant["mic_gain"] = await pd.get_mic_gain()


async def drain_ring(pd, cfg: dict):
    """Copy what the pendant recorded while disconnected. Bytes are fsynced before the
    pendant is told it may release them."""
    try:
        info = await pd.ring_info()
    except Exception as e:
        S.say(f"could not read the pendant's memory: {e}", "warn")
        return
    if info.dropped and info.dropped != kv_get("last_dropped", 0):
        S.say(f"the pendant's memory filled up and overwrote {info.dropped} old packets", "warn")
        kv_set("last_dropped", info.dropped)
    seq, end = info.read_seq, info.write_seq
    local = kv_get("next_seq")
    if local and local > seq:
        seq = min(local, end)
    if seq >= end:
        return
    total = end - seq
    S.say(f"copying {max(1, round(total * 440 / 4000 / 60))} min of audio recorded while away")
    while seq < end:
        done = total - (end - seq)
        S.set("syncing", f"{round(done * 440 / 4000 / 60)} of {round(total * 440 / 4000 / 60)} min", done / total)
        raw, nxt = await pd.ring_read(seq, min(int(cfg["batch_records"]), end - seq))
        raw = raw[:len(raw) - len(raw) % RECORD]
        p = RAW_DIR / f"{int(time.time())}_{seq}_{nxt}.bin"
        with open(p, "wb") as fh:
            fh.write(raw)
            fh.flush()
            os.fsync(fh.fileno())
        await pd.ring_advance(nxt)
        kv_set("next_seq", nxt)
        seq = nxt
    S.last_sync_at = int(time.time())
    kv_set("last_sync_at", S.last_sync_at)


async def decode_pending(cfg: dict) -> int:
    done = set(kv_get("decoded_raw", []))
    pending = [p for p in sorted(RAW_DIR.glob("*.bin")) if p.name not in done]
    if not pending:
        return 0
    loop = asyncio.get_running_loop()
    try:
        sessions = await loop.run_in_executor(
            None, lambda: PL.decode_raw(pending, WAV_DIR, int(cfg["session_gap_seconds"])))
    except Exception as e:
        S.say(f"could not decode copied audio: {e}", "error")
        return 0
    for s in sessions:
        add_session(s, "pendant")
    kv_set("decoded_raw", sorted(done | {p.name for p in pending}))
    if sessions:
        S.say(f"{len(sessions)} session(s) from the pendant's memory queued for transcription")
    return len(sessions)


def add_session(s: PL.DecodedSession, source: str) -> int:
    with db() as c:
        cur = c.execute(
            "INSERT INTO sessions(started_at, ended_at, duration_s, source, wav_path, status, created_at)"
            " VALUES(?,?,?,?,?,'queued',?)",
            (s.started_at, s.ended_at, s.duration_s, source, str(s.wav_path), int(time.time())))
        sid = cur.lastrowid
    _attach_earmarks(sid, s.started_at, s.ended_at)
    S.work.set()
    return sid


# ---------------------------------------------------------------- processing
async def process_queue(cfg: dict):
    loop = asyncio.get_running_loop()
    while True:
        with db() as c:
            row = c.execute("SELECT * FROM sessions WHERE status='queued' ORDER BY started_at").fetchone()
        if not row:
            return
        sid = row["id"]
        label = datetime.fromtimestamp(row["started_at"]).strftime("%a %H:%M session")
        try:
            S.proc_phase, S.proc_detail, S.proc_pct, S.proc_sid = "transcribing", f"{label}: checking for speech", None, sid
            speech = await loop.run_in_executor(
                None, lambda: PL.has_speech(Path(row["wav_path"]), float(cfg["min_speech_seconds"])))
            if not speech:
                _delete_session(sid)
                S.say(f"{label}: no speech, only noise; deleted without transcribing")
                continue
            watcher = None
            if not PL.engine_ready(cfg["engine"], cfg["whisper_model"]):
                S.proc_phase, S.proc_detail = "transcribing", "setting up the speech model (first run only)"
                S.say("setting up the speech model: one-time download")
                repo = PL.engine_repo(cfg["engine"])
                if repo:
                    watcher = asyncio.create_task(_watch_download(repo))
            else:
                S.proc_phase, S.proc_detail = "transcribing", label
            with db() as c:
                c.execute("UPDATE sessions SET status='transcribing' WHERE id=?", (sid,))

            S.proc_pct, S.proc_sid = 0.0, sid

            def prog(frac, lang=None):
                if S.downloading:
                    return
                S.proc_pct = round(100 * frac)
                if lang and lang != "en":
                    S.proc_detail = f"{label}: translating {PL.LANG_NAMES.get(lang, lang)}"
                elif S.proc_phase == "transcribing" and "setting up" not in S.proc_detail:
                    S.proc_detail = label

            S.proc_label = label
            try:
                tr = await loop.run_in_executor(MLX, lambda: PL.transcribe(
                Path(row["wav_path"]), cfg["whisper_model"], cfg["language"] or None, cfg["engine"],
                    bool(cfg["translate"]), cfg["translate_model"], progress=prog))
            finally:
                if watcher:
                    watcher.cancel()
            with db() as c:
                still_there = c.execute("SELECT 1 FROM sessions WHERE id=?", (sid,)).fetchone()
            if not still_there:
                S.say("a session was deleted while it was being processed; skipped")
                continue
            if not tr["segments"]:
                _delete_session(sid)
                S.say(f"{label}: no speech found, removed")
                continue
            summary = None
            title = _title_from(summary, tr["text"], row["started_at"])
            note = PL.write_note(NOTES_DIR, title, row["started_at"], row["duration_s"], summary, tr)
            with db() as c:
                c.execute("UPDATE sessions SET status='done', intel_status='pending', title=?, language=?, transcript_json=?,"
                          " summary_md=?, note_path=?, error=NULL, spk_status=?, spk_json=NULL, words_status='done' WHERE id=?",
                          (title, tr["language"], json.dumps(tr["segments"]), summary, str(note),
                           "pending" if cfg.get("identify_speakers", True) else "off", sid))
            S.say(f"transcript ready: {label}")
        except Exception as e:
            with db() as c:
                gone = c.execute("SELECT 1 FROM sessions WHERE id=?", (sid,)).fetchone() is None
                if not gone:
                    c.execute("UPDATE sessions SET status='error', error=? WHERE id=?", (str(e), sid))
            if not gone:
                S.say(f"processing failed for {label}: {e}", "error")
        S.proc_phase, S.proc_detail, S.proc_pct, S.proc_sid = "idle", "", None, None


async def _watch_download(repo: str):
    """Show real download progress while the speech model is being fetched."""
    loop = asyncio.get_running_loop()
    total = await loop.run_in_executor(None, PL.repo_total_bytes, repo)
    saved_pct, saved_detail = S.proc_pct, S.proc_detail
    S.downloading = True
    last, last_t, rate = 0, time.monotonic(), 0.0
    try:
        while True:
            have = await loop.run_in_executor(None, PL.download_progress, repo)
            now = time.monotonic()
            if have > last and now > last_t:
                rate = 0.7 * rate + 0.3 * (have - last) / (now - last_t) if rate else (have - last) / (now - last_t)
                last, last_t = have, now
            if total and have >= total:
                break
            gb = have / 1e9
            if total:
                S.proc_pct = min(99, round(100 * have / total))
                eta = f", about {max(1, round((total - have) / rate / 60))} min left" if rate > 0 else ""
                S.proc_detail = f"downloading the speech model, one time: {gb:.1f} of {total / 1e9:.1f} GB{eta}"
            else:
                S.proc_detail = f"downloading the speech model, one time: {gb:.1f} GB so far"
            if now - last_t > 180:
                S.proc_detail += " (no progress for 3 min: check the internet connection)"
            await asyncio.sleep(2)
    except asyncio.CancelledError:
        pass
    finally:
        S.downloading = False
        S.proc_pct, S.proc_detail = saved_pct, getattr(S, "proc_label", saved_detail)


def _title_from(summary: Optional[str], text: str, started_at: int) -> str:
    src = ""
    if summary:
        for line in summary.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                src = line.lstrip("-* ")
                break
    if not src:
        src = text.strip().split("\n")[0] if text.strip() else ""
    if not src:
        return datetime.fromtimestamp(started_at).strftime("Quiet session, %a %H:%M")
    return (src[:72] + "…") if len(src) > 72 else src



# ---------------------------------------------------------------- speakers
def _spk_load(raw) -> dict:
    try:
        d = json.loads(raw) if raw else None
    except Exception:
        d = None
    return d if isinstance(d, dict) and isinstance(d.get("speakers"), list) else {"speakers": []}


def _people(with_vec: bool = True) -> list:
    with db() as c:
        rows = [dict(r) for r in c.execute("SELECT * FROM people ORDER BY is_me DESC, name COLLATE NOCASE")]
    out = []
    for r in rows:
        v = json.loads(r["vec_sum"]) if r["vec_sum"] else None
        p = {"id": r["id"], "name": r["name"], "is_me": bool(r["is_me"]), "seconds": round(r["weight"], 1),
             "trained": bool(v)}
        if with_vec:
            p["vec"] = v
        out.append(p)
    return out


def _person_by_name(c, name: str) -> Optional[int]:
    name = " ".join(name.split()).strip()
    if not name:
        return None
    is_me = name.lower() in ("me", "myself")
    if is_me:
        r = c.execute("SELECT id FROM people WHERE is_me=1").fetchone()
        if r:
            return r[0]
        name = "Me"
    r = c.execute("SELECT id FROM people WHERE name=?", (name,)).fetchone()
    if r:
        return r[0]
    now = int(time.time())
    return c.execute("INSERT INTO people(name, is_me, created_at, updated_at) VALUES(?,?,?,?)",
                     (name, 1 if is_me else 0, now, now)).lastrowid


def _voice_add(c, pid: int, vec: Optional[list], w: float, sign: int = 1):
    """Add (or with sign=-1 remove) one speaker's signature to a person's saved voice."""
    if not vec or w <= 0:
        return
    r = c.execute("SELECT vec_sum, weight FROM people WHERE id=?", (pid,)).fetchone()
    if not r:
        return
    cur = json.loads(r["vec_sum"]) if r["vec_sum"] else [0.0] * len(vec)
    w = min(w, 600.0)                                   # one long meeting shouldn't drown everything else
    new = [a + sign * w * b for a, b in zip(cur, vec)]
    weight = max(0.0, r["weight"] + sign * w)
    c.execute("UPDATE people SET vec_sum=?, weight=?, updated_at=? WHERE id=?",
              (json.dumps([round(x, 5) for x in new]) if weight > 0.5 else None, weight, int(time.time()), pid))


def _speaker_public(sp: dict, people: dict) -> dict:
    p = people.get(sp.get("person_id"))
    return {"label": sp["label"], "seconds": sp.get("seconds", 0), "sample": sp.get("sample"),
            "state": sp.get("state", "none") if p or sp.get("guess_me") else "none",
            "person_id": sp.get("person_id") if p else None, "name": p["name"] if p else None,
            "is_me": bool(p and p["is_me"]), "sim": sp.get("sim"), "guess_me": bool(sp.get("guess_me"))}


def _named_segments(segs: list, spk: dict) -> list:
    """Segments with "who" set from named speakers, for the notes model."""
    people = {p["id"]: p for p in _people(False)}
    names = {}
    for sp in spk.get("speakers", []):
        p = people.get(sp.get("person_id"))
        if p and sp.get("state") in ("confirmed", "auto"):
            names[sp["label"]] = "me" if p["is_me"] else p["name"]
    if not names:
        return segs
    return [{**s, "who": names.get(s.get("spk"))} for s in segs]


async def speaker_queue(cfg: dict):
    loop = asyncio.get_running_loop()
    while True:
        with db() as c:
            row = c.execute("SELECT * FROM sessions WHERE status='done' AND spk_status='pending' "
                            "ORDER BY intel_status='pending' DESC, started_at DESC LIMIT 1").fetchone()
        if not row:
            return
        sid = row["id"]
        if not cfg.get("identify_speakers", True):
            with db() as c:
                c.execute("UPDATE sessions SET spk_status='off' WHERE spk_status='pending'")
            return
        label = datetime.fromtimestamp(row["started_at"]).strftime("%a %H:%M")
        with db() as c:
            c.execute("UPDATE sessions SET spk_status='working' WHERE id=?", (sid,))
        try:
            S.proc_phase, S.proc_sid, S.proc_pct = "speakers", sid, None
            if not SPK.runtime_ready() and not SPK.fake():
                S.proc_detail = "setting up voice recognition (one time)"
                S.say("setting up voice recognition: one-time install")
                await loop.run_in_executor(None, SPK.ensure_runtime)
            if not SPK.model_ready(MODELS_DIR):
                S.say("downloading the voice model (40 MB, one time)")

                def dl(have, total):
                    S.proc_pct = round(100 * have / max(1, total))
                    S.proc_detail = f"downloading the voice model, one time: {have / 1e6:.0f} of {total / 1e6:.0f} MB"
                await loop.run_in_executor(None, lambda: SPK.ensure_model(MODELS_DIR, dl))
            S.proc_detail, S.proc_pct = f"{label}: telling voices apart", 0
            segs = json.loads(row["transcript_json"] or "[]")
            old_segs = json.loads(row["transcript_json"] or "[]")          # untouched copy for carrying names over
            old_spk = _spk_load(row["spk_json"])

            def prog(f):
                S.proc_pct = round(100 * f)
            res = await loop.run_in_executor(None, lambda: SPK.analyse(MODELS_DIR, Path(row["wav_path"]), segs, _people(), prog))
            new_segs = res["segments"]
            for s, lab in zip(new_segs, res["labels"]):
                s["spk"] = lab
            _carry_over(old_spk, old_segs, res["speakers"], new_segs)
            segs = new_segs
            with db() as c:
                if not c.execute("SELECT 1 FROM sessions WHERE id=?", (sid,)).fetchone():
                    continue
                c.execute("UPDATE sessions SET transcript_json=?, spk_json=?, spk_status='done', spk_error=NULL WHERE id=?",
                          (json.dumps(segs), json.dumps({"speakers": res["speakers"]}), sid))
            known = [sp for sp in res["speakers"] if sp["state"] == "auto"]
            S.say(f"speakers: {label}, {len(res['speakers'])} voice{'s' if len(res['speakers']) != 1 else ''}"
                  + (f", recognised {len(known)}" if known else ""))
        except Exception as e:
            with db() as c:
                c.execute("UPDATE sessions SET spk_status='error', spk_error=? WHERE id=?", (str(e)[:300], sid))
            S.say(f"couldn't identify speakers for {label}: {e}", "error")
        S.proc_phase, S.proc_detail, S.proc_pct, S.proc_sid = "idle", "", None, None


def _carry_over(old_spk: dict, old_segs: list, speakers: list, segs: list):
    """When a conversation's speakers are worked out again, keep what you already confirmed:
    a voice you named stays named (its saved training is not counted twice), and lines you
    gave to someone by hand go back to that person."""
    people_ids = {p["id"] for p in _people(False)}
    confirmed = {sp["person_id"]: sp.get("contrib") for sp in old_spk.get("speakers", [])
                 if sp.get("state") == "confirmed" and sp.get("person_id") in people_ids}
    for sp in speakers:
        if sp.get("person_id") in confirmed and sp.get("state") in ("auto", "suggested"):
            sp.update(state="confirmed")
            if confirmed[sp["person_id"]]:
                sp["contrib"] = confirmed.pop(sp["person_id"])
    # confirmed people not found by voice this time: keep their training record on the first label we give them
    old_label_person = {sp["label"]: sp.get("person_id") for sp in old_spk.get("speakers", [])
                        if sp.get("state") == "confirmed"}
    manual = [(g["start"], g["end"], old_label_person.get(g.get("spk"))) for g in old_segs
              if g.get("spk_manual") and old_label_person.get(g.get("spk"))]
    for a, b, pid in manual:
        target = next((sp for sp in speakers if sp.get("person_id") == pid), None)
        if target is None:
            n = 1
            while any(x["label"] == f"S{n}" for x in speakers):
                n += 1
            target = {"label": f"S{n}", "seconds": 0, "vec": None, "rms": 0, "sample": [a, b],
                      "person_id": pid, "sim": None, "state": "confirmed"}
            if confirmed.get(pid):
                target["contrib"] = confirmed.pop(pid)
            speakers.append(target)
        for g in segs:
            ov = min(b, g["end"]) - max(a, g["start"])
            if ov > 0.5 * max(0.01, g["end"] - g["start"]):
                g["spk"], g["spk_manual"] = target["label"], True
    secs: dict = {}
    for g in segs:
        secs[g["spk"]] = secs.get(g["spk"], 0.0) + max(0.0, g["end"] - g["start"])
    speakers[:] = [sp for sp in speakers if sp["label"] in secs]
    for sp in speakers:
        sp["seconds"] = round(secs[sp["label"]], 1)


async def words_queue(cfg: dict):
    """Background, one conversation per pass: transcribe older recordings again to get word timings,
    keeping their notes, tasks and title. New recordings always go first."""
    loop = asyncio.get_running_loop()
    with db() as c:
        row = c.execute("SELECT * FROM sessions WHERE status='done' AND words_status='pending' "
                        "ORDER BY started_at DESC LIMIT 1").fetchone()
        left = c.execute("SELECT COUNT(*) FROM sessions WHERE status='done' AND words_status='pending'").fetchone()[0]
    if not row or not cfg.get("identify_speakers", True):
        return False
    sid = row["id"]
    label = datetime.fromtimestamp(row["started_at"]).strftime("%a %H:%M")
    with db() as c:
        c.execute("UPDATE sessions SET words_status='working' WHERE id=?", (sid,))
    try:
        S.proc_phase, S.proc_sid, S.proc_pct = "refreshing", sid, 0
        S.proc_detail = f"{label}: word timings for speaker labels ({left} to go)"

        def prog(frac, lang=None):
            S.proc_pct = round(100 * frac)
        tr = await loop.run_in_executor(MLX, lambda: PL.transcribe(
            Path(row["wav_path"]), cfg["whisper_model"], cfg["language"] or None, cfg["engine"],
            bool(cfg["translate"]), cfg["translate_model"], progress=prog))
        with db() as c:
            cur = c.execute("SELECT transcript_json, spk_json FROM sessions WHERE id=?", (sid,)).fetchone()
            if not cur:
                return True
            old = json.loads(cur["transcript_json"] or "[]")
            new = tr["segments"]
            if new:
                # carry hand-made speaker fixes over by time; the speaker pass re-labels the rest
                for g in new:
                    hit = next((o for o in old if o.get("spk_manual") and min(o["end"], g["end"]) - max(o["start"], g["start"])
                                > 0.5 * max(0.01, g["end"] - g["start"])), None)
                    if hit:
                        g["spk"], g["spk_manual"] = hit.get("spk"), True
                c.execute("UPDATE sessions SET transcript_json=?, words_status='done', spk_status='pending' WHERE id=?",
                          (json.dumps(new), sid))
            else:
                c.execute("UPDATE sessions SET words_status='done' WHERE id=?", (sid,))
    except Exception as e:
        with db() as c:
            c.execute("UPDATE sessions SET words_status='error' WHERE id=?", (sid,))
        S.say(f"couldn't refresh word timings for {label}: {e}", "warn")
    S.proc_phase, S.proc_detail, S.proc_pct, S.proc_sid = "idle", "", None, None
    return True


# ---------------------------------------------------------------- intelligence: notes, tasks, day brief
def _day_of(ts: int) -> str:
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def _mark_day_stale(day: str):
    with db() as c:
        c.execute("INSERT INTO days(day, status, updated_at) VALUES(?, 'stale', ?) "
                  "ON CONFLICT(day) DO UPDATE SET status='stale'", (day, int(time.time())))


def _open_tasks() -> list:
    with db() as c:
        return [dict(r) for r in c.execute("SELECT * FROM tasks WHERE status='open' ORDER BY created_at DESC LIMIT 200")]


def _notes_markdown(n: dict) -> str:
    out = []
    if n.get("summary"):
        out += ["## Summary", n["summary"], ""]
    for key, head in (("key_points", "Key points"), ("decisions", "Decisions")):
        if n.get(key):
            out += [f"## {head}"] + [f"- {x}" for x in n[key]] + [""]
    if n.get("tasks"):
        out += ["## Action items"] + [f"- [{'x' if t['done'] else ' '}] {t['task']}"
                                     + (f" ({t['owner']})" if t['owner'] not in ('me', 'unknown') else "")
                                     + (f", due {t['due']}" if t.get('due') else "") for t in n["tasks"]] + [""]
    if n.get("people"):
        out += ["## People", ", ".join(n["people"]), ""]
    return "\n".join(out).strip()


async def intel_queue(cfg: dict):
    """Notes + tasks for every transcribed conversation, oldest first."""
    if cfg["intel_provider"] == "off" and os.environ.get("EARMARK_FAKE_LLM") != "1":
        return
    loop = asyncio.get_running_loop()
    while True:
        with db() as c:
            row = c.execute("SELECT * FROM sessions WHERE status='done' AND intel_status='pending' "
                            "AND COALESCE(spk_status,'') NOT IN ('pending','working') "
                            "ORDER BY started_at LIMIT 1").fetchone()
        if not row:
            return
        sid = row["id"]
        label = datetime.fromtimestamp(row["started_at"]).strftime("%a %H:%M")
        segs = _named_segments(json.loads(row["transcript_json"] or "[]"), _spk_load(row["spk_json"]))
        marks = _earmark_offsets(sid, row["started_at"])
        with db() as c:
            c.execute("UPDATE sessions SET intel_status='working' WHERE id=?", (sid,))
        watcher = None
        try:
            st = IN.status(cfg)
            if cfg["intel_provider"] == "local" and not st["ready"]:
                S.proc_phase, S.proc_detail, S.proc_pct, S.proc_sid = "thinking", "setting up the notes model (one time)", None, sid
                S.say("setting up the local notes model: one-time download")
                await loop.run_in_executor(MLX, IN.ensure_local_runtime)
                watcher = asyncio.create_task(_watch_download(cfg["local_model"]))
            else:
                S.proc_phase, S.proc_detail, S.proc_pct, S.proc_sid = "thinking", f"{label}: reading the conversation", 5, sid

            def prog(frac, what):
                if not S.downloading:
                    S.proc_pct, S.proc_detail = round(5 + 85 * frac), f"{label}: {what}"
            S.proc_label = f"{label}: reading the conversation"
            try:
                notes = await loop.run_in_executor(MLX, lambda: IN.conversation_notes(cfg, segs, row["started_at"], prog, marks))
            finally:
                if watcher:
                    watcher.cancel()
            S.proc_pct, S.proc_detail = 92, f"{label}: updating your tasks"
            opened = _open_tasks()
            try:
                fu = await loop.run_in_executor(MLX, lambda: IN.follow_up(cfg, opened, notes))
            except Exception as e:
                S.say(f"task follow-up skipped: {e}", "warn")
                fu = {"completed": [], "duplicates": []}
            with db() as c:
                if not c.execute("SELECT 1 FROM sessions WHERE id=?", (sid,)).fetchone():
                    continue
            new_n, merged, flagged = _apply_tasks(sid, notes, fu, opened)
            title = notes["title"] or row["title"]
            with db() as c:
                c.execute("UPDATE sessions SET notes_json=?, kind=?, title=?, summary_md=?, intel_status='done', "
                          "intel_error=NULL WHERE id=?",
                          (json.dumps(notes, ensure_ascii=False), notes["kind"], title, _notes_markdown(notes), sid))
            tr = {"language": row["language"], "segments": segs}
            try:
                PL.write_note(NOTES_DIR, title, row["started_at"], row["duration_s"], _notes_markdown(notes), tr)
            except Exception:
                pass
            _mark_day_stale(_day_of(row["started_at"]))
            bits = [f"{new_n} new task{'s' if new_n != 1 else ''}"] if new_n else []
            if merged:
                bits.append(f"{merged} already on your list")
            if flagged:
                bits.append(f"{flagged} look{'s' if flagged == 1 else ''} done")
            S.say(f"notes ready: {title}" + (f" ({', '.join(bits)})" if bits else ""))
        except Exception as e:
            with db() as c:
                c.execute("UPDATE sessions SET intel_status='error', intel_error=? WHERE id=?", (str(e)[:300], sid))
            S.say(f"couldn't write notes for {label}: {e}", "error")
        S.proc_phase, S.proc_detail, S.proc_pct, S.proc_sid = "idle", "", None, None


def _apply_tasks(sid: int, notes: dict, fu: dict, opened: list) -> tuple[int, int, int]:
    now = int(time.time())
    dup_of = {d["new"]: d["id"] for d in fu.get("duplicates", [])}
    new_n = merged = flagged = 0
    with db() as c:
        c.execute("DELETE FROM tasks WHERE session_id=? AND origin='auto' AND status='open' AND mentions<=1", (sid,))
        for i, t in enumerate(notes["tasks"]):
            target = dup_of.get(i)
            if target is None:                          # cheap backstop for near-identical wording
                for o in opened:
                    if IN.similar(o["text"], t["task"]) >= 0.75:
                        target = o["id"]
                        break
            if target is not None:
                c.execute("UPDATE tasks SET mentions=mentions+1, updated_at=?, due=COALESCE(?, due), "
                          "due_text=COALESCE(?, due_text) WHERE id=?", (now, t["due"], t["due_text"], target))
                if t["done"]:
                    c.execute("UPDATE tasks SET suggested_done=1, done_evidence=?, done_session=? WHERE id=? AND status='open'",
                              (t["quote"], sid, target))
                    flagged += 1
                merged += 1
                continue
            status = "done" if t["done"] else "open"
            c.execute("INSERT INTO tasks(text, owner, due, due_text, status, session_id, quote, t, origin, "
                      "created_at, updated_at, completed_at) VALUES(?,?,?,?,?,?,?,?,'auto',?,?,?)",
                      (t["task"], t["owner"], t["due"], t["due_text"], status, sid, t["quote"], t["t"],
                       now, now, now if t["done"] else None))
            new_n += 0 if t["done"] else 1
        for comp in fu.get("completed", []):
            c.execute("UPDATE tasks SET suggested_done=1, done_evidence=?, done_session=?, updated_at=? "
                      "WHERE id=? AND status='open'", (str(comp.get("evidence", ""))[:240], sid, now, comp["id"]))
            flagged += 1
    return new_n, merged, flagged


async def day_queue(cfg: dict):
    """Refresh stale day briefs once the conversation notes for that day are in."""
    if cfg["intel_provider"] == "off" and os.environ.get("EARMARK_FAKE_LLM") != "1":
        return
    loop = asyncio.get_running_loop()
    with db() as c:
        stale = [r["day"] for r in c.execute("SELECT day FROM days WHERE status='stale' ORDER BY day DESC")]
    for day in stale:
        t0 = int(datetime.strptime(day, "%Y-%m-%d").timestamp())
        with db() as c:
            rows = [dict(r) for r in c.execute(
                "SELECT id, started_at, duration_s, title, kind, notes_json, intel_status FROM sessions "
                "WHERE started_at>=? AND started_at<? AND status='done' ORDER BY started_at", (t0, t0 + 86400))]
        if any(r["intel_status"] in ("pending", "working") for r in rows):
            continue                                   # wait until the day's notes are written
        rows = [r for r in rows if r["notes_json"] and json.loads(r["notes_json"]).get("kind") != "ambient"]
        if not rows:
            with db() as c:
                c.execute("UPDATE days SET status='ready', brief_json=NULL, updated_at=? WHERE day=?", (int(time.time()), day))
            continue
        for r in rows:
            r["notes"] = json.loads(r["notes_json"])
        S.proc_phase, S.proc_detail, S.proc_pct = "thinking", f"writing the brief for {datetime.strptime(day, '%Y-%m-%d').strftime('%A')}", None
        try:
            brief = await loop.run_in_executor(MLX, lambda: IN.day_brief(cfg, datetime.strptime(day, "%Y-%m-%d").date(), rows))
            with db() as c:
                c.execute("UPDATE days SET brief_json=?, status='ready', error=NULL, updated_at=? WHERE day=?",
                          (json.dumps(brief, ensure_ascii=False), int(time.time()), day))
        except Exception as e:
            with db() as c:
                c.execute("UPDATE days SET status='error', error=?, updated_at=? WHERE day=?", (str(e)[:300], int(time.time()), day))
        S.proc_phase, S.proc_detail, S.proc_pct = "idle", "", None


async def proc_loop():
    while True:
        try:
            _app_idle_check()
            # Each kind of model is loaded only for its own step and freed straight after,
            # so at most one of them occupies memory at a time.
            loop = asyncio.get_running_loop()
            await process_queue(load_config())
            await loop.run_in_executor(MLX, PL.unload_models)
            await speaker_queue(load_config())
            await loop.run_in_executor(None, SPK.unload)
            await intel_queue(load_config())
            await day_queue(load_config())
            await loop.run_in_executor(MLX, IN.unload_local)
            did = await words_queue(load_config())
            await loop.run_in_executor(MLX, PL.unload_models)
            if did:
                await speaker_queue(load_config())
                await loop.run_in_executor(None, SPK.unload)
                S.work.clear()
                try:                                      # older recordings: a breather between each one
                    await asyncio.wait_for(S.work.wait(), 20)
                except asyncio.TimeoutError:
                    pass
                continue
        except Exception as e:
            S.say(f"processing error: {e}", "error")
        S.proc_phase, S.proc_detail = "idle", ""
        S.work.clear()
        try:
            await asyncio.wait_for(S.work.wait(), 30)
        except asyncio.TimeoutError:
            pass


def _delete_session(sid: int):
    with db() as c:
        r = c.execute("SELECT wav_path, note_path, started_at FROM sessions WHERE id=?", (sid,)).fetchone()
        c.execute("DELETE FROM sessions WHERE id=?", (sid,))
        c.execute("DELETE FROM tasks WHERE session_id=? AND origin='auto' AND status!='done'", (sid,))
    if r:
        _mark_day_stale(_day_of(r["started_at"]))
    if r:
        for p in (r["wav_path"], r["note_path"]):
            if p and Path(p).exists():
                try:
                    Path(p).unlink()
                except OSError:
                    pass


# ---------------------------------------------------------------- api
@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    migrate_config()
    S.loop = asyncio.get_running_loop()
    freed = PL.remove_abandoned_downloads()
    if freed:
        S.say(f"removed {freed / 1e9:.1f} GB of abandoned partial model downloads")
    tasks = [asyncio.create_task(pendant_loop()), asyncio.create_task(proc_loop())]
    S.say(f"Earmark ready at http://127.0.0.1:{PORT}" + ("  [simulated pendant]" if FAKE else ""))
    yield
    for t in tasks:
        t.cancel()


app = FastAPI(title="Earmark", lifespan=lifespan)

_OPEN_PATHS = ("/pair", "/api/app/pair", "/static/manifest.webmanifest", "/static/icon-180.png", "/static/icon-192.png",
               "/static/icon-512.png", "/static/icon.png")


@app.middleware("http")
async def guard(request: Request, call_next):
    """This Mac's own browser is trusted. Everyone else (Tailscale, Wi-Fi) needs a paired-device cookie."""
    local = PH.is_local(request.client.host if request.client else None, request.headers)
    request.state.local = local
    auth = request.headers.get("authorization") or ""
    if local:
        if auth.lower().startswith("bearer "):          # the app talking to Earmark on this same Mac
            with db() as c:
                dev = PH.device_for(c, auth[7:].strip())
            if dev:
                request.state.device = dev
        return await call_next(request)
    path = request.url.path
    if path in _OPEN_PATHS:
        return await call_next(request)
    token = request.cookies.get(PH.COOKIE)
    if auth.lower().startswith("bearer "):
        token = auth[7:].strip()
    with db() as c:
        dev = PH.device_for(c, token)
    if dev:
        request.state.device = dev
        return await call_next(request)
    if path.startswith("/api/"):
        return JSONResponse({"detail": "This device is not paired with Earmark."}, status_code=401)
    return HTMLResponse(PH.UNPAIRED_PAGE.replace("__CODE__", "").replace("__ERR__", ""), status_code=401)


def _local_only(request: Request):
    if not getattr(request.state, "local", False):
        raise HTTPException(403, "Only possible from Earmark on the Mac itself.")


@app.get("/pair")
def pair_page(code: str = ""):
    code = "".join(ch for ch in code if ch.isdigit())[:6]
    return HTMLResponse(PH.UNPAIRED_PAGE.replace("__CODE__", code).replace("__ERR__", ""))


@app.post("/pair")
async def pair_submit(request: Request):
    from urllib.parse import parse_qs
    body = parse_qs((await request.body()).decode(errors="ignore"))
    code = (body.get("code") or [""])[0]
    with db() as c:
        token = PH.redeem(c, code, PH.device_name(request.headers.get("user-agent", "")))
    if not token:
        return HTMLResponse(PH.UNPAIRED_PAGE.replace("__CODE__", "").replace(
            "__ERR__", "That code didn't work. It may have expired: make a new one on the Mac."), status_code=400)
    S.say(f"paired a new device: {PH.device_name(request.headers.get('user-agent', ''))}")
    host = (request.headers.get("host") or "")
    secure = request.headers.get("x-forwarded-proto") == "https" or host.split(":")[0].endswith(".ts.net") \
        or request.url.scheme == "https"
    r = RedirectResponse("/#/today", status_code=303)
    r.set_cookie(PH.COOKIE, token, max_age=400 * 86400, httponly=True, secure=secure, samesite="lax", path="/")
    return r


# ---------------------------------------------------------------- the Earmark phone app
def _app_device(request: Request) -> dict:
    dev = getattr(request.state, "device", None)
    if not dev:
        raise HTTPException(401, "pair this app first")
    return dev


@app.post("/api/app/pair")
def api_app_pair(request: Request, body: dict):
    name = " ".join(str(body.get("name") or "").split())[:40] or "Phone"
    platform = str(body.get("platform") or "")[:20]
    with db() as c:
        token = PH.redeem(c, str(body.get("code", "")), f"Earmark app on {name}" + (f" ({platform})" if platform else ""))
    if not token:
        raise HTTPException(400, "That code didn't work. Make a new one on the Mac: Settings, Phone, Pair a phone.")
    S.say(f"paired the Earmark app on {name}")
    return {"token": token, "server": "Earmark", "version": 1}


def _app_settings() -> dict:
    cfg = load_config()
    return {k: cfg.get(k) for k in ("led_brightness", "mic_gain", "single_tap_earmark", "double_tap_pause",
                                    "haptics", "session_gap_seconds")}


@app.post("/api/app/heartbeat")
def api_app_heartbeat(request: Request, body: dict):
    dev = _app_device(request)
    st = {"at": time.time(), "device_id": dev["id"], "device_name": dev["name"].replace("Earmark app on ", ""),
          "holds_pendant": bool(body.get("holds_pendant")), "wants_pendant": bool(body.get("wants_pendant")),
          "pendant_connected": bool(body.get("pendant_connected")), "battery": body.get("battery"),
          "state": str(body.get("state") or ""), "session_seconds": body.get("session_seconds"),
          "queued_seconds": body.get("queued_seconds"), "app_version": str(body.get("app_version") or "")[:20]}
    first = dev["id"] not in S.app_state or not S.app_state[dev["id"]].get("holds_pendant")
    was_holding = not first
    S.app_state[dev["id"]] = st
    if was_holding and not st["holds_pendant"] and not _phone_holder():
        S.pendant.update(via=None, connected=bool(S.pd))
        S.say(f"{st['device_name']} let go of the pendant")
        S.wake.set()
    if st["holds_pendant"]:
        _phone_status_into_state(st)
        if first:
            S.say(f"{st['device_name']} has the pendant; this Mac steps back")
        S.wake.set()
    with db() as c:
        seq = (kv_get(f"app_seq_{dev['id']}") or 0)
    return {"ok": True, "paused": S.paused, "settings": _app_settings(), "last_seq": seq,
            "mac_has_pendant": bool(S.pd), "server_time": time.time()}


@app.post("/api/app/audio")
async def api_app_audio(request: Request):
    dev = _app_device(request)
    try:
        start = float(request.headers.get("x-earmark-start", ""))
        seq = int(request.headers.get("x-earmark-seq", ""))
    except ValueError:
        raise HTTPException(400, "X-Earmark-Start and X-Earmark-Seq are required")
    codec = int(request.headers.get("x-earmark-codec", "21") or 21)
    if codec not in OPUS_CODECS:
        raise HTTPException(415, f"codec {codec} is not supported")
    if abs(start - time.time()) > 30 * 86400:
        raise HTTPException(400, "recording time is implausible; is the phone clock right?")
    body = await request.body()
    if len(body) > 8 * 1024 * 1024:
        raise HTTPException(413, "chunk too large")
    try:
        frames = AS.parse_frames(body)
    except ValueError as e:
        raise HTTPException(400, str(e))
    key = f"app_seq_{dev['id']}"
    last = kv_get(key) or 0
    if seq <= last:
        return {"ok": True, "duplicate": True, "last_seq": last}
    pc = S.app_caps.get(dev["id"])
    if pc is None:
        cfg = load_config()
        pc = S.app_caps[dev["id"]] = AS.PhoneCapture(
            WAV_DIR, int(cfg["session_gap_seconds"]), lambda s: _phone_session(s))
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, lambda: pc.add(start, frames))
    kv_set(key, seq)
    return {"ok": True, "last_seq": seq, "frames": len(frames)}


def _phone_session(s: PL.DecodedSession):
    add_session(s, "phone")
    S.say(f"session from the phone saved ({int(s.duration_s // 60)} min {int(s.duration_s % 60)} s), queued for transcription")


@app.post("/api/app/event")
def api_app_event(request: Request, body: dict):
    dev = _app_device(request)
    kind = str(body.get("type") or "")
    at = float(body.get("at") or time.time())
    if kind == "earmark":
        with db() as c:
            c.execute("INSERT INTO earmarks(at, created_at) VALUES(?, ?)", (at, int(time.time())))
        S.last_earmark = at
        S.say(f"Earmarked the moment at {datetime.fromtimestamp(at):%H:%M:%S} (on the phone)")
    elif kind in ("pause", "resume"):
        set_paused(kind == "pause", f"from {dev['name'].replace('Earmark app on ', '')}")
    else:
        raise HTTPException(400, "unknown event")
    return {"ok": True, "paused": S.paused}


def _app_idle_check():
    for pc in list(S.app_caps.values()):
        pc.idle_check()


@app.get("/api/phone")
def api_phone(request: Request):
    _local_only(request)
    cfg = load_config()
    with db() as c:
        devs = [dict(r) for r in c.execute("SELECT id, name, created_at, last_seen FROM devices WHERE revoked=0 ORDER BY created_at DESC")]
        r = c.execute("SELECT v FROM kv WHERE k='pair_code'").fetchone()
    code = json.loads(r[0]) if r else None
    if code and time.time() > code["exp"]:
        code = None
    ip = PH.lan_ip()
    return {"tailscale": PH.tailscale_status(PORT), "lan_access": bool(cfg.get("lan_access")),
            "lan_url": f"http://{ip}:{PORT}" if ip else None, "lan_live": S.listening_lan,
            "devices": devs, "code": {"code": code["code"], "exp": code["exp"]} if code else None}


@app.post("/api/phone/code")
def api_phone_code(request: Request):
    _local_only(request)
    with db() as c:
        rec = PH.new_code(c)
    return {"code": rec["code"], "exp": rec["exp"]}


@app.post("/api/phone/tailscale")
def api_phone_tailscale(request: Request, body: dict):
    _local_only(request)
    r = PH.tailscale_enable(PORT) if body.get("on", True) else PH.tailscale_disable(PORT)
    _phone_cache["at"] = 0.0
    S.say("phone access through Tailscale " + ("turned on" if body.get("on", True) and r["ok"] else
                                                "turned off" if r["ok"] else f"failed: {r['output'][:160]}"))
    return {**r, "tailscale": PH.tailscale_status(PORT)}


@app.post("/api/phone/lan")
def api_phone_lan(request: Request, body: dict):
    _local_only(request)
    cfg = load_config()
    cfg["lan_access"] = bool(body.get("on"))
    save_config(cfg)
    return {"ok": True, "restart_needed": cfg["lan_access"] != S.listening_lan}


@app.delete("/api/phone/devices/{did}")
def api_phone_forget(request: Request, did: int):
    _local_only(request)
    with db() as c:
        c.execute("UPDATE devices SET revoked=1 WHERE id=?", (did,))
    return {"ok": True}


@app.get("/api/status")
def api_status():
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    t0 = int(today.timestamp())
    with db() as c:
        rows = c.execute("SELECT started_at, ended_at, duration_s FROM sessions WHERE ended_at>=?", (t0,)).fetchall()
        counts = dict(c.execute("SELECT status, COUNT(*) FROM sessions GROUP BY status").fetchall())
    open_s = S.capture.open_seconds if S.capture else 0
    holder = _phone_holder()
    if holder:
        open_s = max(open_s, float(holder.get("session_seconds") or 0))
    return {
        "phase": S.phase, "detail": S.detail, "progress": S.progress,
        "proc_phase": S.proc_phase, "proc_detail": S.proc_detail, "proc_pct": S.proc_pct, "proc_sid": S.proc_sid,
        "pendant": S.pendant, "paused": S.paused, "last_sync_at": S.last_sync_at,
        "battery": kv_get("battery"), "open_seconds": open_s, "last_earmark": S.last_earmark,
        "today": {"captured_seconds": sum(r["duration_s"] for r in rows) + open_s,
                  "spans": [[r["started_at"], r["ended_at"]] for r in rows], "day_start": t0},
        "counts": counts, "log": list(S.log)[:30], "simulated": FAKE,
        "tasks": _task_counts(), "intel": _intel_status(), "phone": _phone_status(),
    }


@app.get("/api/sessions")
def api_sessions(q: str = "", kind: str = "", limit: int = Query(300, le=2000)):
    sql, args = "SELECT * FROM sessions WHERE 1=1", []
    if q:
        sql += " AND (title LIKE ? OR summary_md LIKE ? OR transcript_json LIKE ?)"
        args += [f"%{q}%"] * 3
    if kind:
        sql += " AND kind=?"
        args.append(kind)
    sql += " ORDER BY started_at DESC LIMIT ?"
    with db() as c:
        return [_session_card(r) for r in c.execute(sql, args + [limit])]


@app.get("/api/sessions/{sid}")
def api_session(sid: int):
    with db() as c:
        r = c.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
    if not r:
        raise HTTPException(404)
    d = dict(r)
    d["segments"] = json.loads(d.pop("transcript_json") or "[]")
    d["notes"] = json.loads(d.pop("notes_json") or "null")
    d["earmarks"] = _earmark_offsets(sid, d["started_at"])
    people = {p["id"]: p for p in _people(False)}
    d["speakers"] = [_speaker_public(sp, people) for sp in _spk_load(d.pop("spk_json", None))["speakers"]]
    with db() as c:
        d["tasks"] = [dict(t) for t in c.execute(
            "SELECT * FROM tasks WHERE session_id=? OR done_session=? ORDER BY t", (sid, sid))]
    return d


@app.get("/api/sessions/{sid}/audio")
def api_audio(sid: int):
    with db() as c:
        r = c.execute("SELECT wav_path FROM sessions WHERE id=?", (sid,)).fetchone()
    if not r or not Path(r["wav_path"]).exists():
        raise HTTPException(404)
    return FileResponse(r["wav_path"], media_type="audio/wav")


@app.post("/api/sessions/{sid}/retry")
def api_retry(sid: int):
    with db() as c:
        c.execute("UPDATE sessions SET status='queued', error=NULL WHERE id=?", (sid,))
    S.work.set()
    return {"ok": True}


@app.patch("/api/sessions/{sid}")
def api_rename(sid: int, body: dict):
    with db() as c:
        c.execute("UPDATE sessions SET title=? WHERE id=?", (str(body.get("title", ""))[:120], sid))
    return {"ok": True}


@app.delete("/api/sessions/{sid}")
def api_delete(sid: int):
    _delete_session(sid)
    S.work.set()
    return {"ok": True}


@app.post("/api/sync")
def api_sync():
    """Look for the pendant now (and copy anything in its memory)."""
    S.wake.set()
    return {"ok": True}


@app.post("/api/pause")
def api_pause(body: dict):
    set_paused(bool(body.get("paused")), "from the app")
    return {"ok": True, "paused": S.paused}


@app.post("/api/restart")
def api_restart():
    def _go():
        time.sleep(0.5)
        os.execv(sys.executable, [sys.executable, "-m", "earmark.app"])
    import threading
    threading.Thread(target=_go, daemon=True).start()
    return {"ok": True}


# ---------------------------------------------------------------- day / tasks / search
_intel_cache = {"at": 0.0, "v": None}


def _intel_status() -> dict:
    """Readiness of the notes model; cached because the page polls status every few seconds."""
    if time.monotonic() - _intel_cache["at"] > 30 or _intel_cache["v"] is None:
        _intel_cache["v"], _intel_cache["at"] = IN.status(load_config()), time.monotonic()
    return _intel_cache["v"]


_phone_cache = {"at": 0.0, "serving": False}


def _phone_status() -> dict:
    """Is Earmark reachable from a phone, and has a paired phone used it in the last two minutes?"""
    if time.time() - _phone_cache["at"] > 60:
        _phone_cache["at"] = time.time()
        try:
            _phone_cache["serving"] = PH.tailscale_status(PORT).get("serving", False) if PH.tailscale_bin() else False
        except Exception:
            _phone_cache["serving"] = False
    with db() as c:
        active = [r[0] for r in c.execute("SELECT name FROM devices WHERE revoked=0 AND last_seen>?", (int(time.time()) - 120,))]
        paired = c.execute("SELECT COUNT(*) FROM devices WHERE revoked=0").fetchone()[0]
    return {"on": bool(_phone_cache["serving"] or S.listening_lan), "tailscale": bool(_phone_cache["serving"]),
            "paired": paired, "active": active}


def _task_counts() -> dict:
    today = datetime.now().strftime("%Y-%m-%d")
    with db() as c:
        mine = "status='open' AND LOWER(COALESCE(owner,'me')) IN ('me','unknown','')"
        r = c.execute(f"SELECT SUM({mine}), SUM({mine} AND due IS NOT NULL AND due<?), "
                      f"SUM({mine} AND suggested_done=1), SUM(status='open') FROM tasks", (today,)).fetchone()
    # "open" is what the side menu shows: your own open tasks, the same as the Mine tab
    return {"open": r[0] or 0, "overdue": r[1] or 0, "looks_done": r[2] or 0, "all_open": r[3] or 0}


def _session_card(r) -> dict:
    n = json.loads(r["notes_json"]) if r["notes_json"] else None
    return {"id": r["id"], "started_at": r["started_at"], "ended_at": r["ended_at"], "duration_s": r["duration_s"],
            "title": r["title"], "kind": r["kind"], "status": r["status"], "intel_status": r["intel_status"],
            "source": r["source"], "language": r["language"],
            "gist": (n or {}).get("summary", "")[:220] if n else None,
            "people": (n or {}).get("people", []) if n else [],
            "topics": (n or {}).get("topics", []) if n else [],
            "task_count": len([t for t in (n or {}).get("tasks", []) if not t.get("done")]) if n else 0,
            "earmark_count": _earmark_count(r["id"]),
            "speakers": _card_speakers(r)}


def _card_speakers(r) -> list:
    try:
        raw = r["spk_json"]
    except (IndexError, KeyError):
        return []
    sps = _spk_load(raw)["speakers"]
    if not sps:
        return []
    people = {p["id"]: p for p in _people(False)}
    out = []
    for sp in sorted(sps, key=lambda x: -x.get("seconds", 0)):
        p = people.get(sp.get("person_id"))
        if p and sp.get("state") in ("confirmed", "auto") and not p["is_me"]:
            out.append(p["name"])
    return out


def _earmark_count(sid: int) -> int:
    with db() as c:
        return c.execute("SELECT COUNT(*) FROM earmarks WHERE session_id=?", (sid,)).fetchone()[0]


@app.get("/api/day")
def api_day(d: str = ""):
    day = d or datetime.now().strftime("%Y-%m-%d")
    try:
        t0 = int(datetime.strptime(day, "%Y-%m-%d").timestamp())
    except ValueError:
        raise HTTPException(400, "date must be YYYY-MM-DD")
    with db() as c:
        rows = c.execute("SELECT * FROM sessions WHERE started_at>=? AND started_at<? ORDER BY started_at DESC",
                         (t0, t0 + 86400)).fetchall()
        dr = c.execute("SELECT * FROM days WHERE day=?", (day,)).fetchone()
        prev = c.execute("SELECT MAX(started_at) FROM sessions WHERE started_at<?", (t0,)).fetchone()[0]
        nxt = c.execute("SELECT MIN(started_at) FROM sessions WHERE started_at>=?", (t0 + 86400,)).fetchone()[0]
        tasks = [dict(t) for t in c.execute(
            "SELECT t.*, s.title AS session_title FROM tasks t LEFT JOIN sessions s ON s.id=t.session_id "
            "WHERE t.status='open' AND (t.created_at BETWEEN ? AND ? OR t.due=?) ORDER BY t.due IS NULL, t.due, t.created_at",
            (t0, t0 + 86400, day))]
    cards = [_session_card(r) for r in rows]
    return {"day": day, "is_today": day == datetime.now().strftime("%Y-%m-%d"),
            "brief": json.loads(dr["brief_json"]) if dr and dr["brief_json"] else None,
            "brief_status": dr["status"] if dr else ("none" if not cards else "stale"),
            "sessions": cards, "tasks": tasks,
            "captured_s": sum(r["duration_s"] for r in rows),
            "spans": [[r["started_at"], r["ended_at"], r["id"], r["kind"]] for r in rows], "day_start": t0,
            "earmarks": _day_earmarks(t0),
            "prev": _day_of(prev) if prev else None, "next": _day_of(nxt) if nxt else None}


def _day_earmarks(t0: int) -> list:
    with db() as c:
        return [[r[0], r[1]] for r in c.execute("SELECT at, session_id FROM earmarks WHERE at>=? AND at<? ORDER BY at", (t0, t0 + 86400))]


@app.post("/api/day/{day}/refresh")
def api_day_refresh(day: str):
    _mark_day_stale(day)
    S.work.set()
    return {"ok": True}


@app.get("/api/tasks")
def api_tasks(view: str = "open"):
    where = {"open": "t.status='open'", "done": "t.status='done'", "all": "t.status!='dismissed'"}.get(view, "t.status='open'")
    with db() as c:
        rows = [dict(t) for t in c.execute(
            f"SELECT t.*, s.title AS session_title, s.started_at AS session_started FROM tasks t "
            f"LEFT JOIN sessions s ON s.id=t.session_id WHERE {where} "
            f"ORDER BY t.status='done', COALESCE(t.completed_at,0) DESC, t.due IS NULL, t.due, t.created_at DESC LIMIT 500")]
    return rows


@app.post("/api/tasks")
def api_task_add(body: dict):
    text = str(body.get("text", "")).strip()
    if not text:
        raise HTTPException(400, "task text is required")
    now = int(time.time())
    due = body.get("due") or None
    with db() as c:
        cur = c.execute("INSERT INTO tasks(text, owner, due, status, origin, created_at, updated_at) "
                        "VALUES(?,?,?,'open','manual',?,?)", (text[:300], str(body.get("owner") or "me"), due, now, now))
        return {"id": cur.lastrowid}


@app.patch("/api/tasks/{tid}")
def api_task_update(tid: int, body: dict):
    now = int(time.time())
    sets, args = [], []
    if "status" in body:
        st = body["status"]
        if st not in ("open", "done", "dismissed"):
            raise HTTPException(400, "bad status")
        sets += ["status=?", "completed_at=?", "suggested_done=0"]
        args += [st, now if st == "done" else None]
    if body.get("suggested_done") is False:
        sets += ["suggested_done=0", "done_evidence=NULL"]
    for k in ("text", "owner", "due"):
        if k in body:
            sets.append(f"{k}=?")
            args.append((str(body[k]).strip() or None) if body[k] is not None else None)
    if not sets:
        return {"ok": True}
    with db() as c:
        c.execute(f"UPDATE tasks SET {', '.join(sets)}, updated_at=? WHERE id=?", args + [now, tid])
    return {"ok": True}


@app.delete("/api/tasks/{tid}")
def api_task_delete(tid: int):
    with db() as c:
        c.execute("DELETE FROM tasks WHERE id=?", (tid,))
    return {"ok": True}


@app.post("/api/sessions/{sid}/renotes")
def api_renotes(sid: int):
    with db() as c:
        c.execute("UPDATE sessions SET intel_status='pending', intel_error=NULL WHERE id=? AND status='done'", (sid,))
    S.work.set()
    return {"ok": True}


def _session_spk(c, sid: int):
    r = c.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
    if not r:
        raise HTTPException(404)
    return r, json.loads(r["transcript_json"] or "[]"), _spk_load(r["spk_json"])


def _recount(segs: list, spk: dict):
    secs: dict = {}
    for s in segs:
        if s.get("spk"):
            secs[s["spk"]] = secs.get(s["spk"], 0.0) + max(0.0, float(s.get("end", 0)) - float(s.get("start", 0)))
    spk["speakers"] = [sp for sp in spk["speakers"] if sp["label"] in secs]
    for sp in spk["speakers"]:
        sp["seconds"] = round(secs[sp["label"]], 1)


def _uncontribute(c, sp: dict):
    k = sp.pop("contrib", None)
    if k:
        _voice_add(c, k["person_id"], sp.get("vec"), k["w"], -1)


def _contribute(c, sp: dict):
    if sp.get("person_id") and sp.get("vec"):
        w = float(sp.get("seconds", 0))
        _voice_add(c, sp["person_id"], sp["vec"], w)
        sp["contrib"] = {"person_id": sp["person_id"], "w": w}


def _merge_label(segs: list, spk: dict, src: str, dst: str):
    """Move every line of speaker src into dst (same person named twice)."""
    for s in segs:
        if s.get("spk") == src:
            s["spk"] = dst
    a = next(sp for sp in spk["speakers"] if sp["label"] == src)
    b = next(sp for sp in spk["speakers"] if sp["label"] == dst)
    if a.get("vec") and b.get("vec"):
        wa, wb = float(a.get("seconds", 0)), float(b.get("seconds", 0))
        v = [(x * wa + y * wb) for x, y in zip(a["vec"], b["vec"])]
        n = sum(x * x for x in v) ** 0.5 or 1.0
        b["vec"] = [round(x / n, 5) for x in v]
    elif a.get("vec"):
        b["vec"] = a["vec"]
    spk["speakers"] = [sp for sp in spk["speakers"] if sp["label"] != src]


def _save_spk(c, sid: int, segs: list, spk: dict):
    _recount(segs, spk)
    c.execute("UPDATE sessions SET transcript_json=?, spk_json=? WHERE id=?", (json.dumps(segs), json.dumps(spk), sid))


def _spk_response(sid: int) -> dict:
    with db() as c:
        r, segs, spk = _session_spk(c, sid)
    people = {p["id"]: p for p in _people(False)}
    return {"ok": True, "speakers": [_speaker_public(sp, people) for sp in spk["speakers"]],
            "labels": [s.get("spk") for s in segs]}


@app.post("/api/sessions/{sid}/speakers/{label}")
def api_speaker_name(sid: int, label: str, body: dict):
    """Name a speaker (or confirm the suggestion with no name). Empty name clears it.
    Naming two speakers the same person merges them."""
    with db() as c:
        r, segs, spk = _session_spk(c, sid)
        sp = next((x for x in spk["speakers"] if x["label"] == label), None)
        if not sp:
            raise HTTPException(404, "no such speaker")
        name = body.get("name")
        if name is None:                                     # confirm what is shown
            if not sp.get("person_id"):
                if sp.get("guess_me"):
                    sp["person_id"] = _person_by_name(c, "me")
                else:
                    raise HTTPException(400, "nothing to confirm")
            pid = sp["person_id"]
        else:
            pid = _person_by_name(c, str(name))
        _uncontribute(c, sp)
        sp.pop("guess_me", None)
        if pid is None:
            sp.update(person_id=None, state="none", sim=None)
            _save_spk(c, sid, segs, spk)
            return _spk_response(sid)
        other = next((x for x in spk["speakers"] if x is not sp and x.get("person_id") == pid
                      and x.get("state") in ("confirmed", "auto", "suggested")), None)
        if other:
            _uncontribute(c, other)
            _merge_label(segs, spk, label, other["label"])
            _recount(segs, spk)
            sp = other
        sp.update(person_id=pid, state="confirmed", sim=None)
        _contribute(c, sp)
        _save_spk(c, sid, segs, spk)
    _mark_names_changed(sid)
    return _spk_response(sid)


@app.post("/api/sessions/{sid}/lines")
def api_lines_speaker(sid: int, body: dict):
    """Give lines first..last to a speaker: an existing label, or a person's name."""
    first, last = int(body.get("first", -1)), int(body.get("last", body.get("first", -1)))
    with db() as c:
        r, segs, spk = _session_spk(c, sid)
        if not (0 <= first <= last < len(segs)):
            raise HTTPException(400, "bad line range")
        target = body.get("label")
        if not target:
            pid = _person_by_name(c, str(body.get("name") or ""))
            if pid is None:
                raise HTTPException(400, "give a label or a name")
            hit = next((x for x in spk["speakers"] if x.get("person_id") == pid), None)
            if hit:
                target = hit["label"]
            else:
                n = 1
                while any(x["label"] == f"S{n}" for x in spk["speakers"]):
                    n += 1
                target = f"S{n}"
                spans = [[segs[i]["start"], segs[i]["end"]] for i in range(first, last + 1)]
                try:
                    vec = SPK.clip_vec(MODELS_DIR, Path(r["wav_path"]), spans) if SPK.model_ready(MODELS_DIR) else None
                except Exception:
                    vec = None
                new = {"label": target, "seconds": 0, "vec": vec, "rms": 0, "sample": spans[0],
                       "person_id": pid, "sim": None, "state": "confirmed"}
                spk["speakers"].append(new)
        elif not any(x["label"] == target for x in spk["speakers"]):
            raise HTTPException(404, "no such speaker")
        for i in range(first, last + 1):
            segs[i]["spk"] = target
            segs[i]["spk_manual"] = True
        _recount(segs, spk)
        sp = next(x for x in spk["speakers"] if x["label"] == target)
        if sp.get("state") == "confirmed" and sp.get("person_id") and not sp.get("contrib"):
            _contribute(c, sp)
        _save_spk(c, sid, segs, spk)
    _mark_names_changed(sid)
    return _spk_response(sid)


@app.post("/api/sessions/{sid}/split")
def api_split_line(sid: int, body: dict):
    """Split line `index` before word number `word`; the second part starts as the same speaker."""
    i, k = int(body.get("index", -1)), int(body.get("word", 0))
    with db() as c:
        r, segs, spk = _session_spk(c, sid)
        if not 0 <= i < len(segs):
            raise HTTPException(400, "bad line")
        g = segs[i]
        words = g.get("words")
        if not words:                                  # no timings: spread the line's time over its words
            toks = g["text"].split()
            step = (g["end"] - g["start"]) / max(1, len(toks))
            words = [[round(g["start"] + j * step, 2), round(g["start"] + (j + 1) * step, 2), w] for j, w in enumerate(toks)]
        if not 0 < k < len(words):
            raise HTTPException(400, "split point must be inside the line")
        a, b = words[:k], words[k:]
        first = {**g, "start": a[0][0], "end": a[-1][1], "text": " ".join(w[2] for w in a), "words": a}
        second = {**g, "start": b[0][0], "end": b[-1][1], "text": " ".join(w[2] for w in b), "words": b}
        segs[i:i + 1] = [first, second]
        _save_spk(c, sid, segs, spk)
    return {**_spk_response(sid), "segments": segs}


@app.post("/api/sessions/{sid}/speakers")
def api_speakers_rerun(sid: int):
    with db() as c:
        c.execute("UPDATE sessions SET spk_status='pending', spk_error=NULL WHERE id=?", (sid,))
    S.work.set()
    return {"ok": True}


def _mark_names_changed(sid: int):
    """A voice was named or corrected: look again at unnamed speakers in other conversations."""
    people = _people()
    with db() as c:
        rows = c.execute("SELECT id, spk_json FROM sessions WHERE spk_json IS NOT NULL AND id!=? "
                         "ORDER BY started_at DESC LIMIT 400", (sid,)).fetchall()
        for r in rows:
            spk = _spk_load(r["spk_json"])
            before = json.dumps(spk["speakers"])
            for sp in spk["speakers"]:
                if sp.get("state") in ("auto", "suggested") and not sp.get("guess_me"):
                    sp.update(person_id=None, state="none", sim=None)
            SPK.match(spk["speakers"], people)
            if json.dumps(spk["speakers"]) != before:
                c.execute("UPDATE sessions SET spk_json=? WHERE id=?", (json.dumps(spk), r["id"]))


@app.get("/api/people")
def api_people():
    with db() as c:
        rows = c.execute("SELECT id, spk_json FROM sessions WHERE spk_json IS NOT NULL").fetchall()
    used: dict = {}
    for r in rows:
        for sp in _spk_load(r["spk_json"])["speakers"]:
            if sp.get("person_id") and sp.get("state") in ("confirmed", "auto"):
                used[sp["person_id"]] = used.get(sp["person_id"], 0) + 1
    return [{**p, "conversations": used.get(p["id"], 0)} for p in _people(False)]


@app.patch("/api/people/{pid}")
def api_person_rename(pid: int, body: dict):
    name = " ".join(str(body.get("name", "")).split())
    if not name:
        raise HTTPException(400, "name required")
    with db() as c:
        if not c.execute("SELECT 1 FROM people WHERE id=?", (pid,)).fetchone():
            raise HTTPException(404)
        other = c.execute("SELECT * FROM people WHERE name=? AND id!=?", (name, pid)).fetchone()
        if other:                                            # same name as someone saved: they are one person
            me = c.execute("SELECT * FROM people WHERE id=?", (pid,)).fetchone()
            va = json.loads(me["vec_sum"]) if me["vec_sum"] else None
            vb = json.loads(other["vec_sum"]) if other["vec_sum"] else None
            vs = [a + b for a, b in zip(va, vb)] if va and vb else (va or vb)
            c.execute("UPDATE people SET vec_sum=?, weight=weight+?, is_me=MAX(is_me,?), updated_at=? WHERE id=?",
                      (json.dumps(vs) if vs else None, me["weight"], me["is_me"], int(time.time()), other["id"]))
            for r in c.execute("SELECT id, spk_json FROM sessions WHERE spk_json IS NOT NULL").fetchall():
                spk = _spk_load(r["spk_json"])
                hit = False
                for sp in spk["speakers"]:
                    if sp.get("person_id") == pid:
                        sp["person_id"] = other["id"]
                        if sp.get("contrib"):
                            sp["contrib"]["person_id"] = other["id"]
                        hit = True
                if hit:
                    c.execute("UPDATE sessions SET spk_json=? WHERE id=?", (json.dumps(spk), r["id"]))
            c.execute("DELETE FROM people WHERE id=?", (pid,))
            return {"ok": True, "merged_into": other["id"]}
        c.execute("UPDATE people SET name=?, updated_at=? WHERE id=?", (name, int(time.time()), pid))
    return {"ok": True}


@app.delete("/api/people/{pid}")
def api_person_delete(pid: int):
    """Forget a voice: the signature is deleted and their lines go back to 'Speaker N'."""
    with db() as c:
        for r in c.execute("SELECT id, spk_json FROM sessions WHERE spk_json IS NOT NULL").fetchall():
            spk = _spk_load(r["spk_json"])
            hit = False
            for sp in spk["speakers"]:
                if sp.get("person_id") == pid:
                    sp.update(person_id=None, state="none", sim=None)
                    sp.pop("contrib", None)
                    hit = True
            if hit:
                c.execute("UPDATE sessions SET spk_json=? WHERE id=?", (json.dumps(spk), r["id"]))
        c.execute("DELETE FROM people WHERE id=?", (pid,))
    return {"ok": True}


@app.get("/api/search")
def api_search(q: str = ""):
    q = q.strip()
    if len(q) < 2:
        return {"sessions": [], "tasks": []}
    like = f"%{q}%"
    ql = q.lower()
    out = []
    with db() as c:
        rows = c.execute("SELECT * FROM sessions WHERE title LIKE ? OR summary_md LIKE ? OR transcript_json LIKE ? "
                         "ORDER BY started_at DESC LIMIT 40", (like, like, like)).fetchall()
        tasks = [dict(t) for t in c.execute("SELECT * FROM tasks WHERE text LIKE ? AND status!='dismissed' "
                                            "ORDER BY status='done', created_at DESC LIMIT 20", (like,))]
    for r in rows:
        card = _session_card(r)
        hits = []
        for sg in json.loads(r["transcript_json"] or "[]"):
            if ql in sg["text"].lower():
                hits.append({"t": sg["start"], "text": sg["text"]})
                if len(hits) >= 3:
                    break
        card["hits"] = hits
        out.append(card)
    return {"sessions": out, "tasks": tasks}


def _mask(v: str) -> str:
    return ("•" * 8 + v[-4:]) if v else ""


@app.get("/api/settings")
def api_settings():
    cfg = load_config()
    cfg = dict(cfg)
    for k in ("openai_key", "anthropic_key"):
        cfg[k] = _mask(cfg.get(k, ""))
    return {"config": cfg, "ollama_models": PL.ollama_models(cfg["ollama_host"]),
            "local_models": IN.LOCAL_MODELS, "intel": IN.status(load_config()),
            "paths": {"home": str(HOME), "notes": str(NOTES_DIR), "audio": str(WAV_DIR)}}


@app.put("/api/settings")
def api_settings_put(body: dict):
    cfg = load_config()
    for k, default in DEFAULT_CONFIG.items():
        if k not in body or k == "lan_access":                # changed only via /api/phone/lan, from the Mac
            continue
        v = body[k]
        if k in ("openai_key", "anthropic_key") and (not str(v).strip() or str(v).startswith("•")):
            continue
        try:
            if isinstance(default, bool):
                cfg[k] = v if isinstance(v, bool) else str(v).lower() in ("1", "true", "on", "yes")
            elif isinstance(default, int):
                cfg[k] = int(float(v))
            else:
                cfg[k] = str(v)
        except (TypeError, ValueError):
            raise HTTPException(400, f"invalid value for {k}")
    cfg["led_brightness"] = max(0, min(100, cfg["led_brightness"]))
    cfg["mic_gain"] = max(-1, min(8, cfg["mic_gain"]))
    cfg["poll_seconds"] = max(5, cfg["poll_seconds"])
    cfg["session_gap_seconds"] = max(15, cfg["session_gap_seconds"])
    if cfg["intel_provider"] not in ("local", "ollama", "openai", "anthropic", "off"):
        raise HTTPException(400, "unknown intelligence provider")
    old = load_config()
    save_config(cfg)
    if old.get("local_model") != cfg["local_model"] or cfg["intel_provider"] != "local":
        IN.unload_local()
    S.settings_changed.set()
    S.wake.set()
    _intel_cache["at"] = 0.0
    return {"ok": True, "config": {k: (_mask(v) if k.endswith("_key") else v) for k, v in cfg.items()}}


# test hooks, only with the simulated pendant
if FAKE:
    @app.post("/api/_fake/tap")
    async def fake_tap(body: dict = None):
        return {"ok": PEND.tap(int((body or {}).get("kind", BTN_DOUBLE)))}

    @app.post("/api/_fake/presence")
    async def fake_presence(body: dict):
        PEND.fake().present = bool(body.get("present", True))
        S.wake.set()
        return {"ok": True}

    @app.post("/api/_fake/offline")
    async def fake_offline(body: dict):
        PEND.fake().add_offline(int(body.get("seconds", 20)))
        return {"ok": True}

    @app.post("/api/_fake/suggest_done")
    async def fake_suggest_done(body: dict):
        with db() as c:
            c.execute("UPDATE tasks SET suggested_done=1, done_evidence=? WHERE id=?",
                      (body.get("evidence", "I sent it this morning"), int(body["id"])))
        return {"ok": True}

    @app.post("/api/_fake/earmark")
    async def fake_earmark(body: dict):
        with db() as c:
            st = c.execute("SELECT started_at FROM sessions WHERE id=?", (int(body["session_id"]),)).fetchone()
            c.execute("INSERT INTO earmarks(at, session_id, created_at) VALUES(?,?,?)",
                      (st[0] + float(body.get("offset", 3)), int(body["session_id"]), int(time.time())))
        return {"ok": True}

    @app.get("/api/_fake/state")
    async def fake_state():
        f = PEND.fake()
        return {"led": f.led, "mic": f.mic, "clock_set": f.clock_set_at is not None, "buzzes": f.buzzes,
                "connected": f.connected, "present": f.present, "unread": f.write_seq - f.read_seq}


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")


app.mount("/static", StaticFiles(directory=STATIC), name="static")


def main():
    import socket
    import uvicorn
    for _ in range(20):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", PORT)) != 0:
                break
        time.sleep(0.25)
    else:
        print(f"Earmark is already running on port {PORT}")
        sys.exit(0)
    lan = bool(load_config().get("lan_access"))
    S.listening_lan = lan
    uvicorn.run(app, host="0.0.0.0" if lan else "127.0.0.1", port=PORT, log_level="warning",
                proxy_headers=False, forwarded_allow_ips="")


if __name__ == "__main__":
    main()
