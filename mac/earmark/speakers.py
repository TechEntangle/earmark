"""Who spoke when, and who they are.

1. Every transcript line already has start/end times. Each line long enough to carry a voice
   (>= 1.2 s) gets a voice signature from NVIDIA TitaNet-small (192 numbers, runs on the CPU
   through sherpa-onnx, 40 MB, downloaded once).
2. Lines are grouped by average-linkage clustering on cosine distance: one group per speaker.
   Short lines ("Yes.", "Agreed.") join the closest group, or the previous speaker's.
3. Each group is compared with the voices you have named before. A close match is labelled
   automatically; a near match is offered as a suggestion; anything else stays "Speaker N".

Tested on mixed-level, room-smeared multi-speaker audio: 97-100% of speech time assigned to the
right speaker, and named voices recognised in a different recording (same voice ~0.76-0.94
similarity, different voices <= 0.72).

EARMARK_FAKE_SPEAKERS=1 (or EARMARK_FAKE_TRANSCRIBE=1) uses a deterministic stand-in for tests.
"""
from __future__ import annotations

import os
import threading
import urllib.request
from pathlib import Path
from typing import Callable, Optional

import numpy as np

MODEL_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx"
MODEL_NAME = "nemo_en_titanet_small.onnx"
MODEL_BYTES = 40_257_283
SR = 16000

MIN_VOICE_S = 1.5           # shorter lines are too short to identify on their own
CLUSTER_DIST = 0.7          # cosine distance at which two groups stop being merged
SMALL_GROUP_S = 4.0         # groups with less speech than this are folded into a neighbour when close
AUTO_SIM = 0.80             # this close to a saved voice: label automatically
SUGGEST_SIM = 0.70          # this close: suggest, ask to confirm

SEG_URL = ("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/"
           "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")
SEG_NAME = "pyannote-segmentation-3.0.onnx"
SEG_WIN = 160000            # 10 s windows
SEG_HOP = 80000             # 5 s hop: the middle 5 s of each window tiles the recording
SEG_SHIFT = 270             # samples per output frame
MIN_TURN_S = 0.3            # ignore voice "changes" shorter than this
MIN_PIECE_S = 0.35          # never split a line into a piece shorter than this

_lock = threading.Lock()
_seg_session = None
_extractor = None


def fake() -> bool:
    return os.environ.get("EARMARK_FAKE_SPEAKERS") == "1" or os.environ.get("EARMARK_FAKE_TRANSCRIBE") == "1"


# ---------------------------------------------------------------- runtime + model
def runtime_ready() -> bool:
    try:
        import sherpa_onnx  # noqa: F401
        return True
    except Exception:
        return False


def ensure_runtime():
    if fake() or runtime_ready():
        return
    import importlib, subprocess, sys
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "sherpa-onnx>=1.10"], check=True)
    importlib.invalidate_caches()


def model_path(models_dir: Path) -> Path:
    return models_dir / MODEL_NAME


def model_ready(models_dir: Path) -> bool:
    p = model_path(models_dir)
    return fake() or (p.exists() and p.stat().st_size >= MODEL_BYTES * 0.98 and (models_dir / SEG_NAME).exists())


def ensure_model(models_dir: Path, progress: Optional[Callable[[int, int], None]] = None) -> Path:
    p = model_path(models_dir)
    if model_ready(models_dir):
        return p
    models_dir.mkdir(parents=True, exist_ok=True)
    if not (models_dir / SEG_NAME).exists():
        _download_seg(models_dir)
    if p.exists() and p.stat().st_size >= MODEL_BYTES * 0.98:
        return p
    tmp = p.with_suffix(".part")
    with urllib.request.urlopen(MODEL_URL, timeout=60, context=_ssl_context()) as r, open(tmp, "wb") as f:
        total, have = int(r.headers.get("Content-Length") or MODEL_BYTES), 0
        while True:
            b = r.read(1 << 16)
            if not b:
                break
            f.write(b)
            have += len(b)
            if progress:
                progress(have, total)
    tmp.replace(p)
    return p


