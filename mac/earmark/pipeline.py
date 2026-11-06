"""Decode, transcribe and summarise. Everything here is local; no network except Ollama on localhost."""
from __future__ import annotations

import json
import math
import os
import time
import urllib.request
import wave
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Optional

from .pendant import iter_records

SAMPLE_RATE = 16000


def _find_libopus():
    """Return a libopus this process can actually load. Prefer the copy bundled in the PyAV
    wheel (always matches the venv's architecture); skip e.g. Intel Homebrew builds."""
    import ctypes, ctypes.util, glob, os, site
    cands = []
    for sp in site.getsitepackages():
        cands += sorted(glob.glob(os.path.join(sp, "av", ".dylibs", "libopus*.dylib")))
        cands += sorted(glob.glob(os.path.join(sp, "av.libs", "libopus*.so*")))
    cands += ["/opt/homebrew/lib/libopus.dylib", "/usr/local/lib/libopus.dylib"]
    sys_lib = ctypes.util.find_library("opus")
    if sys_lib:
        cands.append(sys_lib)
    for c in cands:
        try:
            ctypes.CDLL(c)
            return c
        except OSError:
            continue
    return None


def _patch_opus_lookup():
    import ctypes.util
    lib = _find_libopus()
    if not lib:
        return
    _orig = ctypes.util.find_library
    ctypes.util.find_library = lambda name: lib if name == "opus" else _orig(name)


_patch_opus_lookup()   # must run before anything imports opuslib


def _opus_decoder():
    import opuslib
    return opuslib.Decoder(SAMPLE_RATE, 1)


def write_wav(path: Path, pcm: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)


@dataclass
class DecodedSession:
    started_at: int          # unix seconds (from pendant RTC)
    ended_at: int
    wav_path: Path

    @property
    def duration_s(self) -> float:
        return os.path.getsize(self.wav_path) / 2 / SAMPLE_RATE


def decode_raw(raw_files: Iterable[Path], wav_dir: Path, gap_s: int = 90,
               min_seconds: float = 5.0) -> list[DecodedSession]:
    """Turn raw ring bundles into WAV sessions, splitting on gaps in the pendant timestamps."""
    import opuslib
    dec = _opus_decoder()
    out: list[DecodedSession] = []
    pcm = bytearray()
    start: Optional[int] = None
    last: Optional[int] = None

    def flush():
        nonlocal pcm, start, dec
        if start is not None and len(pcm) / 2 / SAMPLE_RATE >= min_seconds:
            name = datetime.fromtimestamp(start).strftime("%Y-%m-%d_%H-%M-%S")
            p = wav_dir / f"{name}.wav"
            if p.exists():
                p = wav_dir / f"{name}_{last}.wav"
            write_wav(p, bytes(pcm))
            out.append(DecodedSession(start, last or start, p))
        pcm, start = bytearray(), None
        dec = _opus_decoder()

    for rf in sorted(raw_files):
        for ts, frames in iter_records(rf.read_bytes()):
            if ts < 1_600_000_000:          # pre-RTC-sync garbage
                continue
            if last is not None and ts - last > gap_s:
                flush()
            if start is None:
                start = ts
            for f in frames:
                try:
                    pcm += dec.decode(f, 960)
                except opuslib.OpusError:
                    pass
            last = ts
    flush()
    return out


class LiveCapture:
    """Turns the live Opus stream into sessions, writing audio to disk as it arrives.

    Audio is appended to <wav_dir>/<start>.live.pcm (fsynced every few seconds), so a crash
    or power loss keeps everything up to that point; recover_partials() turns leftovers into
    sessions on the next start. A session closes after `gap_s` seconds without voice energy,
    or at `max_s` (default 4 h, so a long meeting stays one session). Trailing quiet beyond
    2 s is trimmed. Sessions with under `min_voiced_s` of voice are discarded. While paused,
    frames are dropped and any open session is closed."""

    QUIET_KEEP_S = 2
    FSYNC_EVERY_S = 5

    def __init__(self, wav_dir: Path, gap_s: int = 90, max_s: int = 4 * 3600, min_voiced_s: float = 2.0):
        self.wav_dir, self.gap_s, self.max_s, self.min_voiced_s = wav_dir, gap_s, max_s, min_voiced_s
        self.dec = _opus_decoder()
        self.paused = False
        self.closed: list[DecodedSession] = []
        self.noise = 300.0                   # running noise-floor estimate (int16 RMS)
        self._reset()

    def _reset(self):
        self.fh = None
        self.path: Optional[Path] = None
        self.started_at: Optional[float] = None
        self.bytes = 0
        self.sec_buf = bytearray()
        self.voiced_s = 0.0
        self.quiet_run_s = 0.0
        self.last_voice_byte = 0
        self._since_sync = 0.0

    # ---- input
    def push(self, frame: bytes, at: Optional[float] = None):
        """One Opus frame. `at` is when it was recorded (uploads from the phone arrive later);
        live frames from the pendant use the arrival time."""
        if self.paused:
            return
        try:
            pcm = self.dec.decode(frame, 960)
        except Exception:
            return
        self._write(pcm, at)

    def push_silence(self, seconds: float):
        """Keep the timeline true across a short break in an upload (no audio was recorded)."""
        if self.fh is None or seconds <= 0:
            return
        n = int(seconds * SAMPLE_RATE)
        self._write(bytes(2 * n), None)

    @property
    def end_time(self) -> Optional[float]:
        return None if self.started_at is None else self.started_at + self.bytes / 2 / SAMPLE_RATE

    def _write(self, pcm: bytes, at: Optional[float]):
        if self.fh is None:
            self.started_at = (at if at is not None else time.time() - len(pcm) / 2 / SAMPLE_RATE)
            name = datetime.fromtimestamp(self.started_at).strftime("%Y-%m-%d_%H-%M-%S")
            self.wav_dir.mkdir(parents=True, exist_ok=True)
            self.path = self.wav_dir / f"{name}.live.pcm"
            self.fh = open(self.path, "ab")
        self.fh.write(pcm)
        self.bytes += len(pcm)
        self.sec_buf += pcm
        self._since_sync += len(pcm) / 2 / SAMPLE_RATE
        if self._since_sync >= self.FSYNC_EVERY_S:
            self.fh.flush()
            os.fsync(self.fh.fileno())
            self._since_sync = 0
        while len(self.sec_buf) >= SAMPLE_RATE * 2:
            self._second(bytes(self.sec_buf[:SAMPLE_RATE * 2]))
            del self.sec_buf[:SAMPLE_RATE * 2]

    def _second(self, chunk: bytes):
        import numpy as np
        x = np.frombuffer(chunk, dtype=np.int16).astype(np.float32)
        rms = float(np.sqrt(np.mean(x * x))) if len(x) else 0.0
        voiced = rms > max(450.0, self.noise * 2.5)
        if not voiced:
            self.noise = 0.95 * self.noise + 0.05 * rms
            self.quiet_run_s += 1
        else:
            self.voiced_s += 1
            self.quiet_run_s = 0
            self.last_voice_byte = self.bytes - len(self.sec_buf) + len(chunk)
        if self.quiet_run_s >= self.gap_s or self.bytes / 2 / SAMPLE_RATE >= self.max_s:
            self._close()

    # ---- control
    def set_paused(self, paused: bool):
        if paused and not self.paused:
            self._close()
        self.paused = paused

    def finish(self):
        self._close()

    def take_closed(self) -> list[DecodedSession]:
        out, self.closed = self.closed, []
        return out

    @property
    def open_seconds(self) -> float:
        return self.bytes / 2 / SAMPLE_RATE

    def _close(self):
        if self.fh is not None:
            self.fh.flush()
            os.fsync(self.fh.fileno())
            self.fh.close()
            if self.voiced_s >= self.min_voiced_s:
                keep = min(self.bytes, self.last_voice_byte + self.QUIET_KEEP_S * SAMPLE_RATE * 2)
                s = _finalise_pcm(self.path, keep)
                if s:
                    self.closed.append(DecodedSession(int(self.started_at), int(self.started_at) + int(keep / 2 / SAMPLE_RATE), s))
            else:
                self.path.unlink(missing_ok=True)
        self._reset()