def _download_seg(models_dir: Path):
    """pyannote segmentation-3.0 (MIT, 6 MB): finds the moments the voice changes."""
    import io, tarfile
    with urllib.request.urlopen(SEG_URL, timeout=60, context=_ssl_context()) as r:
        data = r.read()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:bz2") as tf:
        m = next(x for x in tf.getmembers() if x.name.endswith("/model.onnx"))
        out = tf.extractfile(m).read()
    tmp = models_dir / (SEG_NAME + ".part")
    tmp.write_bytes(out)
    tmp.replace(models_dir / SEG_NAME)


def _ssl_context():
    """python.org's macOS Python ships without CA certificates; use certifi's bundle (installed with
    huggingface_hub/requests) so downloads verify properly instead of failing."""
    import ssl
    for env in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"):          # an explicitly configured bundle wins
        f = os.environ.get(env)
        if f and os.path.exists(f):
            return ssl.create_default_context(cafile=f)
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def unload():
    """Drop the voice models until the next conversation needs them."""
    global _extractor, _seg_session
    with _lock:
        _extractor = None
        _seg_session = None
    import gc
    gc.collect()


def _get_extractor(models_dir: Path):
    global _extractor
    if _extractor is None:
        import sherpa_onnx as so
        cfg = so.SpeakerEmbeddingExtractorConfig(model=str(model_path(models_dir)), num_threads=max(1, min(4, os.cpu_count() or 2)))
        _extractor = so.SpeakerEmbeddingExtractor(cfg)
    return _extractor


def _norm(v) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32)
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def embed(models_dir: Path, audio: np.ndarray) -> np.ndarray:
    with _lock:
        ex = _get_extractor(models_dir)
        s = ex.create_stream()
        s.accept_waveform(SR, audio)
        s.input_finished()
        return _norm(ex.compute(s))


def _load(wav: Path) -> np.ndarray:
    import wave
    with wave.open(str(wav), "rb") as w:
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    return x


# ---------------------------------------------------------------- where the voice changes
def _seg_model(models_dir: Path):
    global _seg_session
    if _seg_session is None:
        import onnxruntime as ort
        so = ort.SessionOptions()
        so.intra_op_num_threads = max(1, min(4, os.cpu_count() or 2))
        _seg_session = ort.InferenceSession(str(models_dir / SEG_NAME), so, providers=["CPUExecutionProvider"])
    return _seg_session


# powerset classes of segmentation-3.0: none, A, B, C, A+B, A+C, B+C
_POWERSET = [(), (0,), (1,), (2,), (0, 1), (0, 2), (1, 2)]


def change_points(models_dir: Path, audio: np.ndarray, spans: Optional[list] = None,
                  progress: Optional[Callable[[float], None]] = None) -> list:
    """Times (s) where one voice hands over to another, from 10 s windows every 5 s.
    Within a window the model keeps up to three voices apart; each frame's main voice is the one
    speaking (the earlier one when two overlap). Only the middle 5 s of each window is used, so
    every moment is judged with context on both sides. spans limits work to where there is speech."""
    sess = _seg_model(models_dir)
    name = sess.get_inputs()[0].name
    n = len(audio)
    starts = list(range(0, max(1, n - SEG_WIN) + 1, SEG_HOP))
    if starts[-1] + SEG_WIN < n:
        starts.append(n - SEG_WIN if n > SEG_WIN else 0)
    if spans:
        keep = []
        for st in starts:
            a, b = st / SR, (st + SEG_WIN) / SR
            if any(x < b and y > a for x, y in spans):
                keep.append(st)
        starts = keep or starts[:1]
    out = []
    for k, st in enumerate(starts):
        x = audio[st:st + SEG_WIN]
        if len(x) < SEG_WIN:
            x = np.pad(x, (0, SEG_WIN - len(x)))
        with _lock:
            y = sess.run(None, {name: x[None, None, :].astype(np.float32)})[0][0]
        cls = y.argmax(-1)
        frames = len(cls)
        lo = 0 if st == 0 else int(2.5 * SR / SEG_SHIFT)
        hi = frames if st + SEG_WIN >= n else int(7.5 * SR / SEG_SHIFT)
        main = []
        prev = None
        for f in range(frames):
            act = _POWERSET[int(cls[f])]
            if not act:
                main.append(None)
                continue
            cur = prev if prev in act else act[0]
            main.append(cur)
            prev = cur
        # runs of the same main voice (silence inside a voice's run does not break it)
        runs, cur, beg = [], None, 0
        for f, v in enumerate(main):
            if v is None:
                continue
            if v != cur:
                if cur is not None:
                    runs.append([cur, beg, last])
                cur, beg = v, f
            last = f
        if cur is not None:
            runs.append([cur, beg, last])
        min_f = int(MIN_TURN_S * SR / SEG_SHIFT)
        runs = [r for r in runs if r[2] - r[1] >= min_f] if len(runs) > 1 else runs
        merged = []
        for r in runs:
            if merged and merged[-1][0] == r[0]:
                merged[-1][2] = r[2]
            else:
                merged.append(r)
        for a_, b_ in zip(merged, merged[1:]):
            f = (a_[2] + b_[1]) / 2                     # middle of the hand-over
            if lo <= f < hi:
                out.append((st + f * SEG_SHIFT + 495) / SR)   # + half the receptive field
        if progress and k % 10 == 0:
            progress(k / max(1, len(starts)))
    out.sort()
    dedup = []
    for t in out:
        if not dedup or t - dedup[-1] > MIN_TURN_S:
            dedup.append(t)
    return dedup


def split_at_changes(segments: list, cps: list) -> list:
    """Cut lines where the voice changes, at the gap between words nearest the change."""
    out = []
    for s in segments:
        words = s.get("words") or []
        inside = [t for t in cps if s["start"] + MIN_PIECE_S < t < s["end"] - MIN_PIECE_S]
        if not inside or len(words) < 2:
            out.append(s)
            continue
        cuts = []
        for t in inside:
            best, bd = None, 9e9
            for i in range(1, len(words)):
                gap_mid = (words[i - 1][1] + words[i][0]) / 2
                d = abs(gap_mid - t)
                if d < bd:
                    best, bd = i, d
            if best is not None and bd <= 0.8 and best not in cuts:
                cuts.append(best)
        cuts.sort()
        pieces, prev = [], 0
        for c in cuts + [len(words)]:
            ws = words[prev:c]
            if ws:
                pieces.append(ws)
            prev = c
        # fold pieces that are too short into a neighbour
        i = 0
        while len(pieces) > 1 and i < len(pieces):
            p = pieces[i]
            if p[-1][1] - p[0][0] < MIN_PIECE_S:
                j = i - 1 if i > 0 else i + 1
                pieces[j] = (pieces[j] + p) if j < i else (p + pieces[j])
                pieces.pop(i)
                i = 0
                continue
            i += 1
        if len(pieces) == 1:
            out.append(s)
            continue
        for ws in pieces:
            piece = {k: v for k, v in s.items() if k not in ("words", "start", "end", "text", "spk", "spk_manual")}
            piece.update(start=ws[0][0], end=ws[-1][1], text=" ".join(w[2] for w in ws), words=ws)
            out.append(piece)
    return out


# ---------------------------------------------------------------- clustering
def _average_linkage(E: np.ndarray, max_dist: float) -> np.ndarray:
    """Average-linkage agglomerative clustering on cosine distance, numpy only."""
    n = len(E)
    if n <= 1:
        return np.zeros(n, int)
    sim = E @ E.T
    np.fill_diagonal(sim, -np.inf)
    size = np.ones(n)
    alive = np.ones(n, bool)
    members = {i: [i] for i in range(n)}
    min_sim = 1.0 - max_dist
    while True:
        k = int(np.argmax(sim))
        a, b = divmod(k, n)
        if sim[a, b] < min_sim or not np.isfinite(sim[a, b]):
            break
        # merge b into a (Lance-Williams update for average linkage)
        sa, sb = size[a], size[b]
        sim[a, :] = (sa * sim[a, :] + sb * sim[b, :]) / (sa + sb)
        sim[:, a] = sim[a, :]
        sim[a, a] = -np.inf
        sim[b, :] = -np.inf
        sim[:, b] = -np.inf
        size[a] += sb
        alive[b] = False
        members[a] += members.pop(b)
    lab = np.zeros(n, int)
    for c, (_, idx) in enumerate(sorted(members.items(), key=lambda kv: min(kv[1]))):
        lab[idx] = c
    return lab