def _finalise_pcm(pcm_path: Path, keep_bytes: Optional[int] = None) -> Optional[Path]:
    """Wrap a raw .live.pcm file in a WAV header without loading it into memory."""
    size = pcm_path.stat().st_size
    keep = size if keep_bytes is None else min(size, keep_bytes)
    keep -= keep % 2
    if keep < SAMPLE_RATE * 2:
        pcm_path.unlink(missing_ok=True)
        return None
    wav_path = pcm_path.with_name(pcm_path.name.replace(".live.pcm", "_live.wav"))
    with open(pcm_path, "rb") as src, wave.open(str(wav_path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        left = keep
        while left > 0:
            buf = src.read(min(left, 4 * 1024 * 1024))
            if not buf:
                break
            w.writeframes(buf)
            left -= len(buf)
    pcm_path.unlink(missing_ok=True)
    return wav_path


def recover_partials(wav_dir: Path) -> list[DecodedSession]:
    """Sessions that were still being recorded when Earmark stopped (crash, power loss)."""
    out = []
    for p in sorted(wav_dir.glob("*.live.pcm")):
        try:
            started = datetime.strptime(p.name.split(".live.pcm")[0], "%Y-%m-%d_%H-%M-%S").timestamp()
        except ValueError:
            started = p.stat().st_mtime - p.stat().st_size / 2 / SAMPLE_RATE
        dur = p.stat().st_size / 2 / SAMPLE_RATE
        w = _finalise_pcm(p)
        if w:
            out.append(DecodedSession(int(started), int(started + dur), w))
    return out


# ---------------------------------------------------------------- transcription
_whisper_cache: dict = {}


def whisper_backend() -> str:
    """mlx-whisper (Apple GPU) when available, else faster-whisper (CPU). Both run fully offline
    after the one-time model download."""
    try:
        import mlx_whisper  # noqa: F401
        return "mlx"
    except Exception:
        return "faster"


def _load_wav_f32(wav_path: Path):
    """Read our 16 kHz mono 16-bit WAV straight into float32, so no ffmpeg is needed."""
    import numpy as np
    with wave.open(str(wav_path), "rb") as w:
        pcm = w.readframes(w.getnframes())
    return np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0


def mlx_repo(model_size: str) -> str:
    if model_size in ("large-v3-turbo", "turbo"):
        return "mlx-community/whisper-large-v3-turbo"
    return f"mlx-community/whisper-{model_size}-mlx"


def model_cached(model_size: str) -> bool:
    if whisper_backend() != "mlx":
        return True
    d = Path.home() / ".cache" / "huggingface" / "hub" / ("models--" + mlx_repo(model_size).replace("/", "--"))
    return any(d.glob("snapshots/*/weights.*")) if d.exists() else False


def _speech_chunks(audio):
    """Silero VAD (bundled with faster-whisper, runs locally). Returns sample ranges of speech."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps
    return get_speech_timestamps(audio, VadOptions(threshold=0.5, min_silence_duration_ms=1000,
                                                   speech_pad_ms=300, min_speech_duration_ms=250))


def speech_stats(wav_path: Path) -> tuple[float, float]:
    """(total seconds of speech, longest continuous speech in seconds), using Silero VAD.
    Silero is trained to separate speech from other sounds, so clinks, coughs, typing and
    room noise score near zero. Reads the file in blocks, so length doesn't matter."""
    total, longest = 0.0, 0.0
    for _, audio in _wav_blocks(wav_path):
        for c in _speech_chunks(audio):
            d = (c["end"] - c["start"]) / SAMPLE_RATE
            total += d
            longest = max(longest, d)
    return total, longest


def has_speech(wav_path: Path, min_total_s: float = 3.0, min_run_s: float = 1.0) -> bool:
    if os.environ.get("EARMARK_FAKE_TRANSCRIBE") == "1":
        with wave.open(str(wav_path), "rb") as w:
            return w.getnframes() / SAMPLE_RATE >= min_total_s
    total, longest = speech_stats(wav_path)
    return total >= min_total_s and longest >= min_run_s


def _looks_like_loop(text: str) -> bool:
    import re, zlib
    t = text.strip()
    if not t:
        return True
    words = re.findall(r"\w+", t.lower())
    if len(words) >= 8 and len(set(words)) / len(words) < 0.25:
        return True                                   # "ya, ya, ya, ya ..."
    b = t.encode()
    return len(b) > 60 and len(b) / max(1, len(zlib.compress(b))) > 2.4


def _clean(segs: list) -> list:
    """Drop looping segments and runs of the same sentence repeated back to back."""
    out, seen_recent = [], []
    for s in segs:
        if _looks_like_loop(s["text"]):
            continue
        key = s["text"].lower().strip(" .,!?")
        if key in seen_recent:
            continue
        seen_recent = (seen_recent + [key])[-3:]
        out.append(s)
    return out


PARAKEET_MODELS = {
    "parakeet-v2": "mlx-community/parakeet-tdt-0.6b-v2",   # English only, most accurate for English
    "parakeet-v3": "mlx-community/parakeet-tdt-0.6b-v3",   # 25 European languages
}
_parakeet_cache: dict = {}


def parakeet_available() -> bool:
    try:
        import parakeet_mlx  # noqa: F401
        return True
    except Exception:
        return False


def ensure_parakeet() -> None:
    """Install parakeet-mlx into this venv on first use (native arm64, ~1 min)."""
    if parakeet_available():
        return
    import subprocess, sys, importlib
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "parakeet-mlx"], check=True)
    importlib.invalidate_caches()