def analyse(models_dir: Path, wav: Path, segments: list, people: list,
            progress: Optional[Callable[[float], None]] = None) -> dict:
    """Label every segment with a speaker and match speakers to saved voices.

    people: [{"id", "name", "vec": [...] (normalised centroid), "is_me"}]
    Returns {"labels": [label per segment], "speakers": [{label, seconds, vec, rms, sample, person_id, sim, state}]}.
    """
    if fake():
        return _fake_analyse(segments, people)
    audio = _load(wav)
    if any(s.get("words") for s in segments) and (models_dir / SEG_NAME).exists():
        spans = [(s["start"], s["end"]) for s in segments]
        cps = change_points(models_dir, audio, spans, (lambda f: progress(0.3 * f)) if progress else None)
        segments = split_at_changes(segments, cps)
    n = len(segments)
    vecs: list = [None] * n
    rms = np.zeros(n)
    dur = np.array([max(0.0, float(s.get("end", 0)) - float(s.get("start", 0))) for s in segments])
    for i, s in enumerate(segments):
        a, b = int(float(s.get("start", 0)) * SR), int(float(s.get("end", 0)) * SR)
        clip = audio[a:b]
        if len(clip):
            rms[i] = float(np.sqrt(np.mean(clip ** 2)))
        if dur[i] >= 0.5:
            if len(clip) > 30 * SR:
                mid = len(clip) // 2
                clip = clip[mid - 15 * SR: mid + 15 * SR]
            vecs[i] = embed(models_dir, clip)
        if progress and i % 20 == 0:
            progress(0.3 + 0.6 * i / max(1, n))
    shorts = {i: vecs[i] for i in range(n) if vecs[i] is not None and dur[i] < MIN_VOICE_S}
    for i in shorts:
        vecs[i] = None
    longs = [i for i in range(n) if vecs[i] is not None]
    labels = [-1] * n
    if longs:
        E = np.stack([vecs[i] for i in longs])
        lab = _average_linkage(E, CLUSTER_DIST)
        for i, c in zip(longs, lab):
            labels[i] = int(c)
    groups = _centroids(labels, vecs, dur)

    # fold tiny groups into a close neighbour (usually a cough or a split of one voice)
    changed = True
    while changed and len(groups) > 1:
        changed = False
        for g, (c, secs) in sorted(groups.items(), key=lambda kv: kv[1][1]):
            if secs >= SMALL_GROUP_S:
                continue
            other = max((h for h in groups if h != g), key=lambda h: float(c @ groups[h][0]))
            if float(c @ groups[other][0]) >= 0.35:
                labels = [other if x == g else x for x in labels]
                groups = _centroids(labels, vecs, dur)
                changed = True
                break

    # short lines: nearest voice when there is some signal, otherwise the previous speaker
    cents = {g: c for g, (c, _) in groups.items()}
    prev = None
    for i in range(n):
        if labels[i] >= 0:
            prev = labels[i]
            continue
        if not cents:
            labels[i] = 0
            continue
        v = shorts.get(i)
        if v is not None:
            ranked = sorted(cents, key=lambda g: -float(v @ cents[g]))
            s1 = float(v @ cents[ranked[0]])
            s2 = float(v @ cents[ranked[1]]) if len(ranked) > 1 else -1.0
            # a short reply: trust its own voice when it clearly leans one way
            if s1 >= 0.35 and s1 - s2 >= 0.06:
                labels[i] = ranked[0]
                prev = ranked[0]
                continue
        labels[i] = prev if prev is not None else next(iter(cents))
    # renumber by first appearance -> S1, S2, ...
    order: dict = {}
    for x in labels:
        if x not in order:
            order[x] = f"S{len(order) + 1}"
    labels = [order[x] for x in labels]
    out_labels = labels

    speakers = []
    for old, lab in order.items():
        idx = [i for i in range(n) if out_labels[i] == lab]
        c = groups.get(old, (None, 0))[0]
        secs = float(dur[idx].sum())
        longest = max(idx, key=lambda i: dur[i])
        speakers.append({"label": lab, "seconds": round(secs, 1),
                         "vec": [round(float(v), 5) for v in c] if c is not None else None,
                         "rms": float(np.mean(rms[idx])) if idx else 0.0,
                         "sample": [float(segments[longest].get("start", 0)), float(segments[longest].get("end", 0))],
                         "person_id": None, "sim": None, "state": "none"})
    match(speakers, people)
    if progress:
        progress(1.0)
    return {"labels": out_labels, "speakers": speakers, "segments": segments}


def _centroids(labels: list, vecs: list, dur: np.ndarray) -> dict:
    groups: dict = {}
    for i, g in enumerate(labels):
        if g < 0 or vecs[i] is None:
            continue
        w = min(float(dur[i]), 20.0)
        c, s = groups.get(g, (np.zeros_like(vecs[i]), 0.0))
        groups[g] = (c + vecs[i] * w, s + float(dur[i]))
    return {g: (_norm(c), s) for g, (c, s) in groups.items()}


def match(speakers: list, people: list):
    """Assign saved voices to speakers, each person at most once, best matches first."""
    known = [(p, _norm(p["vec"])) for p in people if p.get("vec")]
    pairs = []
    for sp in speakers:
        if sp.get("state") == "confirmed" or not sp.get("vec"):
            continue
        v = _norm(sp["vec"])
        bonus = 0.0005 * min(float(sp.get("seconds") or 0), 60.0)   # near-ties go to the speaker with more speech
        for p, pv in known:
            pairs.append((float(v @ pv), sp["label"], p, bonus))
    taken_people = {sp["person_id"] for sp in speakers if sp.get("state") == "confirmed" and sp.get("person_id")}
    taken_labels = set()
    for sim, label, p, _ in sorted(pairs, key=lambda x: -(x[0] + x[3])):
        if sim < SUGGEST_SIM:
            break
        if label in taken_labels or p["id"] in taken_people:
            continue
        sp = next(s for s in speakers if s["label"] == label)
        sp.update(person_id=p["id"], sim=round(sim, 3), state="auto" if sim >= AUTO_SIM else "suggested")
        taken_labels.add(label)
        taken_people.add(p["id"])
    # the wearer is usually far louder than everyone else: suggest "me" if no voice is saved for them yet
    me = next((p for p in people if p.get("is_me")), None)
    if (me is None or not me.get("vec")) and len(speakers) >= 1:
        open_sp = [s for s in speakers if s["state"] == "none"]
        if open_sp:
            loud = max(speakers, key=lambda s: s["rms"])
            rest = [s["rms"] for s in speakers if s is not loud] or [0.0]
            if loud in open_sp and (len(speakers) == 1 or loud["rms"] >= 1.6 * float(np.median(rest))) and loud["seconds"] >= 3:
                loud.update(state="suggested", person_id=me["id"] if me else None, sim=None, guess_me=True)


def clip_vec(models_dir: Path, wav: Path, spans: list) -> Optional[list]:
    """One voice signature for a set of [start, end] spans (used when lines are reassigned by hand)."""
    if fake():
        return None
    audio = _load(wav)
    acc, w = None, 0.0
    for a, b in spans:
        if b - a < MIN_VOICE_S:
            continue
        v = embed(models_dir, audio[int(a * SR):int(b * SR)])
        acc = v * (b - a) if acc is None else acc + v * (b - a)
        w += b - a
    return [round(float(x), 5) for x in _norm(acc)] if acc is not None else None


# ---------------------------------------------------------------- stand-in for tests
_FAKE_VOICES = {k: _norm(np.eye(8)[k] + 0.05) for k in range(8)}


def _fake_analyse(segments: list, people: list) -> dict:
    """Alternate two voices line by line; the same two voices in every recording."""
    labels = [f"S{1 + (i % 2)}" for i in range(len(segments))]
    speakers = []
    for k, lab in enumerate(sorted(set(labels), key=labels.index)):
        idx = [i for i, x in enumerate(labels) if x == lab]
        secs = sum(max(0.0, segments[i]["end"] - segments[i]["start"]) for i in idx)
        speakers.append({"label": lab, "seconds": round(secs, 1), "vec": [round(float(x), 5) for x in _FAKE_VOICES[k]],
                         "rms": 0.2 if k == 0 else 0.05,
                         "sample": [segments[idx[0]]["start"], segments[idx[0]]["end"]],
                         "person_id": None, "sim": None, "state": "none"})
    match(speakers, people)
    return {"labels": labels, "speakers": speakers, "segments": segments}