def _hf_cached(repo: str, filename_glob: str) -> bool:
    d = Path.home() / ".cache" / "huggingface" / "hub" / ("models--" + repo.replace("/", "--"))
    return d.exists() and any(d.glob(f"snapshots/*/{filename_glob}"))


HF_HUB = Path(os.environ.get("HF_HUB_CACHE", Path.home() / ".cache" / "huggingface" / "hub"))


def _repo_dir(repo: str) -> Path:
    return HF_HUB / ("models--" + repo.replace("/", "--"))


def engine_repo(engine: str) -> Optional[str]:
    if engine == "auto" or engine.startswith("parakeet"):
        return PARAKEET_MODELS.get(engine, PARAKEET_MODELS["parakeet-v2"])
    return None


def repo_total_bytes(repo: str) -> Optional[int]:
    """Size of the model's weights, from the Hub (one small request)."""
    try:
        from huggingface_hub import HfApi
        info = HfApi().model_info(repo, files_metadata=True)
        return sum((f.size or 0) for f in info.siblings if f.rfilename.endswith((".safetensors", ".npz", ".bin")))
    except Exception:
        return None


def download_progress(repo: str) -> int:
    """Bytes of the model currently on disk (finished + in-progress files)."""
    blobs = _repo_dir(repo) / "blobs"
    if not blobs.exists():
        return 0
    fresh = [p for p in blobs.iterdir() if not p.name.endswith(".incomplete")]
    partial = [p for p in blobs.glob("*.incomplete") if time.time() - p.stat().st_mtime < 600]
    done = sum(p.stat().st_size for p in fresh)
    return done + max((p.stat().st_size for p in partial), default=0)


def remove_abandoned_downloads(max_age_s: int = 900) -> int:
    """Partial downloads left by an earlier, interrupted run are never resumed; delete them."""
    freed = 0
    for repo in list(PARAKEET_MODELS.values()):
        blobs = _repo_dir(repo) / "blobs"
        if not blobs.exists():
            continue
        for p in blobs.glob("*.incomplete"):
            try:
                if time.time() - p.stat().st_mtime > max_age_s:
                    freed += p.stat().st_size
                    p.unlink()
            except OSError:
                pass
    return freed


def engine_ready(engine: str, model_size: str) -> bool:
    """False when the next transcription will first download or install something."""
    if engine == "auto" or engine.startswith("parakeet"):
        return parakeet_available() and _hf_cached(PARAKEET_MODELS.get(engine, PARAKEET_MODELS["parakeet-v2"]),
                                                    "model.safetensors")
    return model_cached(model_size)


_ABBREV = {"mr.", "mrs.", "ms.", "dr.", "st.", "prof.", "sr.", "jr.", "vs.", "etc.", "inc.", "ltd.", "co.", "no.", "e.g.", "i.e."}


def _merge_fragments(raw: list) -> list:
    """Parakeet ends sentences at abbreviations ("Mr." | "Quilter is ..."); join those back.
    Items are (start, end, text) or (start, end, text, words)."""
    out = []
    for item in raw:
        st, en, tx = item[0], item[1], item[2]
        words = item[3] if len(item) > 3 else None
        if out and out[-1][2].strip().split()[-1:] and out[-1][2].strip().split()[-1].lower() in _ABBREV \
                and st - out[-1][1] < 2.0:
            pst, _, ptx, pw = out[-1]
            out[-1] = (pst, en, ptx.strip() + " " + tx.strip(), (pw + words) if pw is not None and words is not None else None)
        else:
            out.append((st, en, tx, words))
    return out


def _token_words(tokens) -> Optional[list]:
    """Parakeet sub-word tokens -> [(start, end, word)]; a token starting with a space begins a word."""
    try:
        words = []
        for t in tokens:
            txt = t.text
            if not words or txt.startswith(" "):
                words.append([float(t.start), float(t.end), txt.strip()])
            else:
                words[-1][1] = float(t.end)
                words[-1][2] += txt
        return [tuple(w) for w in words if w[2]]
    except Exception:
        return None


def _parakeet_segments(audio, engine: str, progress=None) -> list:
    """Run Parakeet on a float32 16 kHz array. Returns [(start, end, text)] per sentence."""
    import tempfile, os
    import mlx.core as mx
    import parakeet_mlx.parakeet as pk
    from parakeet_mlx import from_pretrained

    def _load(filename, sampling_rate, dtype=mx.bfloat16):       # replaces ffmpeg decoding
        return mx.array(_load_wav_f32(Path(filename))).astype(dtype)
    pk.load_audio = _load

    repo = PARAKEET_MODELS.get(engine, PARAKEET_MODELS["parakeet-v2"])
    limit_mlx_cache()
    if repo not in _parakeet_cache:
        _parakeet_cache.clear()
        _parakeet_cache[repo] = from_pretrained(repo)
    model = _parakeet_cache[repo]

    fd, tmp = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    try:
        import numpy as np
        write_wav(Path(tmp), (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
        cb = (lambda cur, tot: progress(min(1.0, cur / max(1, tot)))) if progress else None
        r = model.transcribe(tmp, dtype=mx.float32, chunk_duration=120.0, overlap_duration=15.0,
                             chunk_callback=cb)
    finally:
        os.unlink(tmp)
    return _merge_fragments([(s.start, s.end, s.text, _token_words(getattr(s, "tokens", []) or []))
                             for s in r.sentences])


LANG_NAMES = {"de": "German", "zh": "Chinese", "hi": "Hindi", "mr": "Marathi", "ar": "Arabic", "fr": "French",
              "es": "Spanish", "it": "Italian", "ru": "Russian", "ja": "Japanese", "ko": "Korean", "ur": "Urdu",
              "pt": "Portuguese", "nl": "Dutch", "tr": "Turkish", "fa": "Persian", "ta": "Tamil", "te": "Telugu",
              "bn": "Bengali", "gu": "Gujarati", "ml": "Malayalam", "kn": "Kannada", "pa": "Punjabi", "en": "English"}
_detector_cache: dict = {}


def free_memory():
    """Give memory back to macOS: Python garbage plus MLX's buffer cache on the GPU."""
    import gc
    gc.collect()
    try:
        import mlx.core as mx
        clear = getattr(mx, "clear_cache", None) or getattr(getattr(mx, "metal", None), "clear_cache", None)
        if clear:
            clear()
    except Exception:
        pass


def limit_mlx_cache(mb: int = 256):
    """MLX keeps freed GPU buffers for reuse; without a cap that cache grows to many GB."""
    try:
        import mlx.core as mx
        setter = getattr(mx, "set_cache_limit", None) or getattr(getattr(mx, "metal", None), "set_cache_limit", None)
        if setter:
            setter(mb * 1024 * 1024)
    except Exception:
        pass


def unload_models():
    """Drop every speech model (Parakeet, Whisper, language detector) until it is needed again."""
    _parakeet_cache.clear()
    _whisper_cache.clear()
    _detector_cache.clear()
    try:
        from mlx_whisper.transcribe import ModelHolder
        ModelHolder.model = None
        ModelHolder.model_path = None
    except Exception:
        pass
    free_memory()


def _detect(window, model_size: str = "base"):
    """Language of a speech window via faster-whisper's detector (CPU, int8, fast)."""
    from faster_whisper import WhisperModel
    if model_size not in _detector_cache:
        _detector_cache.clear()
        _detector_cache[model_size] = WhisperModel(model_size, device="cpu", compute_type="int8")
    lang, prob, _ = _detector_cache[model_size].detect_language(audio=window)
    return lang, prob


def other_language(wav_path: Path, detector: str = "base", min_prob: float = 0.6) -> Optional[str]:
    """The first non-English language confidently heard in a recording, or None if it is all English.
    The iPhone transcribes English only; recordings in other languages are transcribed (and translated)
    by the Mac instead."""
    import numpy as np
    if os.environ.get("EARMARK_FAKE_TRANSCRIBE") == "1":       # end-to-end tests only
        return os.environ.get("EARMARK_FAKE_LANGUAGE") or None
    for _off, audio in _wav_blocks(wav_path):
        chunks = _speech_chunks(audio)
        for w in _windows(chunks):
            win = np.concatenate([audio[c["start"]:c["end"]] for c in w])
            if len(win) < 2 * SAMPLE_RATE:
                continue
            lang, prob = _detect(win[:30 * SAMPLE_RATE], detector)
            if lang != "en" and prob >= min_prob:
                return lang
    return None


def _windows(chunks: list, max_s: float = 30.0, max_gap_s: float = 3.0) -> list:
    """Group VAD chunks into windows of nearby speech, up to max_s of speech each."""
    out, cur, cur_len = [], [], 0
    for c in chunks:
        n = c["end"] - c["start"]
        if cur and (cur_len + n > max_s * SAMPLE_RATE or c["start"] - cur[-1]["end"] > max_gap_s * SAMPLE_RATE):
            out.append(cur)
            cur, cur_len = [], 0
        cur.append(c)
        cur_len += n
    if cur:
        out.append(cur)
    return out


def _whisper_segments(speech, model_size: str, language: Optional[str], task: str = "transcribe"):
    """Whisper on a float32 array -> ([(start, end, text)], detected_language)."""
    if whisper_backend() == "mlx":
        import mlx_whisper
        repo = mlx_repo(model_size)
        r = mlx_whisper.transcribe(speech, path_or_hf_repo=repo, language=language or None, task=task,
                                   fp16=True, condition_on_previous_text=False,
                                   word_timestamps=True, hallucination_silence_threshold=2.0)
        return [(x["start"], x["end"], x["text"],
                 [(w["start"], w["end"], w["word"].strip()) for w in x.get("words") or [] if w.get("word", "").strip()] or None)
                for x in r.get("segments", [])], r.get("language", language or "?")
    from faster_whisper import WhisperModel
    key = model_size
    if key not in _whisper_cache:
        _whisper_cache.clear()
        _whisper_cache[key] = WhisperModel(model_size, device="auto", compute_type="auto")
    segments, info = _whisper_cache[key].transcribe(speech, language=language or None, task=task,
                                                    beam_size=5, condition_on_previous_text=False,
                                                    word_timestamps=True)
    return [(x.start, x.end, x.text, [(w.start, w.end, w.word.strip()) for w in (x.words or []) if w.word.strip()] or None)
            for x in segments], info.language


BLOCK_S = 20 * 60          # long recordings are processed in 20-minute blocks to bound memory


def _wav_blocks(wav_path: Path, block_s: int = BLOCK_S):
    """Yield (offset_seconds, float32 array) blocks without loading the whole file."""
    import numpy as np
    with wave.open(str(wav_path), "rb") as w:
        n, off = w.getnframes(), 0
        while off < n:
            pcm = w.readframes(min(block_s * SAMPLE_RATE, n - off))
            yield off / SAMPLE_RATE, np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
            off += len(pcm) // 2


def transcribe(wav_path: Path, model_size: str = "small", language: Optional[str] = None,
               engine: str = "auto", translate: bool = True, translate_model: str = "large-v3",
               detector: str = "base", progress=None) -> dict:
    """engine: auto      English -> Parakeet, other languages -> Whisper (translated to English
                         when `translate`), decided per stretch of speech
               parakeet-v2 / parakeet-v3 / whisper   force one engine for the whole session
    Recordings longer than 20 minutes are processed block by block."""
    if os.environ.get("EARMARK_FAKE_TRANSCRIBE") == "1":       # end-to-end tests only
        return _fake_transcript(wav_path)
    with wave.open(str(wav_path), "rb") as w:
        total_s = w.getnframes() / SAMPLE_RATE
    nblocks = max(1, math.ceil(total_s / BLOCK_S))
    segs, langs = [], []
    for bi, (offset, audio) in enumerate(_wav_blocks(wav_path)):
        def prog(frac, lang=None, _bi=bi):
            if progress:
                progress((_bi + max(0.0, min(1.0, frac))) / nblocks, lang)
        prog(0.0)
        bsegs, blangs = _transcribe_audio(audio, model_size, language, engine, translate,
                                          translate_model, detector, prog)
        for x in bsegs:
            x["start"] = round(x["start"] + offset, 2)
            x["end"] = round(x["end"] + offset, 2)
            for w in x.get("words") or []:
                w[0], w[1] = round(w[0] + offset, 2), round(w[1] + offset, 2)
        segs += bsegs
        langs += [l for l in blangs if l not in langs]
    segs = _clean(segs)
    uniq = [l for i, l in enumerate(langs) if l and l not in langs[:i]]
    if progress:
        progress(1.0, None)
    return {"language": ", ".join(uniq) or ("en" if segs else ""), "languages": uniq, "segments": segs,
            "text": "\n".join(s["text"] for s in segs)}


def _fake_transcript(wav_path: Path) -> dict:
    with wave.open(str(wav_path), "rb") as w:
        dur = w.getnframes() / SAMPLE_RATE
    if dur < 1:
        return {"language": "", "languages": [], "segments": [], "text": ""}
    segs = [{"start": 0.0, "end": 3.0, "text": "Let's review the launch plan for the pilot."},
            {"start": 4.0, "end": 7.0, "text": "Rahul will send the vendor contract by Thursday."},
            {"start": 8.0, "end": 11.0, "text": "We agreed to keep the budget at the current level.", "from": "de"}]
    segs = [x for x in segs if x["start"] < max(dur, 1)]
    for x in segs:
        if x.get("from"):
            continue
        ws = x["text"].split()
        step = (x["end"] - x["start"]) / len(ws)
        x["words"] = [[round(x["start"] + i * step, 2), round(x["start"] + (i + 1) * step, 2), w] for i, w in enumerate(ws)]
    return {"language": "en, de", "languages": ["en", "de"], "segments": segs,
            "text": "\n".join(x["text"] for x in segs)}


def _transcribe_audio(audio, model_size, language, engine, translate, translate_model, detector, progress):
    import numpy as np
    from faster_whisper.vad import SpeechTimestampsMap
    chunks = _speech_chunks(audio)
    if not chunks:
        return [], []

    # decide a route for each window of speech
    if engine == "auto":
        routed = []
        for w in _windows(chunks):
            win = np.concatenate([audio[c["start"]:c["end"]] for c in w])
            lang, prob = ("en", 1.0) if len(win) < 2 * SAMPLE_RATE else _detect(win[:30 * SAMPLE_RATE], detector)
            if lang != "en" and prob < 0.6:
                lang = "en"                               # not confident: treat as English
            routed.append((lang, w))
        groups = []                                       # merge neighbours with the same language
        for lang, w in routed:
            if groups and groups[-1][0] == lang:
                groups[-1][1].extend(w)
            else:
                groups.append((lang, list(w)))
    else:
        groups = [(None, list(chunks))]

    if progress:
        progress(0.08)                                    # speech detection done
    sizes = [sum(c["end"] - c["start"] for c in g) for _, g in groups]
    total = max(1, sum(sizes))
    done = 0

    def gprog(f, lang, _done=None, _size=None):
        if progress:
            progress(0.08 + 0.92 * (_done + f * _size) / total, lang)

    segs, langs = [], []
    for gi, (lang, group) in enumerate(groups):
        size = sizes[gi]
        gp = (lambda f, _l=lang, _d=done, _s=size: gprog(f, _l, _d, _s))
        gp(0.0)
        speech = np.concatenate([audio[c["start"]:c["end"]] for c in group])
        tmap = SpeechTimestampsMap(group, SAMPLE_RATE)
        src_lang = lang
        if engine == "auto" and lang == "en" or engine.startswith("parakeet"):
            ensure_parakeet()
            raw = _parakeet_segments(speech, "parakeet-v3" if engine == "parakeet-v3" else "parakeet-v2", gp)
            src_lang = src_lang or ("en" if engine != "parakeet-v3" else (language or "auto"))
        elif engine == "auto":
            task = "translate" if translate else "transcribe"
            raw, _ = _whisper_segments(speech, translate_model, lang, task)
        else:                                             # engine == "whisper"
            raw, src_lang = _whisper_segments(speech, model_size, language, "transcribe")
        done += size
        gp(1.0)
        langs.append(src_lang)
        translated = engine == "auto" and translate and src_lang not in (None, "en")
        for item in raw:
            st, en, tx = item[0], item[1], item[2].strip()
            words = item[3] if len(item) > 3 else None
            if tx:
                seg = {"start": round(tmap.get_original_time(st), 2),
                       "end": round(tmap.get_original_time(en, is_end=True), 2), "text": tx}
                if words and not translated:             # translated text has no timing per word
                    seg["words"] = [[round(tmap.get_original_time(a), 2), round(tmap.get_original_time(b, is_end=True), 2), w]
                                    for a, b, w in words]
                if translated:
                    seg["from"] = src_lang
                segs.append(seg)
    segs.sort(key=lambda x: x["start"])
    return segs, langs


# ---------------------------------------------------------------- summary (Ollama)
SUMMARY_PROMPT = """You are turning a raw transcript from a wearable voice recorder into tidy personal notes.
Write in plain markdown with these sections, omitting any that have nothing:
## Summary  (2-4 sentences)
## Key points  (bullets)
## Decisions
## Action items  (bullets, who/what if stated)
## People and names mentioned
Do not invent anything that is not in the transcript. Be concise.

Transcript:
"""


def ollama_models(host: str) -> list[str]:
    try:
        with urllib.request.urlopen(f"{host}/api/tags", timeout=3) as r:
            return [m["name"] for m in json.load(r).get("models", [])]
    except Exception:
        return []


PART_PROMPT = """Below is one part ({i} of {n}) of a long transcript from a wearable voice recorder.
Write compact bullet notes for this part only: topics discussed, decisions, action items (who/what),
names, numbers and dates. Do not invent anything. Transcript part:
"""

MERGE_PROMPT = """Below are notes from consecutive parts of one long recording. Merge them into one set of
notes in plain markdown with these sections, omitting any that have nothing:
## Summary  (3-6 sentences covering the whole recording)
## Key points  (bullets)
## Decisions
## Action items  (bullets, who/what if stated)
## People and names mentioned
Remove duplicates. Do not invent anything. Part notes:
"""

SINGLE_LIMIT = 20000       # characters of transcript summarised in one pass (~25 min of speech)
PART_CHARS = 14000


def _ollama(host: str, model: str, prompt: str, timeout: int = 900) -> Optional[str]:
    body = json.dumps({"model": model, "prompt": prompt, "stream": False,
                       "options": {"temperature": 0.2, "num_ctx": 16384}}).encode()
    req = urllib.request.Request(f"{host}/api/generate", data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r).get("response", "").strip() or None
    except Exception:
        return None


def _split_text(text: str, size: int) -> list[str]:
    parts, cur = [], []
    n = 0
    for line in text.splitlines():
        if cur and n + len(line) > size:
            parts.append("\n".join(cur))
            cur, n = [], 0
        cur.append(line)
        n += len(line) + 1
    if cur:
        parts.append("\n".join(cur))
    return parts


def summarise(text: str, host: str, model: str, progress=None) -> Optional[str]:
    """Notes for a transcript of any length: one pass when short; for long recordings
    (meetings), notes per part and then a merge into one set of notes."""
    if not text.strip() or not model:
        return None
    if len(text) <= SINGLE_LIMIT:
        return _ollama(host, model, SUMMARY_PROMPT + text)
    parts = _split_text(text, PART_CHARS)
    notes = []
    for i, part in enumerate(parts, 1):
        if progress:
            progress(i, len(parts))
        r = _ollama(host, model, PART_PROMPT.format(i=i, n=len(parts)) + part)
        if r:
            notes.append(f"### Part {i} of {len(parts)}\n{r}")
    if not notes:
        return None
    if progress:
        progress(len(parts) + 1, len(parts))
    merged = _ollama(host, model, MERGE_PROMPT + "\n\n".join(notes))
    return merged or "\n\n".join(notes)


def write_note(notes_dir: Path, title: str, started_at: int, duration_s: float,
               summary: Optional[str], transcript: dict) -> Path:
    notes_dir.mkdir(parents=True, exist_ok=True)
    when = datetime.fromtimestamp(started_at)
    p = notes_dir / f"{when.strftime('%Y-%m-%d_%H-%M-%S')}.md"
    lines = [f"# {title}", f"{when.strftime('%A %d %B %Y, %H:%M')} · {int(duration_s // 60)} min",
             f"language: {transcript.get('language', '?')}", ""]
    if summary:
        lines += [summary, "", "---", ""]
    lines.append("## Transcript")
    for s in transcript.get("segments", []):
        m, sec = divmod(int(s["start"]), 60)
        lines.append(f"[{m:02d}:{sec:02d}] {s['text']}")
    p.write_text("\n".join(lines) + "\n")
    return p
